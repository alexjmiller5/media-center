import Foundation

public enum FeedReason: String, Codable, Hashable, Sendable {
  case saved, newRelease, inProgress, priority
}
public enum FeedSort: String, Codable, CaseIterable, Sendable {
  case recommended, newest, oldest, shortest, longest
}
public struct FeedPreferences: Codable, Equatable, Sendable {
  public var kinds: Set<MediaKind> = []
  public var sources: Set<SourceIdentity> = []
  public var statuses: Set<String> = []
  public var includeShorts = true
  public var search = ""
  public var sort: FeedSort = .recommended
  public init() {}
}
public struct FeedCard: Identifiable, Sendable {
  public var identity: MediaIdentity
  public var id: MediaIdentity { identity }
  public var title: String {
    identity.kind == .tvShow && item.identity.kind != .tvShow
      ? sourceTitle ?? "Unknown show" : item.title
  }
  public var item: MediaItem
  public var reasons: Set<FeedReason>
  public var nextEpisode: MediaItem?
  public var isUpcoming: Bool
  public var sourceTitle: String?
  public var orderingRelease: MediaRelease?
}

public enum FeedPolicy {
  public static func eligible(
    item: MediaItem, source: MediaSource?, now: Date,
    calendar: Calendar
  ) -> Set<FeedReason> {
    guard !item.isDeleted, item.isActive else { return [] }
    var reasons = Set<FeedReason>()
    if item.saved { reasons.insert(.saved) }
    if item.state == .inProgress { reasons.insert(.inProgress) }
    if item.state == .priority { reasons.insert(.priority) }
    if let source, source.identity == item.source, !source.isDeleted, source.followed,
      let boundary = source.feedSince, let release = item.release,
      release.isReleased(at: now, calendar: calendar),
      release.isOnOrAfter(boundary, calendar: calendar)
    {
      reasons.insert(.newRelease)
    }
    return reasons
  }

  public static func cards(
    items: [MediaItem], sources: [MediaSource],
    preferences: FeedPreferences = .init(), now: Date,
    calendar: Calendar
  ) -> [FeedCard] {
    let unique = Dictionary(
      items.map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest })
    let sourceMap = Dictionary(
      sources.map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest })
    var cards: [MediaIdentity: FeedCard] = [:]
    for item in unique.values.sorted(by: { ($0.identity.kind.rawValue, $0.identity.id) < ($1.identity.kind.rawValue, $1.identity.id) }) {
      let sourceID =
        item.source
        ?? (item.identity.kind == .tvShow
          ? SourceIdentity(kind: .tvShow, id: item.identity.id) : nil)
      let source = sourceID.flatMap { sourceMap[$0] }
      let reasons = eligible(item: item, source: source, now: now, calendar: calendar)
      guard !reasons.isEmpty, matches(item, source: source, preferences: preferences) else {
        continue
      }
      let grouped = item.identity.kind == .tvEpisode && item.source?.kind == .tvShow
      let identity = grouped ? MediaIdentity(kind: .tvShow, id: item.source!.id) : item.identity
      if var existing = cards[identity] {
        existing.reasons.formUnion(reasons)
        if let date = item.release?.orderingDate(calendar: calendar),
          date > (existing.orderingRelease?.orderingDate(calendar: calendar) ?? .distantPast)
        {
          existing.orderingRelease = item.release
        }
        cards[identity] = existing
      } else {
        let primary = grouped ? unique[identity] ?? item : item
        cards[identity] = FeedCard(
          identity: identity, item: primary, reasons: reasons,
          isUpcoming: item.release.map { !$0.isReleased(at: now, calendar: calendar) } ?? false,
          sourceTitle: source?.isDeleted == false ? source?.title : nil,
          orderingRelease: item.release)
      }
    }
    for identity in cards.keys where identity.kind == .tvShow {
      let episodes = unique.values.filter {
        $0.identity.kind == .tvEpisode
          && $0.source == SourceIdentity(kind: .tvShow, id: identity.id)
      }
      let next = TVProgress.nextEpisode(episodes: Array(episodes), now: now, calendar: calendar)
      cards[identity]?.nextEpisode = next
      if let next {
        cards[identity]?.isUpcoming = false
        // Without the show's own record, the card shows the episode it leads to, not an arbitrary one.
        if unique[identity] == nil { cards[identity]?.item = next }
      }
    }
    return cards.values.sorted { precedes($0, $1, sort: preferences.sort, calendar: calendar) }
  }

  static func matches(_ item: MediaItem, source: MediaSource?, preferences: FeedPreferences)
    -> Bool
  {
    let kind = item.identity.kind == .tvEpisode ? MediaKind.tvShow : item.identity.kind
    if !preferences.kinds.isEmpty && !preferences.kinds.contains(kind)
      && !preferences.kinds.contains(item.identity.kind)
    {
      return false
    }
    let sourceID =
      item.source
      ?? (item.identity.kind == .tvShow ? SourceIdentity(kind: .tvShow, id: item.identity.id) : nil)
    if !preferences.sources.isEmpty && !(sourceID.map { preferences.sources.contains($0) } ?? false)
    {
      return false
    }
    if !preferences.statuses.isEmpty && !preferences.statuses.contains(item.status) { return false }
    if !preferences.includeShorts && item.identity.kind == .youtubeVideo && item.isShort == true {
      return false
    }
    let query = preferences.search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
      || source?.title.localizedCaseInsensitiveContains(query) == true
  }

  private static func precedes(_ lhs: FeedCard, _ rhs: FeedCard, sort: FeedSort, calendar: Calendar)
    -> Bool
  {
    if sort == .recommended {
      func rank(_ card: FeedCard) -> Int {
        card.reasons.contains(.priority) ? 0 : card.reasons.contains(.inProgress) ? 1 : 2
      }
      if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
    }
    let l: Double?
    let r: Double?
    if sort == .shortest || sort == .longest {
      l = lhs.nextEpisode?.durationMinutes ?? lhs.item.durationMinutes
      r = rhs.nextEpisode?.durationMinutes ?? rhs.item.durationMinutes
    } else {
      l = lhs.orderingRelease?.orderingDate(calendar: calendar)?.timeIntervalSince1970
      r = rhs.orderingRelease?.orderingDate(calendar: calendar)?.timeIntervalSince1970
    }
    if l != r {
      guard let l else { return false }
      guard let r else { return true }
      return sort == .shortest || sort == .oldest ? l < r : l > r
    }
    if lhs.identity.kind != rhs.identity.kind {
      return lhs.identity.kind.rawValue < rhs.identity.kind.rawValue
    }
    return lhs.identity.id < rhs.identity.id
  }
}
