import Foundation
import JavaScriptCore

public enum EnrollmentPolicyError: Error, Equatable { case unavailable, invalidReply }

/// Thin JSC adapter. All enrollment decisions execute the pinned canonical service policy.
@MainActor public final class EnrollmentPolicy {
  private let context: JSContext
  public init() throws {
    guard let context = JSContext(),
      let resource = Bundle.module.url(forResource: "enrollment-policy", withExtension: "js")
    else { throw EnrollmentPolicyError.unavailable }
    self.context = context
    context.evaluateScript(try String(contentsOf: resource, encoding: .utf8))
    guard context.exception == nil, context.objectForKeyedSubscript("mediaPolicy")?.isObject == true
    else {
      throw EnrollmentPolicyError.unavailable
    }
  }
  public func call(_ operation: String, arguments: Data) throws -> Data {
    guard arguments.count <= 65536, let input = String(data: arguments, encoding: .utf8) else {
      throw EnrollmentPolicyError.invalidReply
    }
    context.exception = nil
    let value = context.objectForKeyedSubscript("mediaPolicy")?.call(withArguments: [
      operation, input,
    ])
    guard context.exception == nil, value?.isString == true, let string = value?.toString(),
      let result = string.data(using: .utf8), result.count <= 65536
    else { throw EnrollmentPolicyError.invalidReply }
    return result
  }
  public func invoke<Input: Encodable, Output: Decodable>(
    _ operation: String, _ arguments: Input, as: Output.Type = Output.self
  ) throws -> Output {
    try JSONDecoder().decode(
      Output.self, from: call(operation, arguments: JSONEncoder().encode(arguments)))
  }
}
