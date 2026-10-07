import MediaKit
import SwiftUI

@main struct MediaCenterApp: App {
  @State private var model = MediaCenterModel()
  var body: some Scene {
    if #available(macOS 15, *) {
      WindowGroup { MediaCenterRoot(model: model).frame(minWidth: 760, minHeight: 540) }.defaultLaunchBehavior(.presented)
    } else {
      WindowGroup { MediaCenterRoot(model: model).frame(minWidth: 760, minHeight: 540) }
    }
  }
}
