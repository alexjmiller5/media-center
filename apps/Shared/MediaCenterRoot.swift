import MediaKit
import SwiftUI

struct MediaCenterRoot: View {
  @Bindable var model: MediaCenterModel
  @Environment(\.openURL) private var openURL
  var body: some View {
    Group {
      if let library = model.library, model.workspace.connection == library.connection.identity { MediaLibraryView(model: model, library: library) }
      else {
        VStack(alignment: .leading, spacing: 20) {
          Text("Media Center").font(.largeTitle.bold())
          Text("A place for what you want to read and watch.").foregroundStyle(.secondary)
          Text("Connect to Life Data").font(.title2.bold())
          TextField("HTTPS service address", text: $model.endpoint).textFieldStyle(.roundedBorder).accessibilityIdentifier("enroll.endpoint")
          if let approval = model.enrollment?.approval {
            Text("Approve this device in Life Data. Verify the code:")
            Text(approval.code).font(.title.monospaced()).textSelection(.enabled)
            Button("Open approval") { openURL(approval.url) }
            Button("Cancel") { Task { await model.disconnect() } }
          } else {
            Button("Connect") { if let url = model.begin() { openURL(url) } }.buttonStyle(.borderedProminent).disabled(model.starting)
          }
          if let error = model.error { Text(error).foregroundStyle(.red) }
          if model.enrollment?.state == .expired { Text("Approval expired. Connect again to request a new code.") }
          if model.enrollment?.cleanupPending == true { Text("A previous device request still needs revocation. Reconnect when the service is available.").foregroundStyle(.secondary) }
          if model.starting { ProgressView() }
        }.padding(32).frame(maxWidth: 480)
      }
    }.onChange(of: model.workspace.error) { _, error in
      if error == .revoked || error == .profileChanged { Task { await model.disconnect(); model.error = error == .revoked ? "This device’s access was revoked. Reconnect to continue." : "Your media configuration changed. Reconnect to validate access." } }
    }.task { await model.start() }
      .task(id: model.enrollment?.state) { if model.enrollment?.state == .waiting { await model.poll() } }
  }
}

