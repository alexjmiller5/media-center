import Foundation

/// A show-level fact for TV cards and details. Quiet labels are secondary: the user is not done.
public struct SeriesLabel: Equatable, Sendable {
  public var text: String
  public var isQuiet: Bool
  public init(text: String, isQuiet: Bool) {
    self.text = text
    self.isQuiet = isQuiet
  }
}

public enum TVProgress {
  public static func nextEpisode(episodes: [MediaItem], now: Date, calendar: Calendar) -> MediaItem?
  {
    episodes.filter {
      $0.identity.kind == .tvEpisode && !$0.isDeleted && $0.isActive
        && ($0.season ?? 0) > 0 && ($0.episode ?? 0) > 0
        && $0.release?.isReleased(at: now, calendar: calendar) == true
    }.sorted {
      if $0.season != $1.season { return $0.season! < $1.season! }
      if $0.episode != $1.episode { return $0.episode! < $1.episode! }
      return $0.identity.id < $1.identity.id
    }.first
  }
  /// The user's own progress plus the catalog's production status; nil for any other or missing status.
  public static func seriesLabel(state: ConsumptionState, seriesStatus: String?) -> SeriesLabel? {
    switch (state == .finished, seriesStatus) {
    case (true, "Returning Series"), (true, "In Production"), (true, "Planned"):
      return .init(text: "Caught up, awaiting new season", isQuiet: false)
    case (true, "Ended"): return .init(text: "Show ended", isQuiet: false)
    case (true, "Canceled"): return .init(text: "Show canceled", isQuiet: false)
    case (false, "Ended"): return .init(text: "Ended", isQuiet: true)
    case (false, "Canceled"): return .init(text: "Canceled", isQuiet: true)
    default: return nil
    }
  }
}
