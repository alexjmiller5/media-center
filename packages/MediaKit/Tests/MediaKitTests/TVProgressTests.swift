import Foundation
import Testing

@testable import MediaKit

let showSource = SourceIdentity(kind: .tvShow, id: "show-1")
func episode(
  _ number: Int, season: Int = 1, status: String = "Not Started",
  release: MediaRelease? = .day(year: 2026, month: 10, day: 6)
) -> MediaItem {
  MediaItem(
    identity: .init(kind: .tvEpisode, id: "s\(season)e\(number)"), title: "Episode \(number)",
    source: showSource, release: release, status: status, state: fixtureState(status),
    season: season, episode: number)
}

@Test func tenQualifyingEpisodesBecomeOneShowCard() {
  let source = MediaSource(
    identity: showSource, title: "Synthetic series", followed: true,
    feedSince: now.addingTimeInterval(-86400 * 3))
  let episodes = (1...10).map { episode($0) }
  let cards = FeedPolicy.cards(items: episodes, sources: [source], now: now, calendar: utc)
  #expect(cards.count == 1)
  #expect(cards.first?.identity == MediaIdentity(kind: .tvShow, id: "show-1"))
  #expect(cards.first?.nextEpisode?.episode == 1)
}

@Test func nextEpisodeSkipsSpecialsCompletedFutureAndUnknownAirDates() {
  let episodes = [
    episode(1, season: 0), episode(1, status: "Finished"), episode(2),
    episode(3, release: .day(year: 2026, month: 10, day: 9)), episode(4, release: nil),
  ]
  #expect(TVProgress.nextEpisode(episodes: episodes, now: now, calendar: utc)?.episode == 2)
  #expect(TVProgress.nextEpisode(episodes: [episode(1, season: 0)], now: now, calendar: utc) == nil)
}

@Test func finishedSeriesSurfacesForNewEpisodeWithoutChangingSeriesStatus() {
  let series = MediaItem(
    identity: .init(kind: .tvShow, id: "show-1"), title: "Series", status: "Finished",
    state: .finished)
  let source = MediaSource(
    identity: showSource, title: "Series", followed: true,
    feedSince: now.addingTimeInterval(-86400 * 2))
  let cards = FeedPolicy.cards(
    items: [series, episode(1)], sources: [source], now: now, calendar: utc)
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
  let instant = Date(timeIntervalSince1970: 1_791_331_200)  // 2026-10-07 00:00 UTC, Oct 6 locally
  let source = MediaSource(
    identity: showSource, title: "Series", followed: true, feedSince: instant)
  #expect(
    FeedPolicy.eligible(item: episode(1), source: source, now: instant, calendar: calendar) == [
      .newRelease
    ])
  #expect(
    FeedPolicy.eligible(
      item: episode(2, release: .day(year: 2026, month: 10, day: 7)), source: source, now: instant,
      calendar: calendar
    ).isEmpty)
}

@Test func sourceFilterIncludesExplicitlySavedSeriesWithoutAnItemParent() {
  let series = MediaItem(identity: .init(kind: .tvShow, id: "show-1"), title: "Series", saved: true)
  var preferences = FeedPreferences()
  preferences.sources = [showSource]
  #expect(
    FeedPolicy.cards(
      items: [series], sources: [], preferences: preferences, now: now, calendar: utc
    ).count == 1)
}

@Test func groupedShowUsesSourceTitleAndDoesNotInventANextEpisode() {
  var special = episode(1, season: 0)
  special.saved = true
  let source = MediaSource(identity: showSource, title: "Series", followed: false)
  let card = FeedPolicy.cards(items: [special], sources: [source], now: now, calendar: utc).first
  #expect(card?.title == "Series")
  #expect(card?.nextEpisode == nil)
}

@Test(arguments: [Calendar.Identifier.buddhist, .hebrew, .islamic])
func catalogDaysRemainGregorianWithTheDeviceTimeZone(identifier: Calendar.Identifier) {
  var device = Calendar(identifier: identifier)
  device.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  var gregorian = utc
  gregorian.timeZone = device.timeZone
  let future = MediaRelease.day(year: 2026, month: 10, day: 9)
  #expect(future.orderingDate(calendar: device) == future.orderingDate(calendar: gregorian))
  #expect(!future.isReleased(at: now, calendar: device))
  #expect(FeedQueryPlan.day(now, calendar: device) == FeedQueryPlan.day(now, calendar: gregorian))
  #expect(TVProgress.nextEpisode(episodes: [episode(1, release: future)], now: now, calendar: device) == nil)
}

@Test func groupedShowCardDisplaysItsNextEpisodeWhateverTheInputOrder() {
  let source = MediaSource(
    identity: showSource, title: "Synthetic series", followed: true,
    feedSince: now.addingTimeInterval(-86400 * 3))
  // "s1e10" sorts before "s1e2", so identity order alone would pick the wrong episode.
  let episodes = [episode(10), episode(1, status: "Finished"), episode(2)]
  for order in [episodes, episodes.reversed(), [episodes[1], episodes[2], episodes[0]]] {
    let card = FeedPolicy.cards(items: order, sources: [source], now: now, calendar: utc).first
    #expect(card?.nextEpisode?.episode == 2)
    #expect(card?.item.identity == card?.nextEpisode?.identity)
  }
}
