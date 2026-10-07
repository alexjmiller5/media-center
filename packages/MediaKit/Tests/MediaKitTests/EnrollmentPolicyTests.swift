import Foundation
import Testing

@testable import MediaKit

@Test @MainActor func canonicalEnrollmentFixturesRunInJavaScriptCore() throws {
  let policy = try EnrollmentPolicy()
  let fixtures = try #require(
    Bundle.module.url(forResource: "enrollment-policy", withExtension: "json"))
  let root = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: fixtures)) as? [String: Any])
  let cases = try #require(root["cases"] as? [[String: Any]])
  #expect(cases.count > 10)
  for fixture in cases {
    let operation = try #require(fixture["operation"] as? String)
    let args = try JSONSerialization.data(withJSONObject: fixture["args"]!)
    if fixture["error"] != nil {
      #expect(throws: (any Error).self, Comment(rawValue: fixture["name"] as! String)) {
        try policy.call(operation, arguments: args)
      }
    } else {
      let actual = try policy.call(operation, arguments: args)
      let want = try JSONSerialization.data(
        withJSONObject: fixture["want"]!, options: [.sortedKeys, .fragmentsAllowed])
      let normalized = try JSONSerialization.data(
        withJSONObject: JSONSerialization.jsonObject(with: actual, options: .fragmentsAllowed),
        options: [.sortedKeys, .fragmentsAllowed])
      #expect(normalized == want, Comment(rawValue: fixture["name"] as! String))
    }
  }
}

@Test @MainActor func canonicalCaptureReceiptsRequireVerifiedIdentity() throws {
  let policy = try EnrollmentPolicy()
  let id = "11111111-1111-4111-8111-111111111111"
  let accepted = Data(
    "{\"value\":{\"request_id\":\"\(id)\",\"state\":\"received\"},\"requestId\":\"\(id)\"}".utf8)
  let receipt = try JSONDecoder().decode(
    CoreCaptureReceipt.self, from: policy.call("validateCaptureReceipt", arguments: accepted))
  #expect(receipt.state == "received")
  #expect(receipt.item == nil)
  #expect(throws: (any Error).self) {
    try policy.call(
      "validateCaptureReceipt",
      arguments: Data(
        "{\"value\":{\"request_id\":\"\(id)\",\"state\":\"saved\"},\"requestId\":\"\(id)\"}".utf8))
  }
}
