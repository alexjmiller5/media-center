import Foundation

public struct MediaQueryStream: Sendable {
  public let id: String
  public let kind: MediaKind
  public let query: RowQuery
}

/// Compiles runtime feed intent to bounded, individually sorted service queries.
/// Priority/progress each get their own stream because the API has no custom rank SQL.
public enum FeedQueryPlan {
  public static func predicate(_ column: String, _ op: String, _ value: CoreJSONValue) -> CoreJSONValue {
    .object(["column": .string(column), "op": .string(op), "value": value])
  }
  public static func all(_ filters: [CoreJSONValue]) -> CoreJSONValue { .object(["and": .array(filters)]) }
  public static func any(_ filters: [CoreJSONValue]) -> CoreJSONValue { .object(["or": .array(filters)]) }
  public static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
  public static func day(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
  public static func streams(bindings: MediaBindings, metadata: [String: [PropertyMetadata]], sources: [MediaSource],
    preferences: FeedPreferences, now: Date, calendar: Calendar) -> [MediaQueryStream] {
    var streams: [MediaQueryStream] = []
    for role in bindings.items.keys.sorted() {
      guard let kind = MediaKind(rawValue: role), let binding = bindings.items[role],
        preferences.kinds.isEmpty || preferences.kinds.contains(kind) || (kind == .tvEpisode && preferences.kinds.contains(.tvShow)),
        let status = binding.fields["status"], let saved = binding.fields["saved"], let deleted = binding.fields["deletedAt"] else { continue }
      let groups: [[ConsumptionState]] = preferences.sort == .recommended
        ? [[.priority], [.inProgress], [.notStarted, .other]] : [[.priority, .inProgress, .notStarted, .other]]
      for (index, states) in groups.enumerated() {
        let labels = binding.statuses.filter { states.contains($0.value) && (preferences.statuses.isEmpty || preferences.statuses.contains($0.key)) }.keys.sorted()
        guard !labels.isEmpty else { continue }
        var base = [predicate(deleted, "is_null", .bool(true)), predicate(status, "in", .array(labels.map(CoreJSONValue.string)))]
        if !preferences.includeShorts, kind == .youtubeVideo, let short = binding.fields["isShort"] {
          base.append(any([predicate(short, "eq", .bool(false)), predicate(short, "is_null", .bool(true))]))
        }
        if !preferences.sources.isEmpty {
          let ids = preferences.sources.filter { matches($0.kind, kind) }.map(\.id).sorted()
          guard !ids.isEmpty, let column = kind == .tvShow ? binding.fields["id"] : binding.fields["sourceID"] else { continue }
          // Each query remains within the canonical IN bound; selection beyond this
          // is applied by FeedPolicy while the query remains otherwise restricted.
          if ids.count <= 200 { base.append(predicate(column, "in", .array(ids.map(CoreJSONValue.string)))) }
        }
        var intent = [predicate(saved, "eq", .bool(true))]
        let progress = labels.filter { binding.statuses[$0] == .priority || binding.statuses[$0] == .inProgress }
        if !progress.isEmpty { intent.append(predicate(status, "in", .array(progress.map(CoreJSONValue.string)))) }
        var followed: [CoreJSONValue] = []
        if labels.contains(where: { binding.statuses[$0] != .priority && binding.statuses[$0] != .inProgress }),
          let parent = binding.fields["sourceID"], let release = binding.fields["release"] {
          let dateOnly = metadata[binding.table]?.first(where: { $0.column == release })?.type == "date"
          for source in sources where source.followed && !source.isDeleted && matches(source.identity.kind, kind) {
            guard let boundary = source.feedSince else { continue }
            followed.append(all([
              predicate(parent, "eq", .string(source.identity.id)),
              predicate(release, "gte", .string(dateOnly ? day(boundary, calendar: calendar) : timestamp(boundary))),
              predicate(release, "lte", .string(dateOnly ? day(now, calendar: calendar) : timestamp(now)))
            ]))
          }
        }
        let batches = max(1, (followed.count + 15) / 16)
        for batch in 0..<batches {
          let slice = Array(followed.dropFirst(batch * 16).prefix(16))
          var query = browse(binding: binding, sort: preferences.sort)
          query.filter = all(base + [any(intent + slice)])
          streams.append(.init(id: "\(role):\(index):\(batch)", kind: kind, query: query))
        }
      }
    }
    return streams
  }
  public static func browse(binding: RecordBinding, sort: FeedSort = .newest) -> RowQuery {
    var order: [CoreRowsQueryOrder] = []
    let field = binding.fields[sort == .shortest || sort == .longest ? "duration" : "release"]
    if let field { order.append(.init(column: field, direction: sort == .oldest || sort == .shortest ? "asc" : "desc")) }
    return .init(table: binding.table, columns: Set(binding.fields.values).sorted(), order: order, limit: 50)
  }
  private static func matches(_ source: SourceKind, _ kind: MediaKind) -> Bool {
    (source == .youtubeChannel && kind == .youtubeVideo) || (source == .feed && kind == .article)
      || (source == .tvShow && [.tvShow, .tvEpisode].contains(kind))
  }
  public static func precedes(_ lhs: MediaItem, _ rhs: MediaItem, sort: FeedSort, calendar: Calendar) -> Bool {
    if sort == .recommended {
      func rank(_ item: MediaItem) -> Int { item.state == .priority ? 0 : item.state == .inProgress ? 1 : 2 }
      if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
    }
    let left = sort == .shortest || sort == .longest ? lhs.durationMinutes : lhs.release?.orderingDate(calendar: calendar)?.timeIntervalSince1970
    let right = sort == .shortest || sort == .longest ? rhs.durationMinutes : rhs.release?.orderingDate(calendar: calendar)?.timeIntervalSince1970
    if left != right {
      guard let left else { return false }; guard let right else { return true }
      return sort == .oldest || sort == .shortest ? left < right : left > right
    }
    if lhs.identity.kind != rhs.identity.kind { return lhs.identity.kind.rawValue < rhs.identity.kind.rawValue }
    return lhs.identity.id.utf8.lexicographicallyPrecedes(rhs.identity.id.utf8)
  }
}
