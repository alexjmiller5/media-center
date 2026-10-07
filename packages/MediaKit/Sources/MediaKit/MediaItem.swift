import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
  case movie, tvShow, tvEpisode, youtubeVideo, article, podcastEpisode
}
public struct MediaIdentity: Hashable, Codable, Sendable {
  public var kind: MediaKind
  public var id: String
  public init(kind: MediaKind, id: String) {
    self.kind = kind
    self.id = id
  }
}
public enum SourceKind: String, Codable, Sendable { case tvShow, youtubeChannel, feed }
public struct SourceIdentity: Hashable, Codable, Sendable {
  public var kind: SourceKind
  public var id: String
  public init(kind: SourceKind, id: String) {
    self.kind = kind
    self.id = id
  }
}

public enum MediaRelease: Hashable, Codable, Sendable {
  case instant(Date)
  case day(year: Int, month: Int, day: Int)

  // Conversion supplies calendar ordering only. The original precision is retained.
  public func orderingDate(calendar: Calendar) -> Date? {
    switch self {
    case .instant(let date): return date
    case .day(let year, let month, let day):
      let timeZone = calendar.timeZone
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      let components = DateComponents(year: year, month: month, day: day)
      guard let date = calendar.date(from: components),
        calendar.dateComponents([.year, .month, .day], from: date) == components
      else { return nil }
      return date
    }
  }
  public func isReleased(at now: Date, calendar: Calendar) -> Bool {
    guard let date = orderingDate(calendar: calendar) else { return false }
    switch self {
    case .instant: return date <= now
    case .day: return calendar.compare(date, to: now, toGranularity: .day) != .orderedDescending
    }
  }
  public func isOnOrAfter(_ boundary: Date, calendar: Calendar) -> Bool {
    guard let date = orderingDate(calendar: calendar) else { return false }
    switch self {
    case .instant: return date >= boundary
    case .day: return calendar.compare(date, to: boundary, toGranularity: .day) != .orderedAscending
    }
  }
}

public struct MediaItem: Hashable, Codable, Sendable {
  public var identity: MediaIdentity
  public var title: String
  public var source: SourceIdentity?
  public var release: MediaRelease?
  public var durationMinutes: Double?
  public var status: String
  public var state: ConsumptionState
  public var saved: Bool
  public var isDeleted: Bool
  public var season: Int?
  public var episode: Int?
  public var isShort: Bool?
  public var url: URL?
  public var imageURL: URL?

  public init(
    identity: MediaIdentity, title: String, source: SourceIdentity? = nil,
    release: MediaRelease? = nil, durationMinutes: Double? = nil,
    status: String = "", state: ConsumptionState = .notStarted, saved: Bool = false,
    isDeleted: Bool = false,
    season: Int? = nil, episode: Int? = nil, isShort: Bool? = nil,
    url: URL? = nil, imageURL: URL? = nil
  ) {
    self.identity = identity
    self.title = title
    self.source = source
    self.release = release
    self.durationMinutes = durationMinutes
    self.status = status
    self.state = state
    self.saved = saved
    self.isDeleted = isDeleted
    self.season = season
    self.episode = episode
    self.isShort = isShort
    self.url = url
    self.imageURL = imageURL
  }
  public var isActive: Bool { state.isActive }
}

public struct MediaSource: Hashable, Codable, Sendable {
  public var identity: SourceIdentity
  public var title: String
  public var followed: Bool
  public var feedSince: Date?
  public var isDeleted: Bool
  public init(
    identity: SourceIdentity, title: String, followed: Bool, feedSince: Date? = nil,
    isDeleted: Bool = false
  ) {
    self.identity = identity
    self.title = title
    self.followed = followed
    self.feedSince = feedSince
    self.isDeleted = isDeleted
  }
}
