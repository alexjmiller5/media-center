import Foundation

/// Nonsecret, last-validated configuration for offline browsing only.
/// A snapshot never authorizes writes or draft recovery; reconnect revalidates the session.
public actor ConnectionSnapshotStore {
  private let directory: URL
  public init(directory: URL) { self.directory = directory }
  private func location(_ identity: ConnectionIdentity) -> URL {
    directory.appendingPathComponent(identity.storageKey + ".json")
  }
  public func save(_ connection: MediaConnection) throws {
    let data = try JSONEncoder().encode(connection)
    guard data.count <= 256 * 1024 else { throw MediaStorageError.pageTooLarge }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = location(connection.identity)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public func load(credential: StoredCredential) -> MediaConnection? {
    guard credential.state == .active, let profile = credential.session?.enrollmentProfile,
      let identity = try? ConnectionIdentity(
        endpoint: credential.endpoint, profile: profile.id, revision: profile.revision,
        credentialID: credential.fingerprint)
    else { return nil }
    let url = location(identity)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
      let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(MediaConnection.self, from: data),
      value.identity == identity, value.session == credential.session
    else { return nil }
    return value
  }
  public func remove(identity: ConnectionIdentity) throws {
    let url = location(identity)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
