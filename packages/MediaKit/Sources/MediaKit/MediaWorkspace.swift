import Foundation
import Observation

@MainActor public protocol MediaService: AnyObject {
  func query(_ request: RowQuery) async throws -> RowPage
  func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt
  func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt
  func captureReceipt(id: String) async throws -> CaptureReceipt
  func close()
}
extension HubClient: MediaService {}

public enum EditState: Equatable, Sendable {
  case sending
  case committed(PatchReceipt)
  case conflict, uncertain, rejected
}

/// Visible state is scoped to one validated connection generation. No automatic mutation replay.
@Observable @MainActor public final class MediaWorkspace {
  public private(set) var connection: ConnectionIdentity?
  public private(set) var rows: [String: RowPage] = [:]
  public private(set) var drafts: [MediaDraft] = []
  public private(set) var captureReceipts: [UUID: CaptureReceipt] = [:]
  public private(set) var editStates: [UUID: EditState] = [:]
  public private(set) var currentValues: [UUID: CoreRow] = [:]
  public private(set) var cachedPages = Set<String>()
  public private(set) var error: HubError?
  public var isOnline = false
  @ObservationIgnored private let store: DraftStore
  @ObservationIgnored private let cache: MediaCache?
  @ObservationIgnored private var service: (any MediaService)?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var sendingCaptures = Set<UUID>()

  public init(drafts: DraftStore, cache: MediaCache? = nil) {
    store = drafts
    self.cache = cache
  }

