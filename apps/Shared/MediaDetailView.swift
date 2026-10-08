import MediaKit
import SwiftUI

struct MediaDetailView: View {
  @Bindable var model: MediaCenterModel
  @Bindable var library: MediaLibrary
  let identity: MediaIdentity
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var showReview = false
  @State private var showFields = false
  @State private var openedExternal = false
  @State private var seasonSelection: SeasonSelection?
  @State private var changing = false
  @State private var consumptionDate = Date()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        adaptiveRow {
          Text(title).font(.largeTitle.bold()).accessibilityIdentifier("detail.title")
          if !textSize.isAccessibilitySize { Spacer() }
          Button("Done") { dismiss() }
        }
        if let item = library.records[identity]?.item {
          Text(item.status).foregroundStyle(.secondary).accessibilityIdentifier("media.status")
          if let duration = item.durationMinutes { Text("\(Int(duration.rounded())) minutes").foregroundStyle(.secondary) }
          adaptiveRow {
            if let url = item.url {
              Button("Open original") {
                library.opened(identity); openedExternal = true
                #if DEBUG
                if model.synthetic == nil { openURL(url) }
                #else
                openURL(url)
                #endif
              }.buttonStyle(.borderedProminent).accessibilityIdentifier("media.open")
            }
            if let store = model.offlineVideos, let record = library.records[identity],
              let binding = library.connection.bindings.items[identity.kind.rawValue],
              let parts = record.offlineParts(binding: binding)
            {
              OfflineVideoView(store: store, videoID: identity.id, parts: parts)
            }
            if library.canEdit(identity, role: "saved") {
              Button(item.saved ? "Unsave" : "Save") { Task { changing = true; await library.edit(identity, role: "saved", value: .bool(!item.saved)); changing = false } }
                .buttonStyle(.bordered).accessibilityIdentifier("media.save").disabled(changing)
            }
          }
          if ["note", "tags", "consumedAt"].contains(where: { library.canEdit(identity, role: $0) }) {
            Button("Edit fields") { showFields = true }.buttonStyle(.bordered).accessibilityIdentifier("media.fields")
          }
          if library.canEdit(identity, role: "status"), let binding = library.connection.bindings.items[identity.kind.rawValue] {
            Menu("Change status") {
              ForEach(binding.statuses.keys.sorted(), id: \.self) { status in
                Button(status) { Task { changing = true; await library.setConsumption(identity, status: status, date: consumptionDate); changing = false } }
              }
            }.buttonStyle(.bordered).disabled(changing)
          }
          #if DEBUG
          if let synthetic = model.synthetic { Button("Revoke preview access") { synthetic.nextWriteError = .revoked }.accessibilityIdentifier("fixture.revoke"); Button("Change preview profile") { synthetic.nextWriteError = .profileChanged }.accessibilityIdentifier("fixture.profile-change") }
          if model.synthetic != nil && openedExternal { Button("Return to Media Center") { showReview = true; openedExternal = false }.accessibilityIdentifier("synthetic.return") }
          #endif
        }
        if identity.kind == .tvShow {
          Text("Episodes").font(.title2.bold())
          ForEach(Array(Set(library.episodes.compactMap(\.season))).sorted(), id: \.self) { season in
            VStack(alignment: .leading, spacing: 12) {
              adaptiveRow {
                Text(season == 0 ? "Specials" : "Season \(season)").font(.headline)
                if !textSize.isAccessibilitySize { Spacer() }
                if season > 0 {
                  Button("Mark aired episodes finished") { seasonSelection = .init(season: season, episodes: library.airedEpisodes(season: season, showID: identity.id)) }
                    .accessibilityLabel("Mark aired episodes in \(season == 0 ? "Specials" : "Season \(season)") finished")
                    .accessibilityIdentifier("season.\(season).finish")
                    .disabled(!library.episodesComplete || library.airedEpisodes(season: season, showID: identity.id).isEmpty || changing)
                }
              }
              ForEach(library.episodes.filter { $0.season == season }, id: \.identity) { episode in
                adaptiveRow {
                  VStack(alignment: .leading, spacing: 4) { Text(episode.title); Text(episode.status).font(.caption).foregroundStyle(.secondary) }
                  if !textSize.isAccessibilitySize { Spacer() }
                  if library.canEdit(episode.identity, role: "status"), let binding = library.connection.bindings.items[MediaKind.tvEpisode.rawValue] {
                    Menu("Status") { ForEach(binding.statuses.keys.sorted(), id: \.self) { status in Button(status) { Task { await library.setConsumption(episode.identity, status: status, date: consumptionDate) } } } }
                      .accessibilityLabel("Status for \(episode.title)")
                  }
                }.padding(.vertical, 8)
              }
            }.padding(18).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
          }
          if !library.episodesComplete { Text("Episode list is incomplete. Bulk changes are unavailable.").foregroundStyle(.secondary) }
          if !library.bulkResults.isEmpty {
            Text("\(library.bulkResults.filter(\.committed).count) of \(library.bulkResults.count) updated").font(.headline)
            ForEach(library.bulkResults.filter { !$0.committed }) { result in Text("Could not update \(result.title)").foregroundStyle(.errorText) }
          }
        }
        if let message = library.message { Text(message).foregroundStyle(.errorText) }
        #if DEBUG
        if let synthetic = model.synthetic { Text("Writes: \(synthetic.writeAttempts)").font(.caption).accessibilityIdentifier("fixture.writes") }
        #endif
      }.padding(28)
    }.frame(minWidth: 320, idealWidth: 620, minHeight: 400)
      .task(id: identity) { await library.loadDetail(identity); if identity.kind == .tvShow { await library.loadEpisodes(showID: identity.id) } }
      .onChange(of: scenePhase) { _, phase in if phase == .active && openedExternal { openedExternal = false; showReview = true } }
      #if os(macOS)
      // Switching apps does not change scenePhase on the Mac; returning activates the app.
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        if openedExternal { openedExternal = false; showReview = true }
      }
      #endif
      .sheet(isPresented: $showFields) { MediaUserFieldsView(library: library, identity: identity) }
      .sheet(isPresented: $showReview) { review }
      .sheet(item: $seasonSelection) { selection in seasonPreview(selection.episodes) }
  }
  private var adaptiveRow: AnyLayout {
    textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
  }
  private var title: String { library.records[identity]?.item.title ?? library.sources.first { $0.identity.kind == .tvShow && $0.identity.id == identity.id }?.title ?? "Media details" }
  private var review: some View {
    ScrollView { VStack(alignment: .leading, spacing: 18) {
      Text("Update this item?").font(.title2.bold())
      Text("Opening it doesn’t change its status. Choose a status only if you want to record what you watched or read.").foregroundStyle(.secondary)
      if library.canEdit(identity, role: "consumedAt") { DatePicker("Consumption date", selection: $consumptionDate, displayedComponents: .date) }
      if let binding = library.connection.bindings.items[identity.kind.rawValue], library.canEdit(identity, role: "status") {
        ForEach(reviewOrder(binding), id: \.self) { status in
          let record = Button(status) { Task { await library.setConsumption(identity, status: status, date: consumptionDate); library.leaveUnchanged(); showReview = false } }
          if binding.statuses[status] == .finished { record.buttonStyle(.borderedProminent) } else { record.buttonStyle(.bordered) }
        }
      }
      Button("Leave unchanged") { library.leaveUnchanged(); showReview = false }.buttonStyle(.bordered).accessibilityIdentifier("review.unchanged")
    }.padding(28) }.frame(minWidth: 300, minHeight: 360)
  }
  /// Finishing is the likely answer after watching or reading, so it leads.
  private func reviewOrder(_ binding: RecordBinding) -> [String] {
    let rank: [ConsumptionState] = [.finished, .watchedParts, .inProgress, .gaveUp, .priority, .notStarted, .other]
    func position(_ label: String) -> Int { binding.statuses[label].flatMap { rank.firstIndex(of: $0) } ?? rank.count }
    return binding.statuses.keys.sorted { (position($0), $0) < (position($1), $1) }
  }
  private func seasonPreview(_ preview: [MediaItem]) -> some View {
    ScrollView { VStack(alignment: .leading, spacing: 18) {
      Text("\(preview.count) aired episodes").font(.title2.bold())
      Text("These episodes will be marked finished individually. Future episodes and the show’s status stay unchanged.").foregroundStyle(.secondary)
      ForEach(preview, id: \.identity) { Text($0.title) }
      HStack {
        Button("Cancel") { seasonSelection = nil }
        Button("Mark finished") { seasonSelection = nil; Task { changing = true; await library.finish(preview); changing = false } }
          .accessibilityIdentifier("season.confirm").buttonStyle(.borderedProminent)
      }
    }.padding(28) }.frame(minWidth: 320, minHeight: 360)
  }
}

