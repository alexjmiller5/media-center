import Foundation
import Testing
@testable import MediaKit

let showSource = SourceIdentity(kind: .tvShow, id: "show-1")
func episode(_ number: Int, season: Int = 1, status: String = "Not Started",
             release: MediaRelease? = .day(year: 2026, month: 10, day: 6)) -> MediaItem {
    MediaItem(identity: .init(kind: .tvEpisode, id: "s\(season)e\(number)"), title: "Episode \(number)",
              source: showSource, release: release, status: status, state: fixtureState(status), season: season, episode: number)
}

@Test func tenQualifyingEpisodesBecomeOneShowCard() {
    let source = MediaSource(identity: showSource, title: "Synthetic series", followed: true,
                             feedSince: now.addingTimeInterval(-86400 * 3))
    let episodes = (1...10).map { episode($0) }
    let cards = FeedPolicy.cards(items: episodes, sources: [source], now: now, calendar: utc)
    #expect(cards.count == 1)
    #expect(cards.first?.identity == MediaIdentity(kind: .tvShow, id: "show-1"))
    #expect(cards.first?.nextEpisode?.episode == 1)
}

@Test func nextEpisodeSkipsSpecialsCompletedFutureAndUnknownAirDates() {
    let episodes = [episode(1, season: 0), episode(1, status: "Finished"), episode(2),
                    episode(3, release: .day(year: 2026, month: 10, day: 9)), episode(4, release: nil)]
    #expect(TVProgress.nextEpisode(episodes: episodes, now: now, calendar: utc)?.episode == 2)
    #expect(TVProgress.nextEpisode(episodes: [episode(1, season: 0)], now: now, calendar: utc) == nil)
}

@Test func finishedSeriesSurfacesForNewEpisodeWithoutChangingSeriesStatus() {
    let series = MediaItem(identity: .init(kind: .tvShow, id: "show-1"), title: "Series", status: "Finished", state: .finished)
    let source = MediaSource(identity: showSource, title: "Series", followed: true,
                             feedSince: now.addingTimeInterval(-86400 * 2))
    let cards = FeedPolicy.cards(items: [series, episode(1)], sources: [source], now: now, calendar: utc)
    #expect(cards.count == 1)
    #expect(cards.first?.reasons == [.newRelease])
    #expect(series.status == "Finished")
}

@Test func savedUnfollowedSeriesCanSuggestAnOlderEpisode() {
    let series = MediaItem(identity: .init(kind: .tvShow, id: "show-1"), title: "Series", saved: true)
    let cards = FeedPolicy.cards(items: [series, episode(1)], sources: [], now: now, calendar: utc)
    #expect(cards.count == 1)
    #expect(cards.first?.nextEpisode?.episode == 1)
    #expect(cards.first?.reasons == [.saved])
}

@Test func dateOnlyBoundaryUsesUserCalendarInsteadOfInventingReleaseInstant() {
    var calendar = utc
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let instant = Date(timeIntervalSince1970: 1_791_331_200) // 2026-10-07 00:00 UTC, Oct 6 locally
    let source = MediaSource(identity: showSource, title: "Series", followed: true, feedSince: instant)
    #expect(FeedPolicy.eligible(item: episode(1), source: source, now: instant, calendar: calendar) == [.newRelease])
    #expect(FeedPolicy.eligible(item: episode(2, release: .day(year: 2026, month: 10, day: 7)), source: source, now: instant, calendar: calendar).isEmpty)
}