  /// Caller completes session/config/grant revalidation before connecting or recovering drafts.
  public func connect(identity: ConnectionIdentity, service: any MediaService) async throws {
    disconnect()
    let current = generation
    let recovered = try await store.load(connection: identity)
    guard current == generation else {
      service.close()
      return
    }
    self.connection = identity
    self.service = service
    self.drafts = recovered
    self.isOnline = true
  }
  public func disconnect() {
    generation &+= 1
    service?.close()
    service = nil
    connection = nil
    isOnline = false
    rows = [:]
    drafts = []
    captureReceipts = [:]
    editStates = [:]
    currentValues = [:]
    cachedPages = []
    sendingCaptures = []
    error = nil
  }
  /// Snapshot browsing has no validated service; reconnecting requires session revalidation.
  public var isBrowsingSnapshot: Bool { connection != nil && service == nil }
  /// `cacheKey` must identify the page independently of time-dependent filter values.
  public func load(_ query: RowQuery, key: String, cacheKey stable: String? = nil) async {
    guard let connection else { return }
    let current = generation
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let queryData = try? encoder.encode(query) else {
      error = .invalidRequest
      return
    }
    let cacheKey = stable ?? (key + ":" + ConnectionIdentity.digest(queryData))
    guard let service else {
      await cached(key: key, cacheKey: cacheKey, connection: connection, generation: current)
      return
    }
    do {
      let result = try await service.query(query)
      guard current == generation else { return }
      // A successful read on the validated session ends a transient outage.
      isOnline = true
      rows[key] = result
      cachedPages.remove(key)
      error = nil
      // A disposable cache write failing must not hide a valid network page.
      try? await cache?.store(
        .init(items: [], nextCursor: result.nextCursor, rows: result.rows), key: cacheKey,
        connection: connection)
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      let reason = error as? HubError ?? .unavailable
      if await handle(reason, generation: current) { return }
      if reason == .unavailable {
        isOnline = false
        self.error = reason
        await cached(key: key, cacheKey: cacheKey, connection: connection, generation: current)
      } else {
        rows[key] = nil
        cachedPages.remove(key)
        self.error = reason
      }
    }
  }
  public func browseOffline(identity: ConnectionIdentity) {
    disconnect()
    connection = identity
    isOnline = false
  }
  private func cached(
    key: String, cacheKey: String, connection: ConnectionIdentity, generation: UInt64
  ) async {
    let page = await cache?.page(key: cacheKey, connection: connection)
    guard generation == self.generation else { return }
    if let page {
      rows[key] = .init(rows: page.rows, nextCursor: page.nextCursor)
      cachedPages.insert(key)
    } else {
      rows[key] = nil
      cachedPages.remove(key)
    }
  }
  public func keep(_ draft: MediaDraft) async throws {
    guard let connection else { throw HubError.revoked }
    guard !sendingCaptures.contains(draft.id), captureReceipts[draft.id] == nil,
      editStates[draft.id] == nil
    else { throw HubError.conflict }
    let current = generation
    try await store.save(draft, connection: connection)
    guard current == generation else { return }
    drafts.removeAll { $0.id == draft.id }
    drafts.append(draft)
  }
  public func discard(_ id: UUID) async throws {
    guard let connection else { throw HubError.revoked }
    let current = generation
    try await store.discard(id: id, connection: connection)
    guard current == generation else { return }
    drafts.removeAll { $0.id == id }
    captureReceipts[id] = nil
    editStates[id] = nil
    currentValues[id] = nil
  }
  public func submit(_ draft: MediaDraft) async {
    guard isOnline, connection != nil, let service, drafts.contains(draft) else { return }
    let current = generation
    switch draft.content {
    case .capture(let input, let intent):
      guard !sendingCaptures.contains(draft.id), captureReceipts[draft.id]?.state != "saved" else {
        return
      }
      sendingCaptures.insert(draft.id)
      do {
        let receipt = try await service.submitCapture(
          .init(
            requestId: draft.id.uuidString.lowercased(), input: .init(text: input),
            intent: intent.rawValue))
        guard current == generation else { return }
        captureReceipts[draft.id] = receipt
        if receipt.state == "saved" { await forget(draft.id, generation: current) }
      } catch {
        guard current == generation else { return }
        let reason = error as? HubError ?? .uncertain
        if await handle(reason, generation: current) { return }
        // The service definitively refused it; anything else may still have been accepted.
        let refused: Bool
        switch reason {
        case .forbidden, .rejected, .invalidRequest: refused = true
        default: refused = false
        }
        captureReceipts[draft.id] = .init(
          requestId: draft.id.uuidString.lowercased(), state: refused ? "rejected" : "uncertain")
      }
      if current == generation { sendingCaptures.remove(draft.id) }
    case .edit(let edit):
      guard editStates[draft.id] == nil else { return }
      editStates[draft.id] = .sending
      do {
        let receipt = try await service.patch(edit)
        guard current == generation else { return }
        editStates[draft.id] = .committed(receipt)
        await forget(draft.id, generation: current)
      } catch {
        guard current == generation else { return }
        let reason = error as? HubError ?? .uncertain
        if await handle(reason, generation: current) { return }
        editStates[draft.id] =
          reason == .conflict ? .conflict : reason == .uncertain ? .uncertain : .rejected
      }
    }
  }
  /// Readback preserves the requested draft and current values side by side; it never retries.
  public func reconcile(_ draft: MediaDraft) async {
    guard isOnline, let service, drafts.contains(draft) else { return }
    let current = generation
    do {
      switch draft.content {
      case .capture:
        let receipt = try await service.captureReceipt(id: draft.id.uuidString.lowercased())
        guard current == generation else { return }
        captureReceipts[draft.id] = receipt
        if receipt.state == "saved" { await forget(draft.id, generation: current) }
      case .edit(let edit):
        let columns = Set(edit.values.keys).union(["id", "updated_at", "hub_at", "deleted_at"])
          .sorted()
        let page = try await service.query(
          .init(
            table: edit.table, columns: columns,
            filter: .object([
              "column": .string("id"), "op": .string("eq"), "value": .string(edit.id),
            ]), limit: 1))
        guard current == generation else { return }
        currentValues[draft.id] = page.rows.first
      }
    } catch { _ = await handle(error as? HubError ?? .unavailable, generation: current) }
  }
  /// A confirmed change no longer needs its preserved input; its receipt stays visible.
  private func forget(_ id: UUID, generation current: UInt64) async {
    guard let connection else { return }
    try? await store.discard(id: id, connection: connection)
    if current == generation { drafts.removeAll { $0.id == id } }
  }
  private func handle(_ reason: HubError, generation current: UInt64) async -> Bool {
    guard current == generation else { return true }
    guard reason == .revoked || reason == .profileChanged else { error = reason; return false }
    let owner = connection
    disconnect()
    let lockedGeneration = generation
    if let owner { await cache?.removePages(connection: owner) }
    if lockedGeneration == generation { error = reason }
    return true
  }
}
