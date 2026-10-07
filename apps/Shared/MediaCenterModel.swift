import Foundation
import MediaKit
import Observation

@Observable @MainActor final class MediaCenterModel {
  var library: MediaLibrary?
  var enrollment: EnrollmentSession?
  var error: String?
  var endpoint = ""
  var starting = false
  let workspace: MediaWorkspace
  private let snapshots: ConnectionSnapshotStore
  #if DEBUG
  var synthetic: SyntheticMediaService?
  #endif
  init() {
    let args = ProcessInfo.processInfo.arguments
    let normal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaCenter")
    var root = normal
    #if DEBUG
    if args.contains("--synthetic"), let index = args.firstIndex(of: "--test-id"), args.indices.contains(index + 1), let id = UUID(uuidString: args[index + 1]) {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCenterTests/" + id.uuidString)
    }
    #endif
    workspace = MediaWorkspace(drafts: DraftStore(directory: root.appendingPathComponent("Drafts")), cache: MediaCache(directory: root.appendingPathComponent("Cache")))
    snapshots = ConnectionSnapshotStore(directory: root.appendingPathComponent("Connections"))
    #if DEBUG
    if args.contains("--synthetic") {
      do { synthetic = try SyntheticMediaService() } catch { self.error = "Could not initialize preview data." }
      return
    }
    #endif
    do { enrollment = try EnrollmentSession(store: KeychainCredentialStore(service: Bundle.main.bundleIdentifier ?? "MediaCenter")) }
    catch { self.error = "Secure enrollment is unavailable." }
  }
  func start() async {
    guard !starting, library == nil else { return }
    starting = true; defer { starting = false }
    #if DEBUG
    if let synthetic {
      do {
        try await workspace.connect(identity: synthetic.connection.identity, service: synthetic)
        library = MediaLibrary(connection: synthetic.connection, workspace: workspace, now: synthetic.now, calendar: ProcessInfo.processInfo.arguments.contains("--buddhist-calendar") ? Calendar(identifier: .buddhist) : .current)
        await library?.refresh()
      } catch { self.error = "Could not open preview data." }
      return
    }
    #endif
    guard let enrollment else { return }
    await enrollment.retryCleanup()
    do {
      guard let credential = try enrollment.storedConnections().first else { return }
      do { try await enrollment.restore(credential); try await attach() }
      catch {
        if error as? HubError == .unavailable, let cached = await snapshots.load(credential: credential) {
          workspace.browseOffline(identity: cached.identity)
          library = MediaLibrary(connection: cached, workspace: workspace, defaults: .standard)
          await library?.refresh()
        } else { self.error = "Reconnect to validate your access and media configuration." }
      }
    } catch { self.error = "Could not read the device’s secure connection." }
  }
  func begin() -> URL? {
    guard let enrollment, let url = URL(string: endpoint) else { error = "Enter your Life Data HTTPS address."; return nil }
    do { error = nil; return try enrollment.begin(endpoint: url, name: "Media Center").url }
    catch { self.error = "Could not begin secure enrollment. Check the HTTPS address."; return nil }
  }
  func poll() async {
    guard let enrollment else { return }
    while enrollment.state == .waiting && !Task.isCancelled {
      await enrollment.poll()
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
    }
    if enrollment.state == .connected {
      do { try await attach() } catch { self.error = "Could not open the validated connection." }
    }
  }
  private func attach() async throws {
    guard let connection = enrollment?.connection, let service = enrollment?.transport else { return }
    try await workspace.connect(identity: connection.identity, service: service)
    try? await snapshots.save(connection)
    library = MediaLibrary(connection: connection, workspace: workspace, defaults: .standard)
    await library?.refresh()
  }
  func disconnect() async {
    let wasStarting = starting
    starting = true; defer { starting = wasStarting }
    let identity = library?.connection.identity
    library = nil; workspace.disconnect()
    await enrollment?.disconnect()
    if let identity { try? await snapshots.remove(identity: identity) }
  }
}
