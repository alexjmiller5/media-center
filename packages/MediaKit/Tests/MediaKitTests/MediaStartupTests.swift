import Foundation
import Testing
import Observation
@testable import MediaKit

@Suite @MainActor struct MediaStartupTests {
  private func waitForValidation(_ fixture: SyntheticStartupFixture) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !fixture.waiting && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(fixture.waiting)
  }
  private func seed(_ root: URL) async throws -> (MemoryCredentialStore, EnrollmentFixture, StoredCredential, MediaConnection) {
    let store = MemoryCredentialStore()
    let fixture = EnrollmentFixture()
    let session = try EnrollmentSession(store: store, factory: { _, token in fixture.token = token; return fixture })
    _ = try session.begin(endpoint: URL(string: "https://example.test")!, name: "Test device")
    await session.poll()
    let credential = try #require(store.records.values.first)
    let connection = try #require(session.connection)
    try await ConnectionSnapshotStore(directory: root.appendingPathComponent("Connections")).save(connection)
    try await MediaCache(directory: root.appendingPathComponent("Cache")).store(
      .init(items: [], nextCursor: nil, rows: [["id": .string("cached-article"), "title": .string("Cached reading"), "status": .string("Unseen"), "saved": .bool(true), "updated_at": .string("2026-01-01T00:00:00.000Z"), "hub_at": .null, "deleted_at": .null]]),
      key: "feed:article:2:0:first", connection: connection.identity)
    try await DraftStore(directory: root.appendingPathComponent("Drafts")).save(.init(input: "Unsent capture", intent: .save), connection: connection.identity)
    return (store, fixture, credential, connection)
  }

  @Test func developmentFixtureExercisesRealStartupAndBoundedRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try SyntheticStartupFixture(directory: root)
    let model = MediaCenterModel(enrollment: fixture.enrollment, storageRoot: root)
    model.startupFixture = fixture
    let launch = Task { await model.start() }
    try await waitForValidation(fixture)
    #expect(model.library?.cards.map(\.title) == ["Cached reading"])
    #expect(!model.workspace.isOnline)
    #expect(model.workspace.drafts.isEmpty)
    #expect(fixture.queries.isEmpty)
    try fixture.accept()
    await launch.value
    #expect(Set(model.library?.cards.map(\.title) ?? []) == ["Cached reading", "New reading"])
    #expect(model.workspace.isOnline)
    #expect(fixture.queries.count == 1)
    #expect(fixture.queries.first?.limit == 50)
  }

  @Test func syntheticStartupRequiresAnIsolatedUUIDWithoutOpeningSecureStorage() {
    let model = MediaCenterModel(arguments: ["test", "--synthetic-startup"])
    #expect(model.enrollment == nil)
    #expect(model.startupFixture == nil)
    #expect(model.error == "Synthetic startup requires an isolated test UUID.")
  }

  @Test func developmentFixtureDenialPurgesCacheAndPreservesDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try SyntheticStartupFixture(directory: root)
    let model = MediaCenterModel(enrollment: fixture.enrollment, storageRoot: root)
    model.startupFixture = fixture
    let launch = Task { await model.start() }
    try await waitForValidation(fixture)
    let identity = try #require(model.library?.connection.identity)
    fixture.deny()
    await launch.value
    #expect(model.library == nil)
    #expect(model.workspace.connection == nil)
    #expect(await MediaCache(directory: root.appendingPathComponent("Cache")).page(key: "feed:article:2:0:first", connection: identity) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Connections").path).isEmpty)
    #expect(try await DraftStore(directory: root.appendingPathComponent("Drafts")).load(connection: identity).count == 1)
  }

  @Test func cachedLaunchShowsReadOnlyContentBeforeSessionReplies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, fixture, _, connection) = try await seed(root)
    fixture.delay = true
    let session = try EnrollmentSession(store: store, factory: { _, _ in fixture })
    let model = MediaCenterModel(enrollment: session, storageRoot: root)
    let launch = Task { await model.start() }
    while fixture.pendingReply == nil { await Task.yield() }
    #expect(model.workspace.connection == connection.identity)
    #expect(model.library?.cards.map(\.title) == ["Cached reading"])
    #expect(model.workspace.isBrowsingSnapshot)
    #expect(!model.workspace.isOnline)
    #expect(model.workspace.drafts.isEmpty)
    #expect(model.offlineVideos == nil)
    let cachedLibrary = model.library
    fixture.delayQuery = true
    let reply = try fixture.sessionReply()
    await confirmation("Promotion never removes the visible connection", expectedCount: 0) { changed in
      withObservationTracking { _ = model.workspace.connection } onChange: { changed() }
      fixture.pendingReply?.resume(returning: reply); fixture.pendingReply = nil
      while fixture.pendingQuery == nil { await Task.yield() }
      #expect(model.library === cachedLibrary)
      #expect(model.library?.cards.map(\.title) == ["Cached reading"])
      #expect(model.workspace.isOnline)
      #expect(model.workspace.drafts.count == 1)
      fixture.pendingQuery?.resume(returning: .init(rows: [], nextCursor: nil)); fixture.pendingQuery = nil
      await launch.value
    }
    #expect(model.library?.visible.isEmpty == true) // successful empty reply replaces cached content
  }

  @Test func unavailableLaunchKeepsCacheReadOnlyAndCancelledLaunchCanRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, fixture, credential, _) = try await seed(root)
    fixture.replyError = HubError.unavailable
    let model = MediaCenterModel(enrollment: try EnrollmentSession(store: store, factory: { _, _ in fixture }), storageRoot: root)
    await model.start()
    #expect(model.library?.cards.map(\.title) == ["Cached reading"])
    #expect(model.workspace.isBrowsingSnapshot)
    #expect(model.workspace.drafts.isEmpty)
    fixture.replyError = nil; fixture.delay = true
    let launch = Task { await model.start() }
    while fixture.pendingReply == nil { await Task.yield() }
    launch.cancel()
    fixture.pendingReply?.resume(throwing: CancellationError()); fixture.pendingReply = nil
    await launch.value
    #expect(store.records[credential.id]?.state == .active)
    #expect(model.workspace.isBrowsingSnapshot)
    fixture.delay = false
    await model.start()
    #expect(model.workspace.isOnline)
  }

  @Test func disconnectDuringRestoreRejectsLateSessionReply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, fixture, _, _) = try await seed(root)
    fixture.delay = true
    let model = MediaCenterModel(enrollment: try EnrollmentSession(store: store, factory: { _, _ in fixture }), storageRoot: root)
    let launch = Task { await model.start() }
    while fixture.pendingReply == nil { await Task.yield() }
    await model.disconnect()
    fixture.pendingReply?.resume(returning: try fixture.sessionReply()); fixture.pendingReply = nil
    await launch.value
    #expect(model.library == nil)
    #expect(model.workspace.connection == nil)
    #expect(!model.workspace.isOnline)
  }

  @Test func launchStillRetriesRevocationsWithoutAnActiveConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryCredentialStore()
    try store.save(.init(endpoint: URL(string: "https://example.test")!, profile: "media-center", token: "revocation-test-token", state: .revoking))
    let fixture = EnrollmentFixture()
    let model = MediaCenterModel(enrollment: try EnrollmentSession(store: store, factory: { _, _ in fixture }), storageRoot: root)
    await model.start()
    #expect(fixture.revokes == 1)
    #expect(store.records.isEmpty)
    #expect(model.library == nil)
  }

  @Test func anotherCredentialCannotHydratePriorContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, fixture, credential, _) = try await seed(root)
    store.records = [:]
    try store.save(.init(endpoint: credential.endpoint, profile: credential.profile, token: "another-test-token", state: .active, session: credential.session))
    fixture.delay = true
    let model = MediaCenterModel(enrollment: try EnrollmentSession(store: store, factory: { _, _ in fixture }), storageRoot: root)
    let launch = Task { await model.start() }
    while fixture.pendingReply == nil { await Task.yield() }
    #expect(model.hasStarted)
    #expect(model.starting)
    #expect(model.library == nil)
    #expect(model.workspace.connection == nil)
    fixture.pendingReply?.resume(throwing: HubError.unavailable); fixture.pendingReply = nil
    await launch.value
    #expect(!model.starting)
  }

  @Test(arguments: [HubError.revoked, .profileChanged]) func refusedLaunchPurgesContentButKeepsDrafts(_ reason: HubError) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, fixture, credential, connection) = try await seed(root)
    fixture.replyError = reason
    let model = MediaCenterModel(enrollment: try EnrollmentSession(store: store, factory: { _, _ in fixture }), storageRoot: root)
    await model.start()
    #expect(model.library == nil)
    #expect(model.workspace.connection == nil)
    #expect(await ConnectionSnapshotStore(directory: root.appendingPathComponent("Connections")).load(credential: credential) == nil)
    #expect(await MediaCache(directory: root.appendingPathComponent("Cache")).page(key: "feed:article:2:0:first", connection: connection.identity) == nil)
    #expect(try await DraftStore(directory: root.appendingPathComponent("Drafts")).load(connection: connection.identity).count == 1)
  }
}
