import Foundation
import Testing

@testable import MediaKit

@MainActor final class DelayedService: MediaService {
  var queryContinuation: CheckedContinuation<RowPage, any Error>?
  var captureContinuation: CheckedContinuation<CaptureReceipt, any Error>?
  var patchCount = 0
  var captureCount = 0
  var patchError: HubError?
  var queryError: HubError?
  var captureError: HubError?
  var receiptError: HubError?
  var delayPatch = false
  var patchContinuation: CheckedContinuation<PatchReceipt, any Error>?
  func query(_ request: RowQuery) async throws -> RowPage {
    if let queryError { throw queryError }
    return try await withCheckedThrowingContinuation { queryContinuation = $0 }
  }
  func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt {
    patchCount += 1
    if let patchError { throw patchError }
    if delayPatch { return try await withCheckedThrowingContinuation { patchContinuation = $0 } }
    return .init(id: edit.id, revision: .init(updatedAt: "2026-01-02T00:00:00.000Z", hubAt: nil))
  }
  func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt {
    captureCount += 1
    if let captureError { throw captureError }
    return try await withCheckedThrowingContinuation { captureContinuation = $0 }
  }
  func captureReceipt(id: String) async throws -> CaptureReceipt {
    if let receiptError { throw receiptError }
    return .init(requestId: id, state: "uncertain")
  }
  func close() {}
}

