import Foundation
import Testing

@testable import MediaKit

/// Delegates to the synthetic service, with a switchable outage and a gate for one show's episodes.
@MainActor final class InterruptibleService: MediaService {
  let synthetic: SyntheticMediaService
  var offline = false
  var gatedShow: String?
  var gate: CheckedContinuation<Void, Never>?
  init() throws { synthetic = try SyntheticMediaService() }
  func query(_ request: RowQuery) async throws -> RowPage {
    if offline { throw HubError.unavailable }
    guard let show = gatedShow, request.table == "episodes", let filter = request.filter,
      String(decoding: try JSONEncoder().encode(filter), as: UTF8.self).contains(show)
    else { return try await synthetic.query(request) }
    var borrowed = request
    borrowed.filter = try JSONDecoder().decode(
      CoreJSONValue.self,
      from: Data(
        String(decoding: try JSONEncoder().encode(filter), as: UTF8.self)
          .replacingOccurrences(of: show, with: "show-one").utf8))
    var page = try await synthetic.query(borrowed)
    page.rows = page.rows.map { row in
      var row = row
      if case .string(let id) = row["id"] { row["id"] = .string(show + "-" + id) }
      row["parent"] = .string(show)
      return row
    }
    await withCheckedContinuation { gate = $0 }
    return page
  }
  func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt { try await synthetic.patch(edit) }
  func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt {
    try await synthetic.submitCapture(request)
  }
  func captureReceipt(id: String) async throws -> CaptureReceipt {
    try await synthetic.captureReceipt(id: id)
  }
  func close() {}
}

