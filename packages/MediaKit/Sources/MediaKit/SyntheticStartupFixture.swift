#if DEBUG
import Foundation
import Observation

@MainActor final class MemoryCredentialStore: CredentialStore {
  var records: [String: StoredCredential] = [:]
  func all() throws -> [StoredCredential] { Array(records.values) }
  func save(_ credential: StoredCredential) throws { records[credential.id] = credential }
  func remove(id: String) throws { records[id] = nil }
}

@Observable @MainActor final class EnrollmentFixture: EnrollmentTransport {
  var token = ""
  var status = 200
  var profile = "media-center"
  var revision = String(repeating: "a", count: 64)
  var configRevision: String?
  var extraScopes: [String] = []
  var rows: [CoreRow] = []
  var queries: [RowQuery] = []
  var delayQuery = false
  var pendingQuery: CheckedContinuation<RowPage, any Error>?
  var pendingReply: CheckedContinuation<CoreSessionReply, any Error>?
  var delay = false
  var delayRevocation = false
  var pendingRevocation: CheckedContinuation<CoreSessionReply, any Error>?
  var revokes = 0
  var revocationStatus: Int?
  var replyCount = 0
  var replyError: (any Error)?
  var binding = RecordBinding(
    table: "items",
    fields: [
      "id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at",
      "hubAt": "hub_at", "deletedAt": "deleted_at",
    ], statuses: ["Unseen": .notStarted, "Done": .finished])
  /// Fields of a `youtubeChannel` source binding, served as the hub does: without `statuses`.
  var source: [String: String]?
  var scopes: [String] {
    (binding.fields.values.flatMap { ["tables:read:items:\($0)", "catalog:read:items:\($0)"] }
      + (source ?? [:]).values.flatMap { ["tables:read:channels:\($0)", "catalog:read:channels:\($0)"] })
      .sorted() + extraScopes
  }
  func sessionReply() throws -> CoreSessionReply {
    .init(
      status: status,
      data: .object([
        "name": .string("device:" + ConnectionIdentity.digest(Data(token.utf8))),
        "scopes": .array(scopes.map(CoreJSONValue.string)),
        "enrollmentProfile": .object(["id": .string(profile), "revision": .string(revision)]),
        "capabilities": .object([
          "row_api": .string("v1"), "schema": .string("none"), "replica_sync": .bool(false),
          "files": .string("opaque-key-v1"), "subscriptions": .null,
          "row_query": .string("bounded-v1"), "conditional_patch": .string("revision-v1"),
        ]),
      ]))
  }
  func reply(path: String, method: String, body: Data?, limit: Int) async throws -> CoreSessionReply
  {
    if method == "POST" {
      revokes += 1
      if delayRevocation {
        let reply = try await withCheckedThrowingContinuation { pendingRevocation = $0 }
        // URLSession fails a request whose task was cancelled while it was in flight.
        if Task.isCancelled { throw URLError(.cancelled) }
        return reply
      }
      return .init(
        status: revocationStatus ?? (status == 200 ? 200 : 401),
        data: .object(["logged_out": .bool(true)]))
    }
    replyCount += 1
    if let replyError { throw replyError }
    if delay { return try await withCheckedThrowingContinuation { pendingReply = $0 } }
    return try sessionReply()
  }
  func consumerConfig() async throws -> CoreConsumerConfigReply {
    let bindings = MediaBindings(items: ["article": binding], sources: [:])
    var value = try JSONDecoder().decode(
      [String: CoreJSONValue].self, from: JSONEncoder().encode(bindings))
    if let source {
      value["sources"] = .object([
        "youtubeChannel": .object([
          "table": .string("channels"), "fields": .object(source.mapValues(CoreJSONValue.string)),
        ])
      ])
    }
    return .init(
      profile: .init(id: profile, revision: configRevision ?? revision),
      config: .init(version: 1, namespace: "media-center", bindings: value))
  }
  func metadata(table: String, columns: [String]) async throws -> CoreCatalogProjectionReply {
    .init(
      table: table,
      properties: columns.map { column in
        .init(
          column: column, type: ["saved", "follow"].contains(column) ? "bool" : column == "status" ? "select" : column == "offline_file" ? "json" : "text",
          description: nil, required: false, readOnly: true,
          options: column == "status" ? [.init(v: "Unseen"), .init(v: "Done")] : nil)
      })
  }
  func query(_ request: RowQuery) async throws -> RowPage {
    queries.append(request)
    if delayQuery { return try await withCheckedThrowingContinuation { pendingQuery = $0 } }
    return .init(rows: rows, nextCursor: nil)
  }
  func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt { throw HubError.forbidden }
  func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt {
    throw HubError.forbidden
  }
  func captureReceipt(id: String) async throws -> CaptureReceipt { throw HubError.forbidden }
  func close() {}
}

/// In-memory enrollment and synthetic cached pages for the real startup path. No network or Keychain.
@MainActor public final class SyntheticStartupFixture {
  private let store = MemoryCredentialStore()
  private let transport = EnrollmentFixture()
  private let directory: URL
  private var prepared = false
  public let enrollment: EnrollmentSession
  public var waiting: Bool { transport.pendingReply != nil }
  public var queries: [RowQuery] { transport.queries }
  public init(directory: URL) throws {
    self.directory = directory
    let transport = self.transport
    enrollment = try EnrollmentSession(store: store, factory: { _, token in transport.token = token; return transport })
  }
  private func row(_ id: String, _ title: String) -> CoreRow {
    ["id": .string(id), "title": .string(title), "status": .string("Unseen"), "saved": .bool(true),
     "updated_at": .string("2026-01-01T00:00:00.000Z"), "hub_at": .null, "deleted_at": .null]
  }
  public func prepare() async throws {
    guard !prepared else { return }
    let transport = self.transport
    let seed = try EnrollmentSession(store: store, factory: { _, token in transport.token = token; return transport })
    _ = try seed.begin(endpoint: URL(string: "https://example.test")!, name: "Synthetic startup")
    await seed.poll()
    guard let connection = seed.connection else { throw HubError.invalidReply }
    try await ConnectionSnapshotStore(directory: directory.appendingPathComponent("Connections")).save(connection)
    transport.rows = [row("cached-article", "Cached reading")]
    let workspace = MediaWorkspace(drafts: DraftStore(directory: directory.appendingPathComponent("Drafts")),
      cache: MediaCache(directory: directory.appendingPathComponent("Cache")))
    try await workspace.connect(identity: connection.identity, service: transport)
    await MediaLibrary(connection: connection, workspace: workspace).refresh()
    try await workspace.keep(.init(input: "Synthetic unsent capture", intent: .save))
    transport.queries = []
    transport.delay = true
    prepared = true
  }
  public func accept() throws {
    guard let pending = transport.pendingReply else { return }
    transport.rows.append(row("new-article", "New reading"))
    transport.delay = false; transport.pendingReply = nil
    pending.resume(returning: try transport.sessionReply())
  }
  public func deny() {
    guard let pending = transport.pendingReply else { return }
    transport.delay = false; transport.pendingReply = nil
    pending.resume(throwing: HubError.revoked)
  }
}
#endif
