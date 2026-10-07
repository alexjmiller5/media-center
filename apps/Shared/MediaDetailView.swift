import MediaKit
import SwiftUI

struct MediaDetailView: View {
  @Bindable var model: MediaCenterModel
  @Bindable var library: MediaLibrary
  let identity: MediaIdentity
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var showReview = false
  @State private var openedExternal = false
  @State private var preview: [MediaItem] = []
  @State private var confirmingSeason = false
  @State private var changing = false
  @State private var consumptionDate = Date()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack { Text(title).font(.largeTitle.bold()); Spacer(); Button("Done") { dismiss() } }
        if let item = library.records[identity]?.item {
          Text(item.status).foregroundStyle(.secondary)
          if let duration = item.durationMinutes { Text("\(Int(duration.rounded())) minutes").foregroundStyle(.secondary) }
          HStack {
            if let url = item.url {
              Button("Open original") {
                library.opened(identity); openedExternal = true
                #if DEBUG
                if model.synthetic == nil { openURL(url) }
                #else
                openURL(url)
                #endif
              }.accessibilityIdentifier("media.open")
            }
            if library.canEdit(identity, role: "saved") {
              Button(item.saved ? "Unsave" : "Save") { Task { changing = true; await library.edit(identity, role: "saved", value: .bool(!item.saved)); changing = false } }
                .accessibilityIdentifier("media.save").disabled(changing)
            }
          }
          if library.canEdit(identity, role: "status"), let binding = library.connection.bindings.items[identity.kind.rawValue] {
            Menu("Change status") {
              ForEach(binding.statuses.keys.sorted(), id: \.self) { status in
                Button(status) { Task { changing = true; await library.setConsumption(identity, status: status, date: consumptionDate); changing = false } }
              }
            }.disabled(changing)
          }
          #if DEBUG
          if model.synthetic != nil && openedExternal { Button("Return to Media Center") { showReview = true; openedExternal = false }.accessibilityIdentifier("synthetic.return") }
          #endif
        }
        if identity.kind == .tvShow {
          Text("Episodes").font(.title2.bold())
          ForEach(Array(Set(library.episodes.compactMap(\.season))).sorted(), id: \.self) { season in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text(season == 0 ? "Specials" : "Season \(season)").font(.headline)
                Spacer()
                if season > 0 {
                  Button("Mark aired episodes finished") { preview = library.airedEpisodes(season: season); confirmingSeason = true }
                    .accessibilityIdentifier("season.\(season).finish")
                    .disabled(!library.episodesComplete || library.airedEpisodes(season: season).isEmpty || changing)
                }
              }
              ForEach(library.episodes.filter { $0.season == season }, id: \.identity) { episode in
                HStack {
                  VStack(alignment: .leading, spacing: 4) { Text(episode.title); Text(episode.status).font(.caption).foregroundStyle(.secondary) }
                  Spacer()
                  if library.canEdit(episode.identity, role: "status"), let binding = library.connection.bindings.items[MediaKind.tvEpisode.rawValue] {
                    Menu("Status") { ForEach(binding.statuses.keys.sorted(), id: \.self) { status in Button(status) { Task { await library.setConsumption(episode.identity, status: status, date: consumptionDate) } } } }
                  }
                }.padding(.vertical, 8)
              }
            }.padding(18).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
          }
          if !library.episodesComplete { Text("Episode list is incomplete. Bulk changes are unavailable.").foregroundStyle(.secondary) }
          if !library.bulkResults.isEmpty {
            Text("\(library.bulkResults.filter(\.committed).count) of \(library.bulkResults.count) updated").font(.headline)
            ForEach(library.bulkResults.filter { !$0.committed }) { result in Text("Could not update \(result.title)").foregroundStyle(.red) }
          }
        }
        if let message = library.message { Text(message).foregroundStyle(.red) }
        #if DEBUG
        if let synthetic = model.synthetic { Text("Writes: \(synthetic.writeCount)").font(.caption).accessibilityIdentifier("fixture.writes") }
        #endif
      }.padding(28)
    }.frame(minWidth: 320, idealWidth: 620, minHeight: 400)
      .task(id: identity) { if identity.kind == .tvShow { await library.loadEpisodes(showID: identity.id) } }
      .onChange(of: scenePhase) { _, phase in if phase == .active && openedExternal { openedExternal = false; showReview = true } }
      .sheet(isPresented: $showReview) { review }
      .sheet(isPresented: $confirmingSeason) { seasonPreview }
  }
  private var title: String { library.records[identity]?.item.title ?? library.sources.first { $0.identity.kind == .tvShow && $0.identity.id == identity.id }?.title ?? "Media details" }
  private var review: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Update this item?").font(.title2.bold())
      Text("Opening it doesn’t change its status. Choose a status only if you want to record what you watched or read.").foregroundStyle(.secondary)
      if library.canEdit(identity, role: "consumedAt") { DatePicker("Consumption date", selection: $consumptionDate, displayedComponents: .date) }
      if let binding = library.connection.bindings.items[identity.kind.rawValue], library.canEdit(identity, role: "status") {
        ForEach(binding.statuses.keys.sorted(), id: \.self) { status in
          Button(status) { Task { await library.setConsumption(identity, status: status, date: consumptionDate); library.leaveUnchanged(); showReview = false } }
        }
      }
      Button("Leave unchanged") { library.leaveUnchanged(); showReview = false }.accessibilityIdentifier("review.unchanged")
    }.padding(28).frame(minWidth: 300)
  }
  private var seasonPreview: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("\(preview.count) aired episodes").font(.title2.bold())
      Text("These episodes will be marked finished individually. Future episodes and the show’s status stay unchanged.").foregroundStyle(.secondary)
      ForEach(preview, id: \.identity) { Text($0.title) }
      HStack {
        Button("Cancel") { confirmingSeason = false }
        Button("Mark finished") { confirmingSeason = false; Task { changing = true; await library.finish(preview); changing = false } }
          .accessibilityIdentifier("season.confirm").buttonStyle(.borderedProminent)
      }
    }.padding(28).frame(minWidth: 320)
  }
}