@Suite @MainActor struct MediaWorkspaceTests {
  func fixture(_ host: String = "one.example") throws -> ConnectionIdentity {
    try .init(
      endpoint: URL(string: "https://\(host)")!, profile: "media", revision: "v1",
      credentialID: "synthetic-fingerprint")
  }
  func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  @Test func lateReadAfterAccountSwitchCannotReplaceVisibleRows() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let first = DelayedService()
    let second = DelayedService()
    try await workspace.connect(identity: fixture(), service: first)
    let task = Task { await workspace.load(.init(table: "items", columns: ["id"]), key: "feed") }
    while first.queryContinuation == nil { await Task.yield() }
    try await workspace.connect(identity: fixture("two.example"), service: second)
    first.queryContinuation?.resume(
      returning: .init(rows: [["id": .string("private-old-account")]], nextCursor: nil))
    await task.value
    #expect(workspace.rows.isEmpty)
    #expect(workspace.connection?.endpoint.host == "two.example")
  }
  @Test func lateSaveAfterLogoutIsHiddenAndDraftSurvivesRestart() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DraftStore(directory: root)
    let workspace = MediaWorkspace(drafts: store)
    let service = DelayedService()
    let owner = try fixture()
    try await workspace.connect(identity: owner, service: service)
    let draft = MediaDraft(input: "Save this", intent: .save)
    try await workspace.keep(draft)
    let task = Task { await workspace.submit(draft) }
    while service.captureContinuation == nil { await Task.yield() }
    workspace.disconnect()
    service.captureContinuation?.resume(
      returning: .init(
        requestId: draft.id.uuidString.lowercased(), state: "saved",
        item: .init(kind: "article", id: "private")))
    await task.value
    #expect(workspace.drafts.isEmpty)
    #expect(workspace.captureReceipts.isEmpty)
    let next = MediaWorkspace(drafts: DraftStore(directory: root))
    try await next.connect(identity: owner, service: service)
    #expect(next.drafts == [draft])
    #expect(service.captureCount == 1)
  }
  @Test func offlineSubmissionAndConflictsPreserveExplicitDraft() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let service = DelayedService()
    try await workspace.connect(identity: fixture(), service: service)
    let edit = ConditionalEdit(
      table: "items", id: "one", values: ["saved": .bool(true)],
      expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil))
    let draft = MediaDraft(edit: edit)
    try await workspace.keep(draft)
    workspace.isOnline = false
    await workspace.submit(draft)
    #expect(service.patchCount == 0)
    #expect(workspace.drafts == [draft])
    workspace.isOnline = true
    service.patchError = .conflict
    await workspace.submit(draft)
    #expect(workspace.editStates[draft.id] == .conflict)
    #expect(workspace.drafts == [draft])
    service.patchError = .uncertain
    await workspace.submit(draft)
    #expect(workspace.editStates[draft.id] == .conflict)
    #expect(service.patchCount == 1)  // A conflict requires explicit reconciliation, never replay.
  }
  @Test func latePatchCannotShowSuccessInAnotherConnection() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let service = DelayedService()
    service.delayPatch = true
    try await workspace.connect(identity: fixture(), service: service)
    let draft = MediaDraft(
      edit: .init(
        table: "items", id: "one", values: ["saved": .bool(true)],
        expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil)))
    try await workspace.keep(draft)
    let task = Task { await workspace.submit(draft) }
    while service.patchContinuation == nil { await Task.yield() }
    try await workspace.connect(identity: fixture("two.example"), service: DelayedService())
    service.patchContinuation?.resume(
      returning: .init(
        id: "one", revision: .init(updatedAt: "2026-01-02T00:00:00.000Z", hubAt: nil)))
    await task.value
    #expect(workspace.editStates.isEmpty)
    #expect(workspace.drafts.isEmpty)
  }
  @Test func uncertainPatchReadbackRetainsCurrentAndRequestedValuesWithoutReplay() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let service = DelayedService()
    service.patchError = .uncertain
    try await workspace.connect(identity: fixture(), service: service)
    let draft = MediaDraft(
      edit: .init(
        table: "items", id: "one", values: ["saved": .bool(true)],
        expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil)))
    try await workspace.keep(draft)
    await workspace.submit(draft)
    #expect(workspace.editStates[draft.id] == .uncertain)
    let task = Task { await workspace.reconcile(draft) }
    while service.queryContinuation == nil { await Task.yield() }
    service.queryContinuation?.resume(
      returning: .init(rows: [["id": .string("one"), "saved": .bool(false)]], nextCursor: nil))
    await task.value
    #expect(workspace.currentValues[draft.id]?["saved"] == .bool(false))
    #expect(workspace.drafts == [draft])
    await workspace.submit(draft)
    #expect(service.patchCount == 1)
  }
  @Test func viewedPagesRecoverOfflineButRevocationNeverUsesCache() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(directory: root.appendingPathComponent("cache"))
    let store = DraftStore(directory: root.appendingPathComponent("drafts"))
    let service = DelayedService()
    let query = RowQuery(table: "items", columns: ["id"])
    let first = MediaWorkspace(drafts: store, cache: cache)
    try await first.connect(identity: fixture(), service: service)
    let task = Task { await first.load(query, key: "feed") }
    while service.queryContinuation == nil { await Task.yield() }
    service.queryContinuation?.resume(
      returning: .init(rows: [["id": .string("one")]], nextCursor: "next"))
    await task.value
    let next = MediaWorkspace(drafts: store, cache: cache)
    try await next.connect(identity: fixture(), service: service)
    service.queryError = .unavailable
    await next.load(query, key: "feed")
    #expect(next.rows["feed"]?.rows.first?["id"] == .string("one"))
    #expect(next.cachedPages.contains("feed"))
    #expect(!next.isOnline)
    next.isOnline = true
    service.queryError = .revoked
    await next.load(query, key: "feed")
    #expect(next.rows.isEmpty)
    #expect(next.connection == nil)
    #expect(next.error == .revoked)
  }
  @Test(arguments: ["patch", "capture", "receipt", "readback"])
  func everyRevokedResponseLocksConnectionAndKeepsDraft(operation: String) async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(directory: root.appendingPathComponent("cache"))
    let store = DraftStore(directory: root.appendingPathComponent("drafts"))
    let owner = try fixture()
    try await cache.store(.init(items: [], nextCursor: nil, rows: [["id": .string("private-row")]]), key: "prior", connection: owner)
    let service = DelayedService()
    let workspace = MediaWorkspace(drafts: store, cache: cache)
    try await workspace.connect(identity: owner, service: service)
    let edit = MediaDraft(edit: .init(table: "items", id: "one", values: ["saved": .bool(true)], expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil)))
    let draft = operation == "capture" || operation == "receipt" ? MediaDraft(input: "Save this", intent: .save) : edit
    try await workspace.keep(draft)
    switch operation {
    case "patch": service.patchError = .revoked; await workspace.submit(draft)
    case "capture": service.captureError = .revoked; await workspace.submit(draft)
    case "receipt": service.receiptError = .revoked; await workspace.reconcile(draft)
    default: service.queryError = .revoked; await workspace.reconcile(draft)
    }
    #expect(workspace.connection == nil)
    #expect(!workspace.isOnline)
    #expect(workspace.rows.isEmpty && workspace.drafts.isEmpty)
    #expect(workspace.error == .revoked)
    #expect(await cache.page(key: "prior", connection: owner) == nil)
    #expect(try await store.load(connection: owner) == [draft])
  }

}
