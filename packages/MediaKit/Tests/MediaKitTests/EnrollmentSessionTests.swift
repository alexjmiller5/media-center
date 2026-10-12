import Foundation
import Testing

@testable import MediaKit

@MainActor final class MemoryCredentialStore: CredentialStore {
  var records: [String: StoredCredential] = [:]
  func all() throws -> [StoredCredential] { Array(records.values) }
  func save(_ credential: StoredCredential) throws { records[credential.id] = credential }
  func remove(id: String) throws { records[id] = nil }
}

@MainActor final class EnrollmentFixture: EnrollmentTransport {
  var token = ""
  var status = 200
  var profile = "media-center"
  var revision = String(repeating: "a", count: 64)
  var configRevision: String?
  var extraScopes: [String] = []
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
          "row_query": .string("bounded-v1"),
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
  func query(_ request: RowQuery) async throws -> RowPage { .init(rows: [], nextCursor: nil) }
  func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt { throw HubError.forbidden }
  func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt {
    throw HubError.forbidden
  }
  func captureReceipt(id: String) async throws -> CaptureReceipt { throw HubError.forbidden }
  func close() {}
}

@Suite @MainActor struct EnrollmentSessionTests {
  @Test func browserGetsOnlyFingerprintAndCredentialActivatesAfterValidation() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    let approval = try session.begin(
      endpoint: URL(string: "https://example.test")!, name: "Example phone")
    #expect(!approval.url.absoluteString.contains(fixture.token))
    #expect(approval.url.query?.contains("profile=media-center") == true)
    #expect(store.records.values.first?.state == .pending)
    await session.poll()
    #expect(session.connection?.bindings.items["article"]?.table == "items")
    #expect(store.records.values.first?.state == .active)
    await session.disconnect()
    #expect(session.connection == nil)
    #expect(store.records.isEmpty)
    #expect(fixture.revokes == 1)
  }
  @Test func sourceBindingsWithoutStatusesConnect() async throws {
    // The hub's consumer config omits `statuses` on source bindings: sources have no consumption state.
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.source = [
      "id": "id", "title": "title", "follow": "follow", "feedSince": "feed_since",
      "updatedAt": "updated_at", "hubAt": "hub_at", "deletedAt": "deleted_at",
    ]
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await session.poll()
    #expect(session.state == .connected)
    #expect(session.failure == nil)
    #expect(session.connection?.bindings.sources["youtubeChannel"]?.table == "channels")
    #expect(session.connection?.bindings.sources["youtubeChannel"]?.statuses == [:])
  }
  @Test func refusedEnrollmentExplainsTheFailingStep() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.extraScopes = ["tables:read:unrelated:id"]
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await session.poll()
    #expect(session.state == .failed)
    #expect(session.failure == "grants: forbidden")
    #expect(!(session.failure ?? "").contains(fixture.token))
  }
  @Test func cancellingThePollingTaskStillRevokesTheRefusedCredential() async throws {
    // The app polls from `.task(id: state)`, which SwiftUI cancels as soon as the state turns failed.
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.extraScopes = ["tables:read:unrelated:id"]
    fixture.delayRevocation = true
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    let task = Task { await session.poll() }
    while fixture.pendingRevocation == nil { await Task.yield() }
    #expect(session.state == .failed)
    task.cancel()
    fixture.pendingRevocation?.resume(
      returning: .init(status: 200, data: .object(["logged_out": .bool(true)])))
    await task.value
    #expect(store.records.isEmpty)
    #expect(!session.cleanupPending)
  }
  @Test func cancelledPollIsNotARefusal() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.replyError = URLError(.cancelled)
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await session.poll()
    #expect(session.state == .waiting)
    #expect(fixture.revokes == 0)
    #expect(store.records.values.map(\.state) == [.pending])
  }
  @Test func offlineFileBindingAdmitsTheFilesGrantAndNothingElseDoes() async throws {
    // The offline copy of a video is read through `files:read:youtube/`; the grant
    // belongs to this consumer only when a binding carries the offlineFile role.
    for bound in [true, false] {
      let store = MemoryCredentialStore()
      let fixture = EnrollmentFixture()
      if bound { fixture.binding.fields["offlineFile"] = "offline_file" }
      fixture.extraScopes = ["files:read:youtube/"]
      let session = try EnrollmentSession(
        store: store,
        factory: { _, token in
          fixture.token = token
          return fixture
        })
      _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
      await session.poll()
      #expect((session.state == .connected) == bound)
      #expect((session.connection != nil) == bound)
    }
  }

  @Test func wrongProfileChangedRevisionAndUnboundGrantsFailClosed() async throws {
    for fault in ["profile", "revision", "grant"] {
      let store = MemoryCredentialStore()
      let fixture = EnrollmentFixture()
      if fault == "profile" { fixture.profile = "other" }
      if fault == "revision" { fixture.configRevision = String(repeating: "b", count: 64) }
      if fault == "grant" { fixture.extraScopes = ["tables:read:unrelated:id"] }
      let session = try EnrollmentSession(
        store: store,
        factory: { _, token in
          fixture.token = token
          return fixture
        })
      _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
      await session.poll()
      #expect(session.connection == nil)
      #expect(!store.records.values.contains { $0.state == .active })
      #expect(session.state == .failed)
    }
  }
  @Test func monotonicDeadlineAndPollingBackoffAreEnforced() async throws {
    var now = 0.0
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.status = 401
    let session = try EnrollmentSession(
      store: store, now: { now },
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await session.poll()
    await session.poll()
    #expect(fixture.replyCount == 1)
    now = 5
    await session.poll()
    #expect(fixture.replyCount == 2)
    now = 301
    await session.poll()
    #expect(session.state == .expired)
    #expect(store.records.values.first?.state == .revoking)
    #expect(session.connection == nil)
    // Never approved: the hub holds nothing to revoke. The candidate stays only for late-approval cleanup.
    #expect(!session.cleanupPending)
    await session.retryCleanup()
    #expect(!session.cleanupPending)
    #expect(store.records.values.first?.state == .revoking)
    fixture.status = 200
    await session.retryCleanup()
    #expect(store.records.isEmpty)
    #expect(!session.cleanupPending)
  }
  @Test func unconfirmedRevocationExplainsItself() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    fixture.revocationStatus = 500
    await session.disconnect()
    #expect(session.cleanupPending)
    #expect(session.cleanupDetail == "revocation: hub did not revoke the device (HTTP 500)")
    fixture.revocationStatus = nil
    await session.retryCleanup()
    #expect(!session.cleanupPending)
    #expect(session.cleanupDetail == nil)
    #expect(store.records.isEmpty)
  }
  @Test func cancellationAndLateApprovalCannotInstallSession() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    fixture.delay = true
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    let task = Task { await session.poll() }
    while fixture.pendingReply == nil { await Task.yield() }
    fixture.status = 401
    await session.disconnect()
    #expect(store.records.values.first?.state == .revoking)
    fixture.status = 200
    fixture.pendingReply?.resume(returning: try fixture.sessionReply())
    await task.value
    #expect(session.connection == nil)
    #expect(store.records.isEmpty)
    #expect(fixture.revokes == 2)
  }
  @Test func expiredAttemptCannotOverwriteAReplacementDuringCleanup() async throws {
    var now = 0.0
    let store = MemoryCredentialStore()
    let first = EnrollmentFixture()
    let next = EnrollmentFixture()
    var useNext = false
    first.delayRevocation = true
    let session = try EnrollmentSession(
      store: store, now: { now },
      factory: { _, token in
        let fixture = useNext ? next : first
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://one.example")!, name: "Example")
    now = 301
    let task = Task { await session.poll() }
    while first.pendingRevocation == nil { await Task.yield() }
    useNext = true
    _ = try session.begin(endpoint: URL(string: "https://two.example")!, name: "Example")
    first.pendingRevocation?.resume(
      returning: .init(status: 200, data: .object(["logged_out": .bool(true)])))
    await task.value
    #expect(session.state == .waiting)
    await session.retryCleanup()
    #expect(next.revokes == 0)
    await session.poll()
    #expect(session.state == .connected)
    #expect(session.connection?.identity.endpoint.host == "two.example")
  }
  @Test func restoreRequiresUnchangedApprovedScopeSetAndRevision() async throws {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let first = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try first.begin(endpoint: URL(string: "https://one.example")!, name: "Example")
    await first.poll()
    let active = try #require(store.records.values.first)
    let second = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    try await second.restore(active)
    #expect(second.connection?.identity == first.connection?.identity)
    fixture.revision = String(repeating: "b", count: 64)
    let third = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    await #expect(throws: (any Error).self) { try await third.restore(active) }
    #expect(third.connection == nil)
  }
  @Test func offlineConnectionSnapshotContainsNoCredentialAndCannotCrossAccounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let session = try EnrollmentSession(
      store: store,
      factory: { _, token in
        fixture.token = token
        return fixture
      })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Example")
    await session.poll()
    let connection = try #require(session.connection)
    let credential = try #require(store.records.values.first)
    let snapshots = ConnectionSnapshotStore(directory: root)
    try await snapshots.save(connection)
    #expect(await snapshots.load(credential: credential)?.identity == connection.identity)
    let other = StoredCredential(
      endpoint: credential.endpoint, profile: credential.profile, token: "other-device-token",
      state: .active, session: credential.session)
    #expect(await snapshots.load(credential: other) == nil)
    for file in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    {
      #expect(try !String(contentsOf: file, encoding: .utf8).contains(fixture.token))
      try Data("broken".utf8).write(to: file)
    }
    #expect(await snapshots.load(credential: credential) == nil)
    #expect(store.records.count == 1)
  }
}
