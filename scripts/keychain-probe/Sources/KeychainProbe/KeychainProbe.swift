import Foundation
import MediaKit
import Security

/// Exercises the production KeychainCredentialStore under the signed app's
/// identity: an unauthorized identity fails here before notarization.
@main @MainActor
struct KeychainProbe {
  static func main() {
    do {
      try run()
      print("Data Protection Keychain create/read/update/delete passed")
    } catch {
      FileHandle.standardError.write(Data("Keychain probe failed: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Failure: Error, CustomStringConvertible { let description: String }

  static func run() throws {
    let service = "media-center.release-probe.\(UUID().uuidString)"
    let store = KeychainCredentialStore(service: service)
    func require(_ condition: Bool, _ stage: String) throws {
      if !condition { throw Failure(description: "stage: \(stage)") }
    }
    func credential(_ state: String) throws -> StoredCredential {
      let json = #"{"endpoint":"https://fixture.invalid","profile":"probe","token":"synthetic","state":"\#(state)"}"#
      return try JSONDecoder().decode(StoredCredential.self, from: Data(json.utf8))
    }
    let pending = try credential("pending")
    defer { try? store.remove(id: pending.id) }
    try require(try store.all().isEmpty, "empty read")
    try store.save(pending)
    try require(try store.all().map(\.state) == [.pending], "create readback")
    try store.save(try credential("active"))
    try require(try store.all().map(\.state) == [.active], "update readback")
    // Inspect the item itself: dropping the Data Protection flag in product
    // code must not let this pass against the file-based keychain.
    var attributes: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: pending.id,
        kSecUseDataProtectionKeychain: true,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary, &attributes)
    try require(status == errSecSuccess, "Data Protection attributes status \(status)")
    let accessible = (attributes as? [String: Any])?[kSecAttrAccessible as String] as? String
    try require(
      accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, "device-only accessibility")
    try store.remove(id: pending.id)
    try require(try store.all().isEmpty, "delete readback")
  }
}