struct MediaLibraryView: View {
  @Bindable var model: MediaCenterModel
  @Bindable var library: MediaLibrary
  @State private var selection: MediaDetailSelection?
  @State private var sourceSelection: SourceDetailSelection?
  @State private var showFilters = false
  @State private var showAdd = false
  @State private var showDrafts = false
  @State private var showSettings = false
  var body: some View {
    #if os(macOS)
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 6) {
        Text("MEDIA CENTER").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 18)
        ForEach(LibrarySection.allCases, id: \.self) { section in
          Button { library.section = section; selection = nil; Task { await library.refresh() } } label: {
            Text(section.rawValue.capitalized).font(.body.weight(library.section == section ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
          }.buttonStyle(.plain).background(library.section == section ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("nav.\(section.rawValue)")
        }
        Spacer()
        Button("Connection") { showSettings = true }
      }.padding(18).navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: { content }
    .sheet(item: $selection) { id in MediaDetailView(model: model, library: library, identity: id.id) }
    .sheet(isPresented: $showFilters) { FeedFiltersView(library: library) }
    .sheet(isPresented: $showAdd) { MediaCaptureView(library: library) }
    .sheet(isPresented: $showDrafts) { MediaDraftsView(library: library) }
    .sheet(item: $sourceSelection) { SourceDetailsView(library: library, identity: $0.id) }
    .sheet(isPresented: $showSettings) { connection }
    #else
    TabView(selection: $library.section) {
      ForEach(LibrarySection.allCases, id: \.self) { section in
        NavigationStack { content }
          .tabItem { Text(section.rawValue.capitalized) }.tag(section).accessibilityIdentifier("nav.\(section.rawValue)")
      }
    }.onChange(of: library.section) { _, _ in selection = nil; Task { await library.refresh() } }
    .sheet(item: $selection) { id in NavigationStack { MediaDetailView(model: model, library: library, identity: id.id) } }
    .sheet(isPresented: $showFilters) { FeedFiltersView(library: library) }
    .sheet(isPresented: $showAdd) { MediaCaptureView(library: library) }
    .sheet(isPresented: $showDrafts) { MediaDraftsView(library: library) }
    .sheet(item: $sourceSelection) { SourceDetailsView(library: library, identity: $0.id) }
    .sheet(isPresented: $showSettings) { connection }
    #endif
  }
  private var connection: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connection").font(.title2.bold())
      Text(library.connection.identity.endpoint.absoluteString).textSelection(.enabled)
      Text(library.workspace.isOnline ? "Connected" : "Offline - cached pages only")
      Text("Disconnect revokes this device’s access. Your unsent drafts remain on this device.").foregroundStyle(.secondary)
      Button("Disconnect", role: .destructive) { Task { await model.disconnect(); showSettings = false } }
      Button("Done") { showSettings = false }
    }.padding(28)
  }
  private var content: some View {
    VStack(spacing: 0) {
      if !library.workspace.isOnline { Text("Offline - viewing cached media. Reconnect before making changes.").font(.callout).padding().frame(maxWidth: .infinity).background(.yellow.opacity(0.12)) }
      if let message = library.message { Text(message).font(.callout).padding().foregroundStyle(.red) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          Text(subtitle).foregroundStyle(.secondary).padding(.bottom, 10)
          if library.section == .sources {
            ForEach(library.sources.filter { !$0.isDeleted }, id: \.identity) { source in
              HStack {
                VStack(alignment: .leading) { Text(source.title).font(.headline); Text(source.followed ? "Following" : "Not following").foregroundStyle(.secondary) }
                Spacer()
                Button("Details") { sourceSelection = .init(id: source.identity) }.accessibilityIdentifier("source.\(source.identity.kind.rawValue).\(source.identity.id)")
                if library.canFollow(source.identity) { Button(source.followed ? "Unfollow" : "Follow") { Task { await library.follow(source.identity, value: !source.followed) } }.disabled(library.loading) }
              }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
          } else if library.section == .feed {
            ForEach(library.cards) { card in
              Button { selection = .init(id: card.identity) } label: {
                MediaCardView(item: card.item, title: card.title, subtitle: card.nextEpisode.map { "Next: \($0.title)" } ?? card.sourceTitle, reasons: card.reasons)
              }.buttonStyle(.plain).accessibilityIdentifier("item.\(card.identity.kind.rawValue).\(card.identity.id)")
            }
          } else {
            ForEach(library.matchingItems, id: \.identity) { item in
              Button { selection = .init(id: item.identity) } label: { MediaCardView(item: item, title: item.title, subtitle: nil, reasons: []) }
                .buttonStyle(.plain).accessibilityIdentifier("item.\(item.identity.kind.rawValue).\(item.identity.id)")
            }
          }
          if library.loading { ProgressView().frame(maxWidth: .infinity) }
          if !library.loading && (library.section == .feed ? library.cards.isEmpty : library.matchingItems.isEmpty) && library.section != .sources {
            VStack(alignment: .leading, spacing: 8) {
              Text(library.section == .feed ? "Nothing waiting right now" : "No matching items on this page").font(.title3.bold())
              Text(library.section == .feed ? "Follow sources or save something from your Library. New releases will join this feed." : "Change your filters or load more catalog items.").foregroundStyle(.secondary)
            }.padding(24)
          }
          if library.hasMore { Button("Load more") { Task { await library.loadMore() } }.disabled(library.loading).frame(maxWidth: .infinity) }
          if library.incomplete { Text("Some sources or pages have not been loaded. These results may be incomplete.").font(.footnote).foregroundStyle(.secondary) }
          #if DEBUG
          if let synthetic = model.synthetic { Text("Writes: \(synthetic.writeCount)").font(.caption).accessibilityIdentifier("fixture.writes") }
          #endif
        }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
      }
    }.navigationTitle(library.section.rawValue.capitalized)
      .searchable(text: $library.preferences.search, prompt: "Search loaded media")
      .toolbar {
        ToolbarItem { Button("Filters") { showFilters = true }.accessibilityIdentifier("feed.filters") }
        ToolbarItem { Button("Add") { showAdd = true }.accessibilityIdentifier("media.add") }
        ToolbarItem { Button("Drafts") { showDrafts = true }.accessibilityIdentifier("media.drafts") }
        ToolbarItem { Button("Refresh") { Task { await library.refresh() } }.disabled(library.loading) }
        #if os(iOS)
        ToolbarItem { Button("Connection") { showSettings = true } }
        #endif
      }
  }
  private var subtitle: String {
    switch library.section {
    case .feed: "Saved for later, in progress, and new from your sources."
    case .library: "Your catalog. Saving adds an item to your feed."
    case .history: "What you’ve explicitly finished, stopped, or partly watched."
    case .sources: "The sources behind your feed."
    }
  }
}

