import CryptoKit
import Foundation

/// One retained part of an offline video copy, as the YouTube offline job writes
/// it into `youtube_videos.offline_file`: concatenated in order, parts are the mp4.
public struct OfflinePart: Codable, Equatable, Sendable {
  public var key: String
  public var bytes: Int
  public var sha256: String
  public init(key: String, bytes: Int, sha256: String) {
    self.key = key
    self.bytes = bytes
    self.sha256 = sha256
  }
}

public enum OfflineVideoError: Error, Equatable, Sendable {
  case invalidManifest, unavailable
  case corruptPart(String)
}

public enum OfflineManifest {
  /// Accepts only content-addressed parts of this video (`youtube/<video>/<sha256>`).
  public static func parts(_ json: String, videoID: String) throws -> [OfflinePart] {
    guard let data = json.data(using: .utf8),
      let parts = try? JSONDecoder().decode([OfflinePart].self, from: data), !parts.isEmpty
    else { throw OfflineVideoError.invalidManifest }
    let hex = CharacterSet(charactersIn: "0123456789abcdef")
    for part in parts {
      guard part.sha256.count == 64, part.sha256.unicodeScalars.allSatisfy(hex.contains),
        part.key == "youtube/\(videoID)/\(part.sha256)", part.bytes > 0
      else { throw OfflineVideoError.invalidManifest }
    }
    return parts
  }
}

extension MediaRecord {
  /// The offline copy's parts, when the connection binds `offlineFile` and the job
  /// has published one. The row's own column is the only source.
  public func offlineParts(binding: RecordBinding) -> [OfflinePart]? {
    guard item.identity.kind == .youtubeVideo, let column = binding.fields["offlineFile"],
      case .string(let json) = row[column]
    else { return nil }
    return try? OfflineManifest.parts(json, videoID: item.identity.id)
  }
}

/// What playback depends on: a verified local file for a video's offline parts.
public protocol OfflineVideoStore: Sendable {
  func localFile(videoID: String, parts: [OfflinePart]) async -> URL?
  func download(videoID: String, parts: [OfflinePart]) async throws -> URL
}

/// Device-local offline copies. Each part is verified by size and SHA-256 before
/// the parts are joined; the joined file is moved into place only when complete.
public actor OfflineVideoCache: OfflineVideoStore {
  private let directory: URL
  private let fetch: @Sendable (String) async throws -> URL
  /// `fetch` downloads one retained file key to a temporary file it hands over.
  public init(directory: URL, fetch: @escaping @Sendable (String) async throws -> URL) {
    self.directory = directory
    self.fetch = fetch
  }

  private func url(_ videoID: String, _ parts: [OfflinePart]) -> URL {
    // A different copy (new parts) never reuses an older file.
    let digest = SHA256.hash(data: Data(parts.map(\.sha256).joined().utf8))
    let tag = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(videoID)-\(tag).mp4")
  }

  public func localFile(videoID: String, parts: [OfflinePart]) -> URL? {
    let url = url(videoID, parts)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    return size == parts.reduce(0) { $0 + $1.bytes } ? url : nil
  }

  public func download(videoID: String, parts: [OfflinePart]) async throws -> URL {
    if let existing = localFile(videoID: videoID, parts: parts) { return existing }
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appendingPathComponent("\(UUID().uuidString).partial")
    manager.createFile(atPath: partial.path, contents: nil)
    defer { try? manager.removeItem(at: partial) }
    let output = try FileHandle(forWritingTo: partial)
    defer { try? output.close() }
    for part in parts {
      let file = try await fetch(part.key)
      defer { try? manager.removeItem(at: file) }
      let input = try FileHandle(forReadingFrom: file)
      defer { try? input.close() }
      var hash = SHA256()
      var count = 0
      while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
        hash.update(data: chunk)
        count += chunk.count
        try output.write(contentsOf: chunk)
      }
      let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      guard count == part.bytes, digest == part.sha256 else {
        throw OfflineVideoError.corruptPart(part.key)
      }
    }
    try output.close()
    remove(videoID: videoID)
    let destination = url(videoID, parts)
    try manager.moveItem(at: partial, to: destination)
    return destination
  }

  /// Drops every local copy of the video.
  public func remove(videoID: String) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix("\(videoID)-") && name.hasSuffix(".mp4") {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