struct MediaUserFieldsView: View {
  @Bindable var library: MediaLibrary
  let identity: MediaIdentity
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""
  @State private var tags = Set<String>()
  @State private var date = Date()
  @State private var hasDate = false
  @State private var original: [String: CoreJSONValue] = [:]
  @State private var originalNote = ""
  @State private var originalTags = Set<String>()
  @State private var originalDate = Date()
  @State private var originalHasDate = false
  @State private var applying = false
  @State private var result: String?
  private var binding: RecordBinding? { library.connection.bindings.items[identity.kind.rawValue] }
  private var tagOptions: [String] {
    guard let binding, let column = binding.fields["tags"] else { return [] }
    return library.connection.metadata[binding.table]?.first { $0.column == column }?.options ?? []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Your fields").font(.title2.bold())
      Form {
        if library.canEdit(identity, role: "note") {
          Section("Notes") { TextEditor(text: $note).frame(minHeight: 100).accessibilityLabel("Notes").accessibilityIdentifier("edit.note") }
        }
        if library.canEdit(identity, role: "tags") {
          Section("Tags") {
            ForEach(tagOptions, id: \.self) { tag in
              Toggle(tag, isOn: Binding(get: { tags.contains(tag) }, set: { value in if value { tags.insert(tag) } else { tags.remove(tag) } }))
            }
          }
        }
        if library.canEdit(identity, role: "consumedAt") {
          Section("Consumption date") {
            Toggle("Record a date", isOn: $hasDate)
            if hasDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
          }
        }
      }
      if let result { Text(result).accessibilityIdentifier("fields.result") }
      HStack {
        Button("Done") { dismiss() }.disabled(applying)
        Spacer()
        Button("Apply") { Task { await apply() } }.disabled(applying).accessibilityIdentifier("fields.apply")
      }
    }.padding(24).frame(minWidth: 300, idealWidth: 480, minHeight: 340)
      .task { load() }
  }
  private func load() {
    guard let binding, let row = library.records[identity]?.row else { return }
    for role in ["note", "tags", "consumedAt"] {
      if let column = binding.fields[role] { original[role] = row[column] ?? .null }
    }
    if case .string(let text) = original["note"] { note = text }
    if case .string(let json) = original["tags"], let decoded = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) { tags = Set(decoded) }
    if case .string(let text) = original["consumedAt"] {
      let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
      if let parsed = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? day.date(from: text) { date = parsed; hasDate = true }
    }
    originalNote = note; originalTags = tags; originalDate = date; originalHasDate = hasDate
  }
  private func apply() async {
    guard let binding else { return }
    var values: [String: CoreJSONValue] = [:]
    if library.canEdit(identity, role: "note") {
      let value: CoreJSONValue = note.isEmpty ? .null : .string(note)
      if note != originalNote { values["note"] = value }
    }
    if library.canEdit(identity, role: "tags"), let json = try? JSONEncoder().encode(tags.sorted()), let text = String(data: json, encoding: .utf8) {
      let value = CoreJSONValue.string(text)
      if tags != originalTags { values["tags"] = value }
    }
    if library.canEdit(identity, role: "consumedAt"), let column = binding.fields["consumedAt"] {
      let dateOnly = library.connection.metadata[binding.table]?.first { $0.column == column }?.type == "date"
      let value: CoreJSONValue = hasDate ? .string(dateOnly ? FeedQueryPlan.day(date, calendar: .current) : FeedQueryPlan.timestamp(date)) : .null
      if hasDate != originalHasDate || (hasDate && date != originalDate) { values["consumedAt"] = value }
    }
    guard !values.isEmpty else { result = "No changes"; return }
    applying = true; defer { applying = false }
    if await library.editFields(identity, values: values) { result = "Updated"; load() }
    else { result = library.message ?? "Could not confirm your changes. Your draft is preserved." }
  }
}

private struct SeasonSelection: Identifiable {
  let season: Int
  let episodes: [MediaItem]
  var id: Int { season }
}
