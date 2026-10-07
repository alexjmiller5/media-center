import Foundation

public struct MediaDraft: Codable, Equatable, Sendable, Identifiable {
  public enum Intent: String, Codable, Sendable {
    case save
    case recordConsumption = "record_consumption"
  }
  public enum Content: Codable, Equatable, Sendable {
    case capture(input: String, intent: Intent)
    case edit(ConditionalEdit)
  }
  public let id: UUID
  public var content: Content
  public init(id: UUID = UUID(), input: String, intent: Intent) {
    self.id = id
    self.content = .capture(input: input, intent: intent)
  }
  public init(id: UUID = UUID(), edit: ConditionalEdit) {
    self.id = id
    self.content = .edit(edit)
  }
}

/// Stores user input, never a background mutation queue. Only explicit discard deletes it.
public actor DraftStore {
  private struct Entry: Codable {
    let connection: ConnectionIdentity
    let draft: MediaDraft
  }
  private let directory: URL
  public init(directory: URL) { self.directory = directory }
  private func folder(_ connection: ConnectionIdentity) -> URL {
    directory.appendingPathComponent(connection.storageKey, isDirectory: true)
  }
  private func location(_ id: UUID, _ connection: ConnectionIdentity) -> URL {
    folder(connection).appendingPathComponent(id.uuidString.lowercased() + ".json")
  }
  public func save(_ draft: MediaDraft, connection: ConnectionIdentity) throws {
    let data = try JSONEncoder().encode(Entry(connection: connection, draft: draft))
    guard data.count <= 128 * 1024 else { throw MediaStorageError.invalidDraft }
    try FileManager.default.createDirectory(
      at: folder(connection), withIntermediateDirectories: true)
    let url = location(draft.id, connection)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public func load(connection: ConnectionIdentity) throws -> [MediaDraft] {
    let path = folder(connection)
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: path, includingPropertiesForKeys: [.fileSizeKey]
    )
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { url in
      guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128 * 1024
      else {
        throw MediaStorageError.invalidDraft
      }
      let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
      guard entry.connection == connection else { throw MediaStorageError.invalidDraft }
      return entry.draft
    }
  }
  public func discard(id: UUID, connection: ConnectionIdentity) throws {
    let url = location(id, connection)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
