import Foundation
import Observation
import Security
import os

private let log = Logger(subsystem: "MediaKit", category: "enrollment")

@MainActor public protocol EnrollmentTransport: MediaService {
  func reply(path: String, method: String, body: Data?, limit: Int) async throws -> CoreSessionReply
  func consumerConfig() async throws -> CoreConsumerConfigReply
  func metadata(table: String, columns: [String]) async throws -> CoreCatalogProjectionReply
}
extension HubClient: EnrollmentTransport {}

public struct MediaConnection: Codable, Equatable, Sendable {
  public let identity: ConnectionIdentity
  public let session: CoreSessionInfo
  public let bindings: MediaBindings
  public let metadata: [String: [PropertyMetadata]]
  public let capabilities: CoreJSONValue
}
public struct PendingApproval: Equatable, Sendable {
  public let url: URL
  public let code: String
}

@Observable @MainActor public final class EnrollmentSession {
  public enum State: Equatable { case idle, waiting, connected, expired, failed }
  public private(set) var state: State = .idle
  public private(set) var approval: PendingApproval?
  public private(set) var connection: MediaConnection?
  /// Why the last enrollment or reconnect was refused: the failing step and reason, never a credential.
  public private(set) var failure: String?
  /// True while a revocation could not be confirmed; `cleanupDetail` says why.
  public private(set) var cleanupPending = false
  public private(set) var cleanupDetail: String?
  public private(set) var transport: (any EnrollmentTransport)?
  @ObservationIgnored private let store: any CredentialStore
  @ObservationIgnored private let policy: EnrollmentPolicy
  @ObservationIgnored private let now: () -> TimeInterval
  @ObservationIgnored private let factory: (URL, String) throws -> any EnrollmentTransport
  @ObservationIgnored private var record: StoredCredential?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var deadline: TimeInterval = 0
  @ObservationIgnored private var nextPoll: TimeInterval = 0
  @ObservationIgnored private var polling = false
  @ObservationIgnored private var stage = "session"
  /// Never-approved candidates the hub answered 401 for: nothing to revoke unless a late approval comes.
  @ObservationIgnored private var unapproved: Set<String> = []

