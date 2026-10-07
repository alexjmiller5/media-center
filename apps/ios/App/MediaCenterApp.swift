import MediaKit
import SwiftUI

@main struct MediaCenterApp: App {
  @State private var model = MediaCenterModel()
  var body: some Scene {
    WindowGroup { MediaCenterRoot(model: model) }
  }
}
