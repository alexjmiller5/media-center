import Foundation

public enum HubError: Error, Equatable {
  case revoked, profileChanged, forbidden, conflict, invalidReply, invalidRequest, unavailable, uncertain
  case rejected(Int)
}
public typealias RowQuery = CoreRowsQueryRequest
public typealias RowPage = CoreRowsQueryReply
public typealias CaptureRequest = CoreCaptureRequest
public typealias CaptureReceipt = CoreCaptureReceipt

public struct ConditionalEdit: Codable, Equatable, Sendable {
  public var table: String
  public var id: String
  public var values: CoreRow
  public var expectedRevision: CoreRevision
  public init(table: String, id: String, values: CoreRow, expectedRevision: CoreRevision) {
    self.table = table
    self.id = id
    self.values = values
    self.expectedRevision = expectedRevision
  }
  private enum CodingKeys: String, CodingKey {
    case table, id, values
    case expectedRevision = "expected_revision"
  }
}
public struct PatchReceipt: Codable, Equatable, Sendable {
  public var id: String
  public var revision: CoreRevision
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Scoped HTTP transport. No replica, SQL, provider API or unconditional write fallback.
@MainActor public final class HubClient {
  public let endpoint: URL
  private let token: String
  private let session: URLSession
  private let policy: EnrollmentPolicy
  public init(endpoint: URL, token: String, configuration: URLSessionConfiguration = .ephemeral)
    throws
  {
    self.endpoint = try ConnectionIdentity(
      endpoint: endpoint, profile: "validation", revision: "validation", credentialID: "validation"
    ).endpoint
    guard !token.isEmpty,
      !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw HubError.invalidRequest
    }
    self.token = token
    policy = try EnrollmentPolicy()
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }
  public func close() { session.invalidateAndCancel() }

  public func reply(path: String, method: String = "GET", body: Data? = nil, limit: Int = 65536)
    async throws -> CoreSessionReply
  {
    var request = URLRequest(url: endpoint.appendingPathComponent(path))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw HubError.invalidReply }
    guard response.expectedContentLength <= limit else { throw HubError.invalidReply }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw HubError.invalidReply }
      data.append(byte)
    }
    let value = (try? JSONDecoder().decode(CoreJSONValue.self, from: data)) ?? .null
    return CoreSessionReply(
      status: response.statusCode, data: value,
      retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map {
        min(300, max(0, $0))
      })
  }
  private func request<T: Decodable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    mutation: Bool = false, limit: Int = 65536, as: T.Type = T.self
  ) async throws -> T {
    guard body?.count ?? 0 <= 65536 else { throw HubError.invalidRequest }
    let response: CoreSessionReply
    do { response = try await reply(path: path, method: method, body: body, limit: limit) } catch {
      // A cancelled read is the caller leaving, not an outage. A cancelled write may have been sent.
      if !mutation, error is CancellationError || (error as? URLError)?.code == .cancelled {
        throw CancellationError()
      }
      throw mutation ? HubError.uncertain : HubError.unavailable
    }
    switch response.status {
    case 200...299: break
    case 401: throw HubError.revoked
    case 403: throw HubError.forbidden
    case 409:
      if case .object(let data) = response.data, data["error"] == .string("profile_changed") {
        throw HubError.profileChanged
      }
      throw HubError.conflict
    case 400...499: throw HubError.rejected(response.status)
    default: throw mutation ? HubError.uncertain : HubError.unavailable
    }
    do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(response.data)) } catch
    { throw mutation ? HubError.uncertain : HubError.invalidReply }
  }
  public func sessionData() async throws -> CoreRow { try await request("v1/session") }
  public func consumerConfig() async throws -> CoreConsumerConfigReply {
    let reply: CoreConsumerConfigReply = try await request("v1/consumer/config")
    let _: CoreConsumerConfig = try policy.invoke("canonicalConsumerConfig", reply.config)
    return reply
  }
  public func metadata(table: String, columns: [String]) async throws -> CoreCatalogProjectionReply
  {
    let reply: CoreCatalogProjectionReply = try await request(
      "v1/catalog/projection", method: "POST",
      body: JSONEncoder().encode(CoreCatalogProjectionRequest(table: table, columns: columns)))
    guard reply.table == table, Set(reply.properties.map(\.column)) == Set(columns),
      reply.properties.count == columns.count
    else {
      throw HubError.invalidReply
    }
    return reply
  }
  public func query(_ query: RowQuery) async throws -> RowPage {
    let normalized: CoreRowsQueryRequest = try policy.invoke("normalizeRowsQuery", query)
    let result: RowPage = try await request(
      "v1/rows/query", method: "POST", body: JSONEncoder().encode(normalized),
      limit: 8 * 1024 * 1024)
    let columns = Set(query.columns)
    var seen = Set<String>()
    guard result.rows.count <= (normalized.limit ?? 50),
      result.nextCursor == nil || !(result.nextCursor?.isEmpty ?? true)
    else {
      throw HubError.invalidReply
    }
    for row in result.rows {
      guard Set(row.keys) == columns, case .string(let id) = row["id"], !id.isEmpty,
        seen.insert(id).inserted
      else {
        throw HubError.invalidReply
      }
    }
    return result
  }
  public func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt {
    guard !edit.values.isEmpty else { throw HubError.invalidRequest }
    let result: PatchReceipt = try await request(
      "v1/rows/patch", method: "POST", body: JSONEncoder().encode(edit), mutation: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard result.id == edit.id, formatter.date(from: result.revision.updatedAt) != nil,
      result.revision.hubAt == nil || formatter.date(from: result.revision.hubAt!) != nil
    else {
      throw HubError.uncertain
    }
    return result
  }
  public func submitCapture(_ capture: CaptureRequest) async throws -> CaptureReceipt {
    try validateRequestID(capture.requestId)
    let value: CoreJSONValue = try await request(
      "v1/captures/media", method: "POST", body: JSONEncoder().encode(capture), mutation: true)
    do { return try receipt(value, id: capture.requestId) } catch { throw HubError.uncertain }
  }
  public func captureReceipt(id: String) async throws -> CaptureReceipt {
    try validateRequestID(id)
    let value: CoreJSONValue = try await request("v1/captures/media/\(id)")
    do { return try receipt(value, id: id) } catch { throw HubError.invalidReply }
  }
  private func validateRequestID(_ id: String) throws {
    guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw HubError.invalidRequest }
  }
  private func receipt(_ value: CoreJSONValue, id: String) throws -> CaptureReceipt {
    try policy.invoke("validateCaptureReceipt", ["value": value, "requestId": .string(id)])
  }
}
