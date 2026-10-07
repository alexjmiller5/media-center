import CryptoKit
import Foundation

public enum MediaStorageError: Error, Equatable {
  case invalidEndpoint, invalidConnection, pageTooLarge, invalidDraft
}

/// Public connection facts only. credentialID is a fingerprint, never a bearer token.
public struct ConnectionIdentity: Codable, Hashable, Sendable {
  public let endpoint: URL
  public let profile: String
  public let revision: String
  public let credentialID: String
  public init(endpoint: URL, profile: String, revision: String, credentialID: String) throws {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil
    else { throw MediaStorageError.invalidEndpoint }
    guard !profile.isEmpty, !revision.isEmpty, !credentialID.isEmpty else {
      throw MediaStorageError.invalidConnection
    }
    components.scheme = "https"
    components.host = host.lowercased()
    if components.port == 443 { components.port = nil }
    while components.path.hasSuffix("/") { components.path.removeLast() }
    guard let canonical = components.url else { throw MediaStorageError.invalidEndpoint }
    self.endpoint = canonical
    self.profile = profile
    self.revision = revision
    self.credentialID = credentialID
  }
  var storageKey: String {
    // Length-delimited JSON prevents boundary collisions between fields.
    let data = try! JSONEncoder().encode([endpoint.absoluteString, profile, revision, credentialID])
    return Self.digest(data)
  }
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct CachedMediaPage: Codable, Equatable, Sendable {
  public var items: [MediaItem]
  public var rows: [CoreRow]
  public var nextCursor: String?
  public init(items: [MediaItem], nextCursor: String?, rows: [CoreRow] = []) {
    self.items = items
    self.rows = rows
    self.nextCursor = nextCursor
  }
}

/// Disposable, bounded content. Drafts and credentials have separate stores.
public actor MediaCache {
  private struct Entry: Codable {
    let connection: ConnectionIdentity
    let key: String
    let page: CachedMediaPage
  }
  private let directory: URL
  private let maxPages: Int
  private let maxBytes: Int
  public init(directory: URL, maxPages: Int = 50, maxBytes: Int = 50 * 1024 * 1024) {
    self.directory = directory
    self.maxPages = min(50, max(1, maxPages))
    self.maxBytes = min(50 * 1024 * 1024, max(1, maxBytes))
  }
  private func location(key: String, connection: ConnectionIdentity) -> URL {
    directory.appendingPathComponent(
      "\(connection.storageKey)-\(ConnectionIdentity.digest(Data(key.utf8))).json")
  }
  public func page(key: String, connection: ConnectionIdentity, now: Date = Date())
    -> CachedMediaPage?
  {
    let url = location(key: key, connection: connection)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maxBytes, let data = try? Data(contentsOf: url),
      let entry = try? JSONDecoder().decode(Entry.self, from: data),
      entry.connection == connection, entry.key == key, entry.page.items.count <= 200,
      entry.page.rows.count <= 200
    else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    return entry.page
  }
  public func store(
    _ page: CachedMediaPage, key: String, connection: ConnectionIdentity, now: Date = Date()
  ) throws {
    let data = try JSONEncoder().encode(Entry(connection: connection, key: key, page: page))
    guard page.items.count <= 200, page.rows.count <= 200, data.count <= maxBytes else {
      throw MediaStorageError.pageTooLarge
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = location(key: key, connection: connection)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.modificationDate: now, .posixPermissions: 0o600], ofItemAtPath: url.path)
    try evict()
  }
  private func entries() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    )
    .filter {
      $0.pathExtension == "json"
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }
  private func evict() throws {
    var entries: [(url: URL, size: Int, date: Date)] = try entries().map { url in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return (
        url: url, size: values.fileSize ?? 0,
        date: values.contentModificationDate ?? Date.distantPast
      )
    }
    entries.sort { a, b in
      if a.date == b.date { return a.url.lastPathComponent < b.url.lastPathComponent }
      return a.date < b.date
    }
    var bytes = entries.reduce(0) { $0 + $1.size }
    while entries.count > maxPages || bytes > maxBytes {
      let entry = entries.removeFirst()
      try FileManager.default.removeItem(at: entry.url)
      bytes -= entry.size
    }
  }
  public func removePages(connection: ConnectionIdentity) {
    for url in (try? entries()) ?? []
    where url.lastPathComponent.hasPrefix(connection.storageKey + "-") {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
