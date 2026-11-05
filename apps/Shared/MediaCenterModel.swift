import Foundation
import MediaKit
import Observation

@Observable @MainActor final class MediaCenterModel {
  var library: MediaLibrary?
  var enrollment: EnrollmentSession?
  var error: String?
  var endpoint = ""
  var starting = false
  var hasStarted = false
  private var connectionGeneration = 0
  let workspace: MediaWorkspace
  /// Offline video copies for the validated hub connection; nil without one.
  var offlineVideos: (any OfflineVideoStore)?
  private let cache: MediaCache
  private let snapshots: ConnectionSnapshotStore
  private let storageRoot: URL
  #if DEBUG
  var synthetic: SyntheticMediaService?
  var startupFixture: SyntheticStartupFixture?
  #endif
  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    let args = arguments
    let normal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaCenter")
    var root = normal
    #if DEBUG
    if (args.contains("--synthetic") || args.contains("--synthetic-startup")), let index = args.firstIndex(of: "--test-id"), args.indices.contains(index + 1), let id = UUID(uuidString: args[index + 1]) {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCenterTests/" + id.uuidString)
    }
    #endif
    cache = MediaCache(directory: root.appendingPathComponent("Cache"))
    workspace = MediaWorkspace(drafts: DraftStore(directory: root.appendingPathComponent("Drafts")), cache: cache)
    snapshots = ConnectionSnapshotStore(directory: root.appendingPathComponent("Connections"))
    storageRoot = root
    #if DEBUG
    if args.contains("--synthetic-startup") {
      guard root != normal else { error = "Synthetic startup requires an isolated test UUID."; return }
      do {
        let fixture = try SyntheticStartupFixture(directory: root)
        startupFixture = fixture
        enrollment = fixture.enrollment
      } catch { self.error = "Could not initialize synthetic startup." }
      return
    }
    if args.contains("--synthetic") {
      do {
        synthetic = try SyntheticMediaService()
        if args.contains("--conflicting-writes") { synthetic?.nextWriteError = .conflict }
        if args.contains("--uncertain-writes") { synthetic?.nextWriteError = .uncertain }
        if args.contains("--offline") { synthetic?.offline = true }
      } catch { self.error = "Could not initialize preview data." }
      return
    }
    #endif
    do { enrollment = try EnrollmentSession(store: KeychainCredentialStore(service: Bundle.main.bundleIdentifier ?? "MediaCenter")) }
    catch { self.error = "Secure enrollment is unavailable." }
  }
  /// Injectable secure session and isolated storage for model integration tests.
  init(enrollment: EnrollmentSession, storageRoot: URL) {
    self.enrollment = enrollment
    self.storageRoot = storageRoot
    cache = MediaCache(directory: storageRoot.appendingPathComponent("Cache"))
    workspace = MediaWorkspace(drafts: DraftStore(directory: storageRoot.appendingPathComponent("Drafts")), cache: cache)
    snapshots = ConnectionSnapshotStore(directory: storageRoot.appendingPathComponent("Connections"))
  }
  func start() async {
    guard !starting, library == nil || workspace.isBrowsingSnapshot else { return }
    let current = connectionGeneration
    hasStarted = true
    starting = true; defer { starting = false }
    #if DEBUG
    if let startupFixture {
      do { try await startupFixture.prepare() }
      catch { self.error = "Could not prepare synthetic startup."; return }
    }
    if let synthetic {
      do {
        try await workspace.connect(identity: synthetic.connection.identity, service: synthetic)
        offlineVideos = OfflineVideoCache(directory: storageRoot.appendingPathComponent("Offline")) {
          try await synthetic.retainedFile(key: $0)
        }
        library = MediaLibrary(connection: synthetic.connection, workspace: workspace, now: synthetic.now, calendar: ProcessInfo.processInfo.arguments.contains("--buddhist-calendar") ? Calendar(identifier: .buddhist) : .current)
        if ProcessInfo.processInfo.arguments.contains("--offline") {
          // Offline launch: the cached snapshot path, with no validated service.
          workspace.browseOffline(identity: synthetic.connection.identity)
        }
        await library?.refresh()
      } catch { self.error = "Could not open preview data." }
      return
    }
    #endif
    guard let enrollment else { return }
    do {
      guard let credential = try enrollment.storedConnections().first else {
        await enrollment.retryCleanup()
        return
      }
      if library == nil, let cached = await snapshots.load(credential: credential) {
        guard current == connectionGeneration, !Task.isCancelled else { return }
        workspace.browseOffline(identity: cached.identity)
        library = MediaLibrary(connection: cached, workspace: workspace, defaults: .standard)
        await library?.refresh()
      }
      guard current == connectionGeneration, !Task.isCancelled else { return }
      await enrollment.retryCleanup()
      guard current == connectionGeneration, !Task.isCancelled else { return }
      do { try await enrollment.restore(credential); try await attach() }
      catch is CancellationError { return }  // the launch was abandoned; the credential stays
      catch {
        guard current == connectionGeneration else { return }
        if error as? HubError != .unavailable {
          await reject(credential)
          self.error = "Reconnect to validate your access and media configuration."
        } else if library == nil {
          self.error = "Reconnect to validate your access and media configuration."
        }
      }
    } catch { self.error = "Could not read the device’s secure connection." }
  }
  /// A refused session cannot retain content; unsent drafts have their independent store.
  private func reject(_ credential: StoredCredential) async {
    let identity = workspace.connection
    library = nil; offlineVideos = nil; workspace.disconnect()
    if let identity {
      await cache.removePages(connection: identity)
      try? await snapshots.remove(identity: identity)
    }
    await enrollment?.forget(credential)
  }
  /// Ends an outage: a connected session retries its reads; a cached snapshot revalidates first.
  func retry() async {
    #if DEBUG
    if synthetic != nil { await library?.refresh(); return }
    #endif
    guard let library else { return }
    guard library.workspace.isBrowsingSnapshot else { await library.refresh(); return }
    guard let enrollment, !starting, let credential = try? enrollment.storedConnections().first else { return }
    starting = true; defer { starting = false }
    let current = connectionGeneration
    do { try await enrollment.restore(credential); try await attach(); error = nil }
    catch is CancellationError { return }
    catch {
      guard current == connectionGeneration else { return }
      if error as? HubError != .unavailable { await reject(credential) }
      self.error = error as? HubError == .unavailable ? nil : "Reconnect to validate your access and media configuration."
    }
  }
  func begin() -> URL? {
    guard let enrollment, let url = URL(string: endpoint) else { error = "Enter your Soma HTTPS address."; return nil }
    do { error = nil; return try enrollment.begin(endpoint: url, name: "Media Center").url }
    catch { self.error = "Could not begin secure enrollment. Check the HTTPS address."; return nil }
  }
  func poll() async {
    guard let enrollment else { return }
    while enrollment.state == .waiting && !Task.isCancelled {
      await enrollment.poll()
      try? await Task.sleep(for: .seconds(1))
    }
    // SwiftUI cancels this polling task as soon as the state turns connected; attach in a task of its own.
    if enrollment.state == .connected {
      await Task {
        do { try await attach() } catch { self.error = "Could not open the validated connection." }
      }.value
    }
  }
  private func attach() async throws {
    guard let connection = enrollment?.connection, let service = enrollment?.transport else { return }
    let current = connectionGeneration
    try await workspace.connect(identity: connection.identity, service: service)
    guard current == connectionGeneration, workspace.connection == connection.identity else { return }
    if let hub = service as? HubClient {
      offlineVideos = OfflineVideoCache(directory: storageRoot.appendingPathComponent("Offline")) {
        try await hub.downloadFile(key: $0)
      }
    }
    if library?.connection != connection {
      library = MediaLibrary(connection: connection, workspace: workspace, defaults: .standard)
    }
    try? await snapshots.save(connection)
    guard current == connectionGeneration else { return }
    await library?.refresh()
  }
  func disconnect() async {
    connectionGeneration += 1
    let wasStarting = starting
    starting = true; defer { starting = wasStarting }
    let identity = library?.connection.identity
    library = nil; offlineVideos = nil; workspace.disconnect()
    await enrollment?.disconnect()
    if let identity { try? await snapshots.remove(identity: identity) }
  }
}
