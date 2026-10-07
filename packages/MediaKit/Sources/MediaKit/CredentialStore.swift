import Foundation
import Security

public struct StoredCredential: Codable, Sendable {
  public enum State: String, Codable, Sendable { case pending, active, revoking }
  public let endpoint: URL
  public let profile: String
  public let token: String
  public var state: State
  public var session: CoreSessionInfo?
  public var id: String {
    ConnectionIdentity.digest(Data((endpoint.absoluteString + "\n" + fingerprint).utf8))
  }
  public var fingerprint: String { ConnectionIdentity.digest(Data(token.utf8)) }
}

@MainActor public protocol CredentialStore {
  func all() throws -> [StoredCredential]
  func save(_ credential: StoredCredential) throws
  func remove(id: String) throws
}
public enum CredentialStoreError: Error {
  case status(OSStatus)
  case malformed
}

/// Device-local credentials. No plaintext fallback, synchronization or shared access group.
@MainActor public final class KeychainCredentialStore: CredentialStore {
  private let service: String
  public init(service: String) { self.service = service }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
  }
  public func all() throws -> [StoredCredential] {
    var query = query
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw CredentialStoreError.status(status) }
    guard let values = result as? [Data] else { throw CredentialStoreError.malformed }
    return try values.map { try JSONDecoder().decode(StoredCredential.self, from: $0) }
  }
  public func save(_ credential: StoredCredential) throws {
    var query = query
    query[kSecAttrAccount as String] = credential.id
    let data = try JSONEncoder().encode(credential)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw CredentialStoreError.status(status) }
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(query as CFDictionary, nil)
    guard added == errSecSuccess else { throw CredentialStoreError.status(added) }
  }
  public func remove(id: String) throws {
    var query = query
    query[kSecAttrAccount as String] = id
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.status(status)
    }
  }
}