  public init(
    store: any CredentialStore,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    factory: @escaping (URL, String) throws -> any EnrollmentTransport = {
      try HubClient(endpoint: $0, token: $1)
    }
  ) throws {
    self.store = store
    self.now = now
    self.factory = factory
    self.policy = try EnrollmentPolicy()
  }
  public func begin(endpoint: URL, name: String, profile: String = "media-center") throws
    -> PendingApproval
  {
    guard record == nil else { throw HubError.conflict }
    let endpoint = try ConnectionIdentity(
      endpoint: endpoint, profile: profile, revision: "pending", credentialID: "pending"
    ).endpoint
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CredentialStoreError.malformed
    }
    let token = Data(bytes).base64EncodedString()
    let credential = StoredCredential(
      endpoint: endpoint, profile: profile, token: token, state: .pending)
    let approval: CoreEnrollmentApproval = try policy.invoke(
      "enrollmentApproval",
      CoreEnrollmentApprovalArgs(fingerprint: credential.fingerprint, name: name, profile: profile))
    guard let url = URL(string: endpoint.absoluteString + approval.path) else {
      throw HubError.invalidRequest
    }
    let client = try factory(endpoint, token)
    do { try store.save(credential) } catch {
      client.close()
      throw error
    }
    generation &+= 1
    record = credential
    transport = client
    connection = nil
    deadline = now() + Double(approval.policy.timeoutSeconds)
    nextPoll = now()
    polling = false
    failure = nil
    state = .waiting
    let pending = PendingApproval(url: url, code: approval.approvalCode)
    self.approval = pending
    return pending
  }
  public func poll() async {
    guard state == .waiting, let record, let transport, !polling else { return }
    if now() >= deadline {
      await expire()
      return
    }
    guard now() >= nextPoll else { return }
    let current = generation
    polling = true
    defer { if current == generation { polling = false } }
    do {
      stage = "session"
      let reply = try await transport.reply(
        path: "v1/session", method: "GET", body: nil, limit: 65536)
      guard current == generation else {
        await revoke(record)
        return
      }
      guard now() < deadline else {
        await expire()
        return
      }
      let poll: CoreEnrollmentPollResult = try policy.invoke(
        "enrollmentPollResult",
        CoreEnrollmentPollArgs(reply: reply, expectedFingerprint: record.fingerprint))
      guard poll.state == .approved else {
        nextPoll = now() + Double(poll.retryAfterSeconds ?? 5)
        return
      }
      let validated = try await validate(reply: reply, credential: record, transport: transport)
      guard current == generation else {
        await revoke(record)
        return
      }
      guard now() < deadline else {
        await expire()
        return
      }
      var active = record
      active.state = .active
      active.session = validated.session
      try store.save(active)
      self.record = active
      connection = validated
      state = .connected
      approval = nil
      // One device credential per installation: earlier ones are revoked once this one works.
      for earlier in (try? store.all()) ?? [] where earlier.state == .active && earlier.id != active.id {
        await revoke(earlier)
      }
    } catch {
      guard current == generation else { return }
      // A cancelled poll (its task ended) is not a refusal; the next poll asks again.
      if let error = error as? URLError,
        [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cancelled].contains(error.code)
      {
        nextPoll = now() + 5
      } else {
        state = .failed
        approval = nil
        fail(error)
        await revoke(record)
        if current == generation {
          self.record = nil
          self.transport = nil
        }
      }
    }
  }
  public func restore(_ credential: StoredCredential) async throws {
    guard record == nil, credential.state == .active, credential.session != nil else {
      throw HubError.invalidRequest
    }
    generation &+= 1
    let current = generation
    let client = try factory(credential.endpoint, credential.token)
    record = credential
    transport = client
    failure = nil
    stage = "session"
    do {
      let reply: CoreSessionReply
      do { reply = try await client.reply(path: "v1/session", method: "GET", body: nil, limit: 65536) }
      // A cancelled launch (the Mac window closed) is the caller leaving, never a refusal.
      catch let error as URLError { throw error.code == .cancelled ? CancellationError() : HubError.unavailable }
      let validated = try await validate(reply: reply, credential: credential, transport: client)
      guard current == generation else {
        client.close()
        return
      }
      connection = validated
      state = .connected
    } catch {
      if current == generation {
        connection = nil
        record = nil
        transport = nil
        state = .failed
        fail(error)
      }
      client.close()
      throw error
    }
  }
  public func storedConnections() throws -> [StoredCredential] {
    try store.all().filter { $0.state == .active }
  }
  public func disconnect() async {
    let old = record
    let oldTransport = transport
    generation &+= 1
    record = nil
    connection = nil
    approval = nil
    transport = nil
    polling = false
    state = .idle
    oldTransport?.close()
    if let old { await revoke(old) }
  }
  private func expire() async {
    let expiredGeneration = generation &+ 1
    await disconnect()
    if generation == expiredGeneration { state = .expired }
  }
  /// Retry only revocations. Pending approvals left by a terminated app are never resumed as active.
  public func retryCleanup() async {
    do {
      for credential in try store.all()
      where credential.state != .active && credential.id != record?.id { await revoke(credential) }
    } catch { cleanupFailed(error) }
  }
  /// Revokes a stored credential that can no longer connect (revoked, changed or refused).
  public func forget(_ credential: StoredCredential) async {
    guard credential.id != record?.id else { return }
    await revoke(credential)
  }
  private func revoke(_ credential: StoredCredential) async {
    var revoked = credential
    revoked.state = .revoking
    unapproved.remove(credential.id)
    do {
      try store.save(revoked)
      let client = try factory(credential.endpoint, credential.token)
      defer { client.close() }
      // Its own task: the caller's cancellation (SwiftUI ends the polling task when the state
      // turns failed) must not abandon a revocation that is already due.
      let reply = try await Task {
        try await client.reply(path: "v1/session", method: "POST", body: nil, limit: 65536)
      }.value
      if reply.status == 401, credential.session != nil {
        // A once-active credential the service no longer accepts is already unusable.
        try store.remove(id: credential.id)
      } else {
        let result: CoreSessionRevocationResult = try policy.invoke("sessionRevocationResult", reply)
        // A 401 for a never-approved candidate: the hub holds nothing yet. Keep it so a late
        // approval is still revoked on the next retry, but there is nothing pending to report.
        if result.state == .revoked { try store.remove(id: credential.id) } else { unapproved.insert(credential.id) }
      }
      cleanupPending = try store.all().contains {
        $0.state != .active && $0.id != record?.id && !unapproved.contains($0.id)
      }
      if !cleanupPending { cleanupDetail = nil }
    } catch { cleanupFailed(error) }
  }
  private func cleanupFailed(_ error: any Error) {
    cleanupPending = true
    cleanupDetail = "revocation: \(Self.describe(error))"
    log.error("Device revocation unconfirmed: \(Self.describe(error), privacy: .public)")
  }
  private func fail(_ error: any Error) {
    failure = "\(stage): \(Self.describe(error))"
    log.error("Enrollment refused at \(self.stage, privacy: .public): \(Self.describe(error), privacy: .public)")
  }
  /// A short, credential-free reason for logs and the connect screen.
  static func describe(_ error: any Error) -> String {
    func path(_ keys: [any CodingKey]) -> String { keys.map(\.stringValue).joined(separator: ".") }
    switch error {
    case EnrollmentPolicyError.rejected(let message): return message
    case DecodingError.keyNotFound(let key, let context): return "missing \(path(context.codingPath + [key]))"
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
      DecodingError.dataCorrupted(let context):
      return "invalid \(path(context.codingPath))"
    case let error as URLError: return "network error \(error.code.rawValue)"
    default: return String(describing: error)
    }
  }
  private func validate(
    reply: CoreSessionReply, credential: StoredCredential, transport: any EnrollmentTransport
  ) async throws -> MediaConnection {
    guard reply.status == 200 else {
      throw reply.status == 401 ? HubError.revoked : HubError.unavailable
    }
    let initial: CoreSessionInfo = try policy.invoke(
      "validateDeviceSession", CoreSessionDataArgs(data: reply.data))
    // The authenticated service owns installation-specific grants. Canonical validation
    // rejects broad scopes; bindings below additionally reject grants outside this consumer.
    let expected = CoreEnrollmentProfileExpectation(
      id: credential.profile, scopes: credential.session?.scopes ?? initial.scopes)
    let session: CoreSessionInfo = try policy.invoke(
      "validateDeviceSession", CoreSessionDataArgs(data: reply.data, expectedProfile: expected))
    guard let profile = session.enrollmentProfile,
      credential.session?.enrollmentProfile == nil
        || credential.session?.enrollmentProfile == profile,
      case .object(let data) = reply.data, let capabilities = data["capabilities"],
      try policy.invoke("supportsRowsQuery", capabilities, as: Bool.self)
    else { throw HubError.forbidden }
    stage = "consumer config"
    let config = try await transport.consumerConfig()
    let canonical: CoreConsumerConfig = try policy.invoke("canonicalConsumerConfig", config.config)
    guard config.profile == profile, canonical.namespace == "media-center" else {
      throw HubError.conflict
    }
    stage = "bindings"
    let bindings = try JSONDecoder().decode(
      MediaBindings.self, from: JSONEncoder().encode(canonical.bindings))
    guard !bindings.items.isEmpty else { throw HubError.invalidReply }
    var allowed: Set<String> = ["captures:read:media", "captures:submit:media"]
    var columns: [String: Set<String>] = [:]
    let editable: Set<String> = [
      "status", "saved", "consumedAt", "tags", "note", "follow", "feedSince",
    ]
    for binding in Array(bindings.items.values) + Array(bindings.sources.values) {
      for (role, column) in binding.fields {
        columns[binding.table, default: []].insert(column)
        allowed.insert("tables:read:\(binding.table):\(column)")
        allowed.insert("catalog:read:\(binding.table):\(column)")
        if editable.contains(role) { allowed.insert("tables:patch:\(binding.table):\(column)") }
      }
    }
    // The offline copy of a YouTube video is read through the files API; that
    // grant belongs to this consumer only while a binding carries the role.
    if bindings.items.values.contains(where: { $0.fields["offlineFile"] != nil }) {
      allowed.insert("files:read:youtube/")
    }
    stage = "grants"
    guard Set(session.scopes).isSubset(of: allowed) else { throw HubError.forbidden }
    var metadata: [String: [PropertyMetadata]] = [:]
    for table in columns.keys.sorted() {
      stage = "catalog \(table)"
      let projection = try await transport.metadata(table: table, columns: columns[table]!.sorted())
      metadata[table] = projection.properties.map {
        .init(
          column: $0.column, type: $0.type, readOnly: $0.readOnly, required: $0.required,
          description: $0.description, options: $0.options?.map(\.v))
      }
    }
    stage = "binding check"
    try bindings.validate(scopes: Set(session.scopes), metadata: metadata)
    stage = "consumer config recheck"
    guard try await transport.consumerConfig() == config else { throw HubError.conflict }
    return MediaConnection(
      identity: try .init(
        endpoint: credential.endpoint, profile: profile.id, revision: profile.revision,
        credentialID: credential.fingerprint),
      session: session, bindings: bindings, metadata: metadata, capabilities: capabilities)
  }
}
