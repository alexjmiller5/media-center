import CryptoKit
import Foundation
import Testing

@testable import MediaKit

private func directory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
private func hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private let video = "dQw4w9WgXcQ"
private func part(_ data: Data) -> OfflinePart {
  OfflinePart(key: "youtube/\(video)/\(hex(data))", bytes: data.count, sha256: hex(data))
}
/// Serves synthetic retained files from memory, counting downloads.
private final class FakeFiles: @unchecked Sendable {
  var blobs: [String: Data] = [:]
  var downloads: [String] = []
  let root: URL
  init(root: URL) { self.root = root }
  func download(_ key: String) async throws -> URL {
    downloads.append(key)
    guard let data = blobs[key] else { throw OfflineVideoError.unavailable }
    let url = root.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
  }
}

@Test func manifestParsesOrderedPartsOfThatVideo() throws {
  let a = Data("first".utf8), b = Data("second".utf8)
  let json = String(data: try JSONEncoder().encode([part(a), part(b)]), encoding: .utf8)!
  #expect(try OfflineManifest.parts(json, videoID: video) == [part(a), part(b)])
}

@Test(arguments: [
  "", "{}", "[]", #"[{"key":"youtube/other12345/x","bytes":1,"sha256":"x"}]"#,
  #"[{"key":"youtube/dQw4w9WgXcQ/../../etc","bytes":1,"sha256":"aa"}]"#,
  #"[{"key":"captures/dQw4w9WgXcQ/aa","bytes":1,"sha256":"aa"}]"#,
])
func manifestRejectsAnythingButContentAddressedPartsOfTheVideo(_ json: String) {
  #expect(throws: OfflineVideoError.invalidManifest) { try OfflineManifest.parts(json, videoID: video) }
}

@Test(arguments: [
  "youtube/aaaaaaaaaaa/", "captures/\(video)/", "youtube/\(video)/../", "youtube/\(video)/x",
])
func manifestRejectsValidChecksumsUnderAnyOtherKey(_ prefix: String) throws {
  let sha = String(repeating: "a", count: 64)
  let json = #"[{"key":""# + prefix + sha + #"","bytes":1,"sha256":""# + sha + #""}]"#
  #expect(throws: OfflineVideoError.invalidManifest) { try OfflineManifest.parts(json, videoID: video) }
  let good = #"[{"key":"youtube/\#(video)/\#(sha)","bytes":1,"sha256":"\#(sha)"}]"#
  #expect(try OfflineManifest.parts(good, videoID: video).count == 1)
}

@Test func cacheAssemblesVerifiedPartsInOrderAndReusesTheCopy() async throws {
  let root = try directory()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = FakeFiles(root: root)
  let a = Data(repeating: 1, count: 1000), b = Data(repeating: 2, count: 10)
  files.blobs = [part(a).key: a, part(b).key: b]
  let cache = OfflineVideoCache(directory: root.appendingPathComponent("Offline")) {
    try await files.download($0)
  }
  #expect(await cache.localFile(videoID: video, parts: [part(a), part(b)]) == nil)
  let url = try await cache.download(videoID: video, parts: [part(a), part(b)])
  #expect(try Data(contentsOf: url) == a + b)
  #expect(url.pathExtension == "mp4")
  #expect(try await cache.download(videoID: video, parts: [part(a), part(b)]) == url)
  #expect(await cache.localFile(videoID: video, parts: [part(a), part(b)]) == url)
  #expect(files.downloads.count == 2)
  await cache.remove(videoID: video)
  #expect(await cache.localFile(videoID: video, parts: [part(a), part(b)]) == nil)
}

@Test func corruptPartIsRejectedAndLeavesNoCopy() async throws {
  let root = try directory()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = FakeFiles(root: root)
  let a = Data("expected".utf8)
  files.blobs = [part(a).key: Data("tampered".utf8)]
  let cache = OfflineVideoCache(directory: root.appendingPathComponent("Offline")) {
    try await files.download($0)
  }
  await #expect(throws: OfflineVideoError.corruptPart(part(a).key)) {
    try await cache.download(videoID: video, parts: [part(a)])
  }
  #expect(await cache.localFile(videoID: video, parts: [part(a)]) == nil)
}

@Test func recordExposesOfflinePartsOnlyThroughItsBinding() throws {
  let a = Data("clip".utf8)
  let json = String(data: try JSONEncoder().encode([part(a)]), encoding: .utf8)!
  var row: CoreRow = [
    "id": .string(video), "title": .string("t"), "status": .string("Not Started"),
    "updated_at": .string("2026-10-08T12:00:00.000Z"), "hub_at": .null,
    "offline_file": .string(json),
  ]
  var fields = ["id": "id", "title": "title", "status": "status", "updatedAt": "updated_at",
                "hubAt": "hub_at"]
  let unbound = RecordBinding(table: "youtube_videos", fields: fields, statuses: ["Not Started": .notStarted])
  #expect(try MediaRecord(kind: .youtubeVideo, row: row, binding: unbound).offlineParts(binding: unbound) == nil)
  fields["offlineFile"] = "offline_file"
  let bound = RecordBinding(table: "youtube_videos", fields: fields, statuses: ["Not Started": .notStarted])
  let record = try MediaRecord(kind: .youtubeVideo, row: row, binding: bound)
  #expect(record.offlineParts(binding: bound) == [part(a)])
  row["offline_file"] = .null
  #expect(try MediaRecord(kind: .youtubeVideo, row: row, binding: bound).offlineParts(binding: bound) == nil)
}

@Test func offlineFileBindsOnlyToAJsonColumnWithItsGrants() throws {
  let fields = [
    "id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at",
    "hubAt": "hub_at", "deletedAt": "deleted_at", "offlineFile": "offline_file",
  ]
  let bindings = MediaBindings(
    items: ["youtubeVideo": RecordBinding(table: "videos", fields: fields, statuses: ["Open": .notStarted])],
    sources: [:])
  func properties(offlineType: String) -> [PropertyMetadata] {
    fields.values.map { column in
      PropertyMetadata(
        column: column,
        type: column == "offline_file" ? offlineType
          : column == "saved" ? "bool" : column == "status" ? "select" : "text",
        readOnly: false, options: column == "status" ? ["Open"] : nil)
    }
  }
  let scopes = Set(fields.values.flatMap { ["tables:read:videos:\($0)", "catalog:read:videos:\($0)"] })
  try bindings.validate(scopes: scopes, metadata: ["videos": properties(offlineType: "json")])
  #expect(throws: BindingError.incompatibleType("videos", "offline_file")) {
    try bindings.validate(scopes: scopes, metadata: ["videos": properties(offlineType: "text")])
  }
  #expect(throws: BindingError.insufficientScope("videos", "offline_file")) {
    try bindings.validate(
      scopes: scopes.subtracting(["tables:read:videos:offline_file"]),
      metadata: ["videos": properties(offlineType: "json")])
  }
}