@Suite @MainActor struct ResilienceTests {
  func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  func identity(host: String = "one.example", profile: String = "media", revision: String = "v1", credential: String = "a") throws -> ConnectionIdentity {
    try .init(endpoint: URL(string: "https://\(host)")!, profile: profile, revision: revision, credentialID: credential)
  }
  let query = RowQuery(table: "items", columns: ["id"])
  let edit = ConditionalEdit(
    table: "items", id: "one", values: ["saved": .bool(true)],
    expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil))

  @Test func cancelledReadsStayOnlineAndASuccessfulReadEndsAnOutage() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let service = DelayedService()
    try await workspace.connect(identity: identity(), service: service)
    let cancelled = Task { await workspace.load(query, key: "feed") }
    while service.queryContinuation == nil { await Task.yield() }
    service.queryContinuation?.resume(throwing: CancellationError())
    await cancelled.value
    #expect(workspace.isOnline)
    #expect(workspace.error == nil)
    service.queryError = .unavailable
    await workspace.load(query, key: "feed")
    #expect(!workspace.isOnline)
    service.queryError = nil
    service.queryContinuation = nil
    let retry = Task { await workspace.load(query, key: "feed") }
    while service.queryContinuation == nil { await Task.yield() }
    service.queryContinuation?.resume(returning: .init(rows: [], nextCursor: nil))
    await retry.value
    #expect(workspace.isOnline)
    #expect(workspace.error == nil)
  }

  @Test func feedPagesAreFoundOfflineAfterTheClockMoves() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try InterruptibleService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root.appendingPathComponent("drafts")), cache: MediaCache(directory: root.appendingPathComponent("cache")))
    try await workspace.connect(identity: service.synthetic.connection.identity, service: service)
    var clock = service.synthetic.now
    let library = MediaLibrary(connection: service.synthetic.connection, workspace: workspace, now: clock)
    await library.refresh()
    let online = Set(library.cards.map(\.identity))
    #expect(online.contains(MediaIdentity(kind: .tvShow, id: "show-one")))
    service.offline = true
    clock = clock.addingTimeInterval(90)
    let later = MediaLibrary(connection: service.synthetic.connection, workspace: workspace, now: clock)
    await later.refresh()
    #expect(Set(later.cards.map(\.identity)) == online)
    #expect(!workspace.isOnline)
  }

  @Test func anotherShowsLateEpisodesNeverJoinTheOpenShow() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try InterruptibleService()
    service.gatedShow = "show-other"
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.synthetic.connection.identity, service: service)
    let library = MediaLibrary(connection: service.synthetic.connection, workspace: workspace, now: service.synthetic.now)
    let stale = Task { await library.loadEpisodes(showID: "show-other") }
    while service.gate == nil { await Task.yield() }
    await library.loadEpisodes(showID: "show-one")
    service.gate?.resume()
    await stale.value
    #expect(!library.episodes.isEmpty)
    #expect(library.episodes.allSatisfy { $0.source?.id == "show-one" })
    #expect(library.airedEpisodes(season: 1, showID: "show-one").allSatisfy { $0.source?.id == "show-one" })
    #expect(library.airedEpisodes(season: 1, showID: "show-other").isEmpty)
  }

  @Test func confirmedChangesLeaveDraftsWhileUnconfirmedOnesStay() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DraftStore(directory: root)
    let workspace = MediaWorkspace(drafts: store)
    let service = DelayedService()
    let owner = try identity()
    try await workspace.connect(identity: owner, service: service)
    let committed = MediaDraft(edit: edit)
    try await workspace.keep(committed)
    await workspace.submit(committed)
    guard case .committed = workspace.editStates[committed.id] else {
      Issue.record("edit was not committed")
      return
    }
    service.patchError = .conflict
    let conflicting = MediaDraft(edit: edit)
    try await workspace.keep(conflicting)
    await workspace.submit(conflicting)
    let capture = MediaDraft(input: "Save https://example.test/a", intent: .save)
    try await workspace.keep(capture)
    let sending = Task { await workspace.submit(capture) }
    while service.captureContinuation == nil { await Task.yield() }
    service.captureContinuation?.resume(
      returning: .init(requestId: capture.id.uuidString.lowercased(), state: "saved", item: .init(kind: "article", id: "new")))
    await sending.value
    #expect(workspace.captureReceipts[capture.id]?.state == "saved")
    #expect(workspace.drafts == [conflicting])
    #expect(try await store.load(connection: owner) == [conflicting])
  }

  @Test(arguments: [(HubError.rejected(422), "rejected"), (.forbidden, "rejected"), (.uncertain, "uncertain"), (.unavailable, "uncertain")])
  func definitiveCaptureRejectionsAreNotShownAsPending(error: HubError, state: String) async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let service = DelayedService()
    service.captureError = error
    try await workspace.connect(identity: identity(), service: service)
    let capture = MediaDraft(input: "Save https://example.test/b", intent: .save)
    try await workspace.keep(capture)
    await workspace.submit(capture)
    #expect(workspace.captureReceipts[capture.id]?.state == state)
    #expect(workspace.drafts == [capture])
  }

  @Test func draftsSurviveReenrollmentWithTheSameServiceProfileOnly() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DraftStore(directory: root)
    let draft = MediaDraft(input: "Keep me", intent: .save)
    try await store.save(draft, connection: identity())
    #expect(try await store.load(connection: identity(revision: "v2", credential: "b")) == [draft])
    #expect(try await store.load(connection: identity(host: "two.example")).isEmpty)
    #expect(try await store.load(connection: identity(profile: "other")).isEmpty)
    try await store.discard(id: draft.id, connection: identity(revision: "v3", credential: "c"))
    #expect(try await store.load(connection: identity()).isEmpty)
  }
}

@Suite @MainActor struct CredentialLifecycleTests {
  func session(_ store: MemoryCredentialStore, _ fixture: EnrollmentFixture) throws -> EnrollmentSession {
    try EnrollmentSession(store: store, factory: { _, token in
      fixture.token = token
      return fixture
    })
  }

  @Test func offlineRestoreKeepsTheCredentialForCachedBrowsing() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let first = try session(store, fixture)
    _ = try first.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await first.poll()
    let active = try #require(store.records.values.first)
    fixture.replyError = URLError(.notConnectedToInternet)
    await #expect(throws: HubError.unavailable) { try await session(store, fixture).restore(active) }
    #expect(store.records.values.map(\.state) == [.active])
  }

  @Test func credentialRevokedByTheServiceIsForgotten() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let first = try session(store, fixture)
    _ = try first.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await first.poll()
    let active = try #require(store.records.values.first)
    fixture.status = 401
    let next = try session(store, fixture)
    await #expect(throws: HubError.revoked) { try await next.restore(active) }
    await next.forget(active)
    #expect(store.records.isEmpty)
    #expect(!next.cleanupPending)
  }

  @Test func completingEnrollmentRevokesEarlierDeviceCredentials() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let first = try session(store, fixture)
    _ = try first.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await first.poll()
    let second = try session(store, fixture)
    _ = try second.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await second.poll()
    #expect(second.state == .connected)
    #expect(store.records.values.filter { $0.state == .active }.count == 1)
    #expect(store.records.count == 1)
    #expect(fixture.revokes == 1)
  }
}
