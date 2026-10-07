import Foundation

public enum TVProgress {
    public static func nextEpisode(episodes: [MediaItem], now: Date, calendar: Calendar) -> MediaItem? {
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
}
