import AVKit
import MediaKit
import SwiftUI

/// Download/play controls for a video's offline copy (`offlineFile` binding). The
/// copy lives in the device cache; playing it needs no network.
struct OfflineVideoView: View {
  let store: any OfflineVideoStore
  let videoID: String
  let parts: [OfflinePart]
  @State private var local: URL?
  @State private var downloading = false
  @State private var failed = false
  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let local {
        Button("Play offline") { player = AVPlayer(url: local) }
          .accessibilityIdentifier("media.offline.play")
      } else if downloading {
        ProgressView().accessibilityLabel("Downloading for offline playback")
      } else {
        Button(failed ? "Retry download" : "Download") {
          Task {
            downloading = true; failed = false
            do { local = try await store.download(videoID: videoID, parts: parts) } catch { failed = true }
            downloading = false
          }
        }
        .accessibilityLabel(failed ? "Retry download for offline playback" : "Download for offline playback")
        .accessibilityIdentifier("media.offline.download")
      }
    }
    .buttonStyle(.bordered)
    .task(id: parts) { local = await store.localFile(videoID: videoID, parts: parts) }
    .sheet(isPresented: Binding(get: { player != nil }, set: { if !$0 { player?.pause(); player = nil } })) {
      if let player {
        VideoPlayer(player: player).frame(minWidth: 320, minHeight: 200).onAppear { player.play() }
      }
    }
  }
}
