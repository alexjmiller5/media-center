import Foundation
import Testing

@testable import MediaKit

final class StubProtocol: URLProtocol, @unchecked Sendable {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
  }
  private static let state = State()
  static func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
    state.lock.lock()
    defer { state.lock.unlock() }
    state.handler = handler
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.lock.lock()
    let handler = Self.state.handler
    Self.state.lock.unlock()
    do {
      let (status, data) = try handler!(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct HubClientTests {
  func client() throws -> HubClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return try HubClient(
      endpoint: URL(string: "https://example.test")!, token: "synthetic-device-token",
      configuration: config)
  }
  let query = CoreRowsQueryRequest(table: "items", columns: ["id", "title"], limit: 2)
  var edit: ConditionalEdit {
    .init(
      table: "items", id: "one", values: ["saved": .bool(true)],
      expectedRevision: .init(updatedAt: "2026-01-01T00:00:00.000Z", hubAt: nil))
  }
  @Test func cancelledReadsAreNotOutagesButCancelledWritesStayUncertain() async throws {
    StubProtocol.install { _ in throw URLError(.cancelled) }
    await #expect(throws: CancellationError.self) { _ = try await client().query(query) }
    await #expect(throws: HubError.uncertain) { _ = try await client().patch(edit) }
  }
  @Test func revokedForbiddenAndCursorConflictRemainDistinct() async throws {
    let client = try client()
    for (status, error) in [(401, HubError.revoked), (403, .forbidden), (409, .conflict)] {
      StubProtocol.install { _ in (status, Data("{}".utf8)) }
      await #expect(throws: error) { try await client.query(query) }
    }
  }
  @Test func changedProfileIsDistinctFromARecordConflict() async throws {
    let client = try client()
    StubProtocol.install { _ in (409, Data(#"{"error":"profile_changed"}"#.utf8)) }
    await #expect(throws: HubError.profileChanged) { try await client.query(query) }
    await #expect(throws: HubError.profileChanged) { try await client.patch(edit) }
  }
  @Test func queryUsesNarrowEndpointAndRejectsUnexpectedProjections() async throws {
    let client = try client()
    StubProtocol.install { request in
      #expect(request.url?.path == "/v1/rows/query")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-device-token")
      return (200, Data(#"{"rows":[{"id":"one","title":"Example"}],"next_cursor":null}"#.utf8))
    }
    #expect(try await client.query(query).rows.count == 1)
    for body in [
      #"{"rows":[]}"#, #"{"rows":[{"id":"one","private":"bad"}],"next_cursor":null}"#,
      #"{"rows":[{"title":"no identity"}],"next_cursor":null}"#,
    ] {
      StubProtocol.install { _ in (200, Data(body.utf8)) }
      await #expect(throws: HubError.invalidReply) { try await client.query(query) }
    }
  }
  @Test func patchRequiresReceiptAndNeverRetriesUncertainWrites() async throws {
    let client = try client()
    StubProtocol.install { _ in throw URLError(.timedOut) }
    await #expect(throws: HubError.uncertain) { try await client.patch(edit) }
    StubProtocol.install { _ in
      (
        200,
        Data(
          #"{"id":"wrong","revision":{"updated_at":"2026-01-01T00:00:01.000Z","hub_at":null}}"#.utf8
        )
      )
    }
    await #expect(throws: HubError.uncertain) { try await client.patch(edit) }
    StubProtocol.install { _ in (422, Data("{}".utf8)) }
    await #expect(throws: HubError.rejected(422)) { try await client.patch(edit) }
    StubProtocol.install { _ in (409, Data("{}".utf8)) }
    await #expect(throws: HubError.conflict) { try await client.patch(edit) }
    StubProtocol.install { _ in
      (
        200,
        Data(
          #"{"id":"one","revision":{"updated_at":"2026-01-01T00:00:01.000Z","hub_at":null}}"#.utf8)
      )
    }
    #expect(try await client.patch(edit).id == "one")
  }
  @Test func captureAcceptanceIsNotASaveAndInvalidSaveIsUncertain() async throws {
    let client = try client()
    let id = "11111111-1111-4111-8111-111111111111"
    let request = CoreCaptureRequest(requestId: id, input: .init(text: "Save this"), intent: "save")
    StubProtocol.install { _ in
      (202, Data("{\"request_id\":\"\(id)\",\"state\":\"received\"}".utf8))
    }
    #expect(try await client.submitCapture(request).state == "received")
    StubProtocol.install { _ in (200, Data("{\"request_id\":\"\(id)\",\"state\":\"saved\"}".utf8)) }
    await #expect(throws: HubError.uncertain) { try await client.submitCapture(request) }
    await #expect(throws: HubError.invalidReply) { try await client.captureReceipt(id: id) }
  }
  @Test func configurationChangeAndForbiddenMetadataAreVisible() async throws {
    let client = try client()
    StubProtocol.install { _ in (409, Data("{}".utf8)) }
    await #expect(throws: HubError.conflict) { try await client.consumerConfig() }
    StubProtocol.install { _ in (403, Data("{}".utf8)) }
    await #expect(throws: HubError.forbidden) {
      try await client.metadata(table: "items", columns: ["title"])
    }
  }
}
