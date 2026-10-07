import MediaKit
import SwiftUI

@main struct MediaCenterApp: App {
  @State private var model = MediaCenterModel()
  @NSApplicationDelegateAdaptor(MediaCenterDelegate.self) private var delegate
  @Environment(\.openWindow) private var openWindow
  var body: some Scene {
    let _ = delegate.showMainWindow = { openWindow(id: "main") }
    WindowGroup("Media Center", id: "main") {
      MediaCenterRoot(model: model).frame(minWidth: 760, minHeight: 540)
    }
  }
}

@MainActor final class MediaCenterDelegate: NSObject, NSApplicationDelegate {
  var showMainWindow: (() -> Void)?
  func applicationDidFinishLaunching(_ notification: Notification) {
    if NSApplication.shared.windows.isEmpty { showMainWindow?() }
  }
}
