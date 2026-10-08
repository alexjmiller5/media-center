import Foundation
import Testing

@testable import MediaKit

private func storageDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
private func connection(
  _ host: String = "one.example", revision: String = "v1", credential: String = "device-a"
) throws -> ConnectionIdentity {
  try ConnectionIdentity(
    endpoint: URL(string: "https://\(host)")!, profile: "media", revision: revision,
    credentialID: credential)
}
private func storedPage(_ id: String) -> CachedMediaPage {
  CachedMediaPage(
    items: [.init(identity: .init(kind: .article, id: id), title: id)], nextCursor: nil)
}

@Test func cacheIsBoundToEndpointProfileRevisionAndCredential() async throws {
  let root = try storageDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let cache = MediaCache(directory: root)
  let owner = try connection()
  try await cache.store(storedPage("one"), key: "feed", connection: owner)
  #expect(await cache.page(key: "feed", connection: owner)?.items.first?.title == "one")
  for other in [
    try connection("two.example"), try connection(revision: "v2"),
    try connection(credential: "device-b"),
  ] {
    #expect(await cache.page(key: "feed", connection: other) == nil)
  }
  let restarted = MediaCache(directory: root)
  #expect(await restarted.page(key: "feed", connection: owner)?.items.count == 1)
  await restarted.removePages(connection: owner)
  #expect(await cache.page(key: "feed", connection: owner) == nil)
}

@Test func cacheEvictsLeastRecentlyUsedAcrossConnectionsAndEnforcesBytes() async throws {
  let root = try storageDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let cache = MediaCache(directory: root, maxPages: 2, maxBytes: 4096)
  let owner = try connection()
  let other = try connection("two.example")
  try await cache.store(
    storedPage("one"), key: "1", connection: owner, now: Date(timeIntervalSince1970: 1))
  try await cache.store(
    storedPage("two"), key: "2", connection: other, now: Date(timeIntervalSince1970: 2))
  #expect(await cache.page(key: "1", connection: owner, now: Date(timeIntervalSince1970: 3)) != nil)
  try await cache.store(
    storedPage("three"), key: "3", connection: owner, now: Date(timeIntervalSince1970: 4))
  #expect(await cache.page(key: "2", connection: other) == nil)
  #expect(await cache.page(key: "1", connection: owner) != nil)
  await #expect(throws: MediaStorageError.pageTooLarge) {
    try await cache.store(
      storedPage(String(repeating: "x", count: 5000)), key: "large", connection: owner)
  }
  let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
  #expect(files.count == 2)
  #expect(try files.reduce(0) { try $0 + Data(contentsOf: $1).count } <= 4096)
}

@Test func corruptCacheDoesNotDestroyRecoverableDrafts() async throws {
  let root = try storageDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let owner = try connection()
  let cacheRoot = root.appendingPathComponent("cache")
  let cache = MediaCache(directory: cacheRoot)
  let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
  let draft = MediaDraft(id: UUID(), input: "Save this article", intent: .save)
  try await drafts.save(draft, connection: owner)
  try await cache.store(storedPage("one"), key: "feed", connection: owner)
  for file in try FileManager.default.contentsOfDirectory(
    at: cacheRoot, includingPropertiesForKeys: nil)
  {
    try Data("broken".utf8).write(to: file)
  }
  #expect(await cache.page(key: "feed", connection: owner) == nil)
  await cache.removePages(connection: owner)
  let restarted = DraftStore(directory: root.appendingPathComponent("drafts"))
  #expect(try await restarted.load(connection: owner) == [draft])
  #expect(try await restarted.load(connection: connection("two.example")).isEmpty)
  // Drafts belong to the service profile, so a renewed revision or credential still recovers them.
  #expect(try await restarted.load(connection: connection(revision: "v2")) == [draft])
  try await restarted.discard(id: draft.id, connection: owner)
  #expect(try await restarted.load(connection: owner).isEmpty)
}

@Test func connectionRejectsURLsThatCouldLeakCredentials() throws {
  for endpoint in [
    "http://example.com", "https://user:pass@example.com", "https://example.com?token=x",
    "https://example.com#x",
  ] {
    #expect(throws: MediaStorageError.invalidEndpoint) {
      try ConnectionIdentity(
        endpoint: URL(string: endpoint)!, profile: "media", revision: "v1", credentialID: "a")
    }
  }
  #expect(try connection().endpoint.absoluteString == "https://one.example")
}
