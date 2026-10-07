import Foundation
import Observation

public enum LibrarySection: String, CaseIterable, Sendable { case feed, library, history, sources }
public struct BulkEditResult: Identifiable, Sendable {
  public let id: MediaIdentity
  public let title: String
  public let committed: Bool
}

/// One validated catalog connection drives both native clients. Every mutation is explicit.
@Observable @MainActor public final class MediaLibrary {
  public let connection: MediaConnection
  public let workspace: MediaWorkspace
  public var section: LibrarySection = .feed
  public var preferences = FeedPreferences() {
    didSet {
      if let data = try? JSONEncoder().encode(preferences), data.count <= 32 * 1024 {
        defaults?.set(data, forKey: "feed." + connection.identity.storageKey)
      }
    }
  }
  @ObservationIgnored private let defaults: UserDefaults?
  public private(set) var records: [MediaIdentity: MediaRecord] = [:]
  public private(set) var sources: [MediaSource] = []
  public private(set) var visible: [MediaItem] = []
  public private(set) var episodes: [MediaItem] = []
  public private(set) var episodesComplete = false
  public private(set) var sourcesComplete = false
  public private(set) var hasMore = false
  public private(set) var incomplete = false
  public private(set) var loading = false
  public private(set) var message: String?
  public private(set) var review: MediaIdentity?
  public private(set) var bulkResults: [BulkEditResult] = []
  public var now: Date { clock() }
  @ObservationIgnored private let clock: () -> Date
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private var pager: FeedPager?
  @ObservationIgnored private var generation = 0
  private var nextEpisodes: [MediaItem] = []
  private var sourceRows: [SourceIdentity: CoreRow] = [:]
  public init(connection: MediaConnection, workspace: MediaWorkspace, now: @autoclosure @escaping () -> Date = Date(), calendar: Calendar = .current, defaults: UserDefaults? = nil) {
    self.connection = connection; self.workspace = workspace; self.clock = now; self.calendar = calendar; self.defaults = defaults
    if let data = defaults?.data(forKey: "feed." + connection.identity.storageKey), data.count <= 32 * 1024,
      let saved = try? JSONDecoder().decode(FeedPreferences.self, from: data) { preferences = saved }
  }
  public var cards: [FeedCard] {
    FeedPolicy.cards(items: visible + nextEpisodes, sources: sources, preferences: preferences, now: now, calendar: calendar)
  }
  public var matchingItems: [MediaItem] {
    visible.filter { item in
      (preferences.kinds.isEmpty || preferences.kinds.contains(item.identity.kind)) &&
      (preferences.search.isEmpty || item.title.localizedCaseInsensitiveContains(preferences.search))
    }
  }
  public func opened(_ id: MediaIdentity) { review = id }
  public func leaveUnchanged() { review = nil }
  public func refresh() async {
    generation += 1
    let current = generation
    pager?.reset(); visible = []; nextEpisodes = []; message = nil; loading = true
    defer { if generation == current { loading = false } }
    do {
      try await loadSources(generation: current)
      guard generation == current else { return }
      let streams: [MediaQueryStream]
      if section == .feed {
        streams = FeedQueryPlan.streams(bindings: connection.bindings, metadata: connection.metadata,
          sources: sources, preferences: preferences, now: now, calendar: calendar)
      } else {
        streams = connection.bindings.items.keys.sorted().compactMap { role in
          guard let kind = MediaKind(rawValue: role), let binding = connection.bindings.items[role],
            let status = binding.fields["status"], let deleted = binding.fields["deletedAt"] else { return nil }
          var query = FeedQueryPlan.browse(binding: binding, sort: preferences.sort == .recommended ? .newest : preferences.sort)
          let statuses = binding.statuses.filter { section == .history ? !$0.value.isActive : true }.keys.sorted()
          guard !statuses.isEmpty else { return nil }
          query.filter = FeedQueryPlan.all([FeedQueryPlan.predicate(deleted, "is_null", .bool(true)),
            FeedQueryPlan.predicate(status, "in", .array(statuses.map(CoreJSONValue.string)))])
          return MediaQueryStream(id: role, kind: kind, query: query)
        }
      }
      let plans = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0) })
      let sort = section == .feed ? preferences.sort : preferences.sort == .recommended ? .newest : preferences.sort
      let calendar = calendar
      pager = FeedPager(streams: streams.map(\.id), orderedBefore: {
        FeedQueryPlan.precedes($0, $1, sort: sort, calendar: calendar)
      }, fetch: { [weak self] id, cursor in
        guard let self, self.generation == current, let plan = plans[id],
          let binding = self.connection.bindings.items[plan.kind.rawValue] else { throw PagerError.generationChanged }
        var query = plan.query; query.cursor = cursor
        await self.workspace.load(query, key: "browse:\(id):\(cursor ?? "first")")
        guard self.generation == current else { throw PagerError.generationChanged }
        guard let page = self.workspace.rows["browse:\(id):\(cursor ?? "first")"] else { throw self.workspace.error ?? HubError.unavailable }
        let decoded = try page.rows.map { try MediaRecord(kind: plan.kind, row: $0, binding: binding) }
        for record in decoded { self.records[record.item.identity] = record }
        return ItemPage(items: decoded.map(\.item), nextCursor: page.nextCursor)
      })
      try await appendPage(generation: current)
    } catch { if generation == current { message = "Could not load media. Reconnect or try refreshing."; incomplete = true } }
  }
  public func loadMore() async {
    guard !loading, hasMore else { return }
    loading = true; let current = generation
    defer { if current == generation { loading = false } }
    do { try await appendPage(generation: current) }
    catch { if current == generation { message = "Could not load the next page. Refresh to restart."; incomplete = true } }
  }
  private func appendPage(generation: Int) async throws {
    guard let page = try await pager?.loadNext(), generation == self.generation else { return }
    visible.append(contentsOf: page.items); hasMore = page.hasMore; incomplete = page.incomplete || !sourcesComplete
    if section == .feed { try await loadNextEpisodes(generation: generation) }
  }
  private func loadNextEpisodes(generation: Int) async throws {
    guard let binding = connection.bindings.items[MediaKind.tvEpisode.rawValue],
      let parent = binding.fields["sourceID"], let release = binding.fields["release"],
      let season = binding.fields["season"], let number = binding.fields["episode"],
      let status = binding.fields["status"], let deleted = binding.fields["deletedAt"] else { return }
    let shows = FeedPolicy.cards(items: visible, sources: sources, preferences: preferences, now: now, calendar: calendar).filter { $0.identity.kind == .tvShow }
    let dateOnly = connection.metadata[binding.table]?.first { $0.column == release }?.type == "date"
    for show in shows {
      let query = RowQuery(table: binding.table, columns: Set(binding.fields.values).sorted(),
        filter: FeedQueryPlan.all([
          FeedQueryPlan.predicate(parent, "eq", .string(show.identity.id)),
          FeedQueryPlan.predicate(deleted, "is_null", .bool(true)),
          FeedQueryPlan.predicate(status, "in", .array(binding.statuses.filter { $0.value.isActive }.keys.sorted().map(CoreJSONValue.string))),
          FeedQueryPlan.predicate(release, "lte", .string(dateOnly ? FeedQueryPlan.day(now, calendar: calendar) : FeedQueryPlan.timestamp(now))),
          FeedQueryPlan.predicate(season, "gte", .number(1)), FeedQueryPlan.predicate(number, "gte", .number(1))
        ]), order: [.init(column: season, direction: "asc"), .init(column: number, direction: "asc")], limit: 1)
      let key = "next:\(show.identity.id)"
      await workspace.load(query, key: key)
      guard generation == self.generation else { return }
      guard let page = workspace.rows[key] else { throw workspace.error ?? HubError.unavailable }
      if let row = page.rows.first {
        let record = try MediaRecord(kind: .tvEpisode, row: row, binding: binding)
        records[record.item.identity] = record
        nextEpisodes.removeAll { $0.source == record.item.source }
        nextEpisodes.append(record.item)
      }
    }
  }
  private func loadSources(generation: Int) async throws {
    var loaded: [MediaSource] = []; var complete = true
    for role in connection.bindings.sources.keys.sorted() {
      guard let kind = SourceKind(rawValue: role), let binding = connection.bindings.sources[role] else { continue }
      var query = RowQuery(table: binding.table, columns: Set(binding.fields.values).sorted(), limit: 100)
      var seen = Set<String>()
      for pageNumber in 0..<10 {
        await workspace.load(query, key: "sources:\(role):\(pageNumber)")
        guard generation == self.generation else { return }
        guard let page = workspace.rows["sources:\(role):\(pageNumber)"] else { throw workspace.error ?? HubError.unavailable }
        for row in page.rows {
          let source = try MediaSource(kind: kind, row: row, binding: binding)
          loaded.append(source); sourceRows[source.identity] = row
        }
        guard let next = page.nextCursor else { break }
        guard seen.insert(next).inserted else { throw PagerError.stalledCursor }
        query.cursor = next
        if pageNumber == 9 { complete = false }
      }
    }
    sources = loaded; sourcesComplete = complete
  }
  public func loadEpisodes(showID: String) async {
    episodes = []; episodesComplete = false; bulkResults = []
    guard let binding = connection.bindings.items[MediaKind.tvEpisode.rawValue], let parent = binding.fields["sourceID"] else { return }
    var query = FeedQueryPlan.browse(binding: binding, sort: .oldest)
    query.filter = FeedQueryPlan.predicate(parent, "eq", .string(showID))
    var seen = Set<String>()
    let current = generation
    do {
      for number in 0..<20 {
        await workspace.load(query, key: "episodes:\(showID):\(number)")
        guard current == generation else { return }
        guard let page = workspace.rows["episodes:\(showID):\(number)"] else { throw workspace.error ?? HubError.unavailable }
        let decoded = try page.rows.map { try MediaRecord(kind: .tvEpisode, row: $0, binding: binding) }
        for record in decoded { records[record.item.identity] = record }
        episodes += decoded.map(\.item).filter { !$0.isDeleted }
        guard let next = page.nextCursor else { episodesComplete = true; break }
        guard seen.insert(next).inserted else { throw PagerError.stalledCursor }
        query.cursor = next
      }
    } catch { message = "Could not load all episodes. Bulk changes are unavailable." }
  }
  public func airedEpisodes(season: Int) -> [MediaItem] {
    guard episodesComplete else { return [] }
    return episodes.filter { $0.season == season && ($0.episode ?? 0) > 0 && $0.isActive && $0.release?.isReleased(at: now, calendar: calendar) == true }
  }
  public func canEdit(_ id: MediaIdentity, role: String) -> Bool {
    guard workspace.isOnline, workspace.connection == connection.identity,
      let binding = connection.bindings.items[id.kind.rawValue], let column = binding.fields[role],
      connection.metadata[binding.table]?.first(where: { $0.column == column })?.readOnly == false else { return false }
    return connection.session.scopes.contains("tables:patch:\(binding.table):\(column)")
  }
  public func canFollow(_ id: SourceIdentity) -> Bool {
    guard workspace.isOnline, workspace.connection == connection.identity, let binding = connection.bindings.sources[id.kind.rawValue] else { return false }
    return ["follow", "feedSince"].allSatisfy { role in
      guard let column = binding.fields[role] else { return false }
      return connection.metadata[binding.table]?.first { $0.column == column }?.readOnly == false && connection.session.scopes.contains("tables:patch:\(binding.table):\(column)")
    }
  }
  @discardableResult public func follow(_ id: SourceIdentity, value: Bool) async -> Bool {
    guard canFollow(id), let binding = connection.bindings.sources[id.kind.rawValue], let row = sourceRows[id],
      let updated = binding.fields["updatedAt"], case .string(let revision) = row[updated],
      let follow = binding.fields["follow"], let since = binding.fields["feedSince"] else { return false }
    let hub = binding.fields["hubAt"].flatMap { column -> String? in if case .string(let value) = row[column] { return value }; return nil }
    var values: CoreRow = [follow: .bool(value)]
    if value { values[since] = .string(FeedQueryPlan.timestamp(now)) }
    let draft = MediaDraft(edit: .init(table: binding.table, id: id.id, values: values, expectedRevision: .init(updatedAt: revision, hubAt: hub)))
    do { try await workspace.keep(draft) } catch { message = "Could not preserve your source change."; return false }
    await workspace.submit(draft)
    guard case .committed = workspace.editStates[draft.id] else { message = "Your source change was not confirmed. Refresh before trying again."; return false }
    await refresh()
    return true
  }
  @discardableResult public func edit(_ id: MediaIdentity, role: String, value: CoreJSONValue) async -> Bool {
    await editFields(id, values: [role: value])
  }
  @discardableResult public func editFields(_ id: MediaIdentity, values: [String: CoreJSONValue]) async -> Bool {
    guard !values.isEmpty, let record = records[id], let binding = connection.bindings.items[id.kind.rawValue] else { return false }
    var patch: CoreRow = [:]
    for (role, value) in values {
      guard canEdit(id, role: role), let column = binding.fields[role] else { return false }
      if role == "status" {
        guard case .string(let status) = value, binding.statuses[status] != nil else { return false }
      }
      patch[column] = value
    }
    return await apply(id, record: record, binding: binding, values: patch)
  }
  @discardableResult public func setConsumption(_ id: MediaIdentity, status: String, date: Date?) async -> Bool {
    guard canEdit(id, role: "status"), let binding = connection.bindings.items[id.kind.rawValue],
      let state = binding.statuses[status], let statusColumn = binding.fields["status"], let record = records[id] else { return false }
    var values: CoreRow = [statusColumn: .string(status)]
    if let column = binding.fields["consumedAt"], canEdit(id, role: "consumedAt") {
      let dateOnly = connection.metadata[binding.table]?.first { $0.column == column }?.type == "date"
      values[column] = !state.isActive ? date.map { .string(dateOnly ? FeedQueryPlan.day($0, calendar: calendar) : FeedQueryPlan.timestamp($0)) } ?? .null : .null
    }
    return await apply(id, record: record, binding: binding, values: values)
  }
  private func apply(_ id: MediaIdentity, record: MediaRecord, binding: RecordBinding, values: CoreRow) async -> Bool {
    let draft = MediaDraft(edit: .init(table: binding.table, id: id.id, values: values, expectedRevision: record.revision))
    do { try await workspace.keep(draft) } catch { message = "Could not preserve your change."; return false }
    await workspace.submit(draft)
    guard case .committed = workspace.editStates[draft.id] else {
      await workspace.reconcile(draft)
      message = workspace.editStates[draft.id] == .conflict ? "This item changed elsewhere. Review its current values before trying again." : "Your change was not confirmed. The draft is preserved."
      return false
    }
    var query = FeedQueryPlan.browse(binding: binding)
    query.filter = FeedQueryPlan.predicate("id", "eq", .string(id.id)); query.limit = 1
    await workspace.load(query, key: "readback:\(id.kind.rawValue):\(id.id)")
    if let row = workspace.rows["readback:\(id.kind.rawValue):\(id.id)"]?.rows.first,
      let updated = try? MediaRecord(kind: id.kind, row: row, binding: binding) {
      records[id] = updated
      visible = visible.map { $0.identity == id ? updated.item : $0 }
      episodes = episodes.map { $0.identity == id ? updated.item : $0 }
    }
    return true
  }
  public func finish(_ preview: [MediaItem]) async {
    bulkResults = []
    for item in preview {
      guard let binding = connection.bindings.items[item.identity.kind.rawValue],
        let label = binding.statuses.keys.sorted().first(where: { binding.statuses[$0] == .finished }) else {
        bulkResults.append(.init(id: item.identity, title: item.title, committed: false)); continue
      }
      let committed = await setConsumption(item.identity, status: label, date: now)
      bulkResults.append(.init(id: item.identity, title: item.title, committed: committed))
    }
  }
  public func capture(_ draft: MediaDraft) async {
    do { try await workspace.keep(draft) } catch { message = "Could not preserve this capture."; return }
    await workspace.submit(draft)
    if workspace.captureReceipts[draft.id]?.state == "saved" { await refresh() }
  }
}