private struct MediaDetailSelection: Identifiable { let id: MediaIdentity }
private struct SourceDetailSelection: Identifiable { let id: SourceIdentity }

struct MediaCardView: View {
  let item: MediaItem
  let title: String
  let subtitle: String?
  let reasons: Set<FeedReason>
  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      if let image = item.imageURL {
        AsyncImage(url: image) { phase in
          if let image = phase.image { image.resizable().scaledToFill() }
          else { Color.accentColor.opacity(0.08) }
        }.frame(width: 88, height: 88).clipped().clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text(kindLabel(item.identity.kind)).textCase(.uppercase).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        HStack {
          Text(item.status)
          if let duration = item.durationMinutes { Text("\(Int(duration.rounded())) min") }
          if reasons.contains(.saved) { Text("Saved") }
          if reasons.contains(.newRelease) { Text("New release") }
        }.font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
  }
 }

private func kindLabel(_ kind: MediaKind) -> String {
  switch kind { case .article: "Article"; case .youtubeVideo: "Video"; case .tvShow: "TV show"; case .tvEpisode: "TV episode"; case .movie: "Film"; case .podcastEpisode: "Podcast episode" }
}

struct FeedFiltersView: View {
  @Bindable var library: MediaLibrary
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Media") {
          ForEach(MediaKind.allCases.filter { $0 != .tvEpisode }, id: \.self) { kind in
            Toggle(kindLabel(kind), isOn: Binding(get: { library.preferences.kinds.contains(kind) }, set: { value in
              if value { library.preferences.kinds.insert(kind) } else { library.preferences.kinds.remove(kind) }
            })).accessibilityIdentifier("filter.\(kind.rawValue)")
          }
          Text("No selection includes every type.").font(.footnote).foregroundStyle(.secondary)
          Toggle("Include Shorts", isOn: $library.preferences.includeShorts)
        }
        Section("Order") { Picker("Sort", selection: $library.preferences.sort) { ForEach(FeedSort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } } }
        Section("Sources") {
          ForEach(library.sources.filter { !$0.isDeleted }, id: \.identity) { source in
            Toggle(source.title, isOn: Binding(get: { library.preferences.sources.contains(source.identity) }, set: { value in
              if value { library.preferences.sources.insert(source.identity) } else { library.preferences.sources.remove(source.identity) }
            }))
          }
        }
        Section("Statuses") {
          ForEach(Array(Set(library.connection.bindings.items.values.flatMap { $0.statuses.keys })).sorted(), id: \.self) { status in
            Toggle(status, isOn: Binding(get: { library.preferences.statuses.contains(status) }, set: { value in
              if value { library.preferences.statuses.insert(status) } else { library.preferences.statuses.remove(status) }
            }))
          }
        }
      }.navigationTitle("Feed filters").toolbar { ToolbarItem { Button("Done") { dismiss(); Task { await library.refresh() } }.accessibilityIdentifier("filters.done") } }
    }.frame(minWidth: 320, minHeight: 420)
  }
}

struct SourceDetailsView: View {
  @Bindable var library: MediaLibrary
  let identity: SourceIdentity
  @Environment(\.dismiss) private var dismiss
  @State private var date = Date()
  @State private var applying = false
  @State private var result: String?
  private var source: MediaSource? { library.sources.first { $0.identity == identity } }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(source?.title ?? "Source details").font(.title2.bold())
      Text(source?.followed == true ? "Following" : "Not following").foregroundStyle(.secondary)
      Text("The feed includes releases from this date onward. Older items remain in the Library and can be saved individually.").foregroundStyle(.secondary)
      if source?.followed == true && library.canFollow(identity) {
        DatePicker("Feed starts", selection: $date).accessibilityIdentifier("source.feed-start")
        Button("Update feed start") {
          Task { applying = true; result = await library.setFeedStart(identity, date: date) ? "Updated" : library.message ?? "Could not confirm the change."; applying = false }
        }.disabled(applying || source?.feedSince == date).accessibilityIdentifier("source.apply")
      } else { Text("Follow this source before choosing its feed start.") }
      if let result { Text(result) }
      Button("Done") { dismiss() }.disabled(applying).accessibilityIdentifier("source.done")
    }.padding(24).frame(minWidth: 320, idealWidth: 480)
      .task(id: identity) { date = source?.feedSince ?? library.now }
  }
}
