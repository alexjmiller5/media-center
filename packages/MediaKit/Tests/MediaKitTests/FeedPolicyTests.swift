import Foundation
import Testing
@testable import MediaKit

let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07 12:00 UTC
var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
let channel = SourceIdentity(kind: .youtubeChannel, id: "channel-1")

func video(_ id: String = "video-1", saved: Bool = false, status: String = "Not Started",
           release: MediaRelease? = .instant(now.addingTimeInterval(-3600))) -> MediaItem {
    MediaItem(identity: .init(kind: .youtubeVideo, id: id), title: id, source: channel,
              release: release, status: status, state: fixtureState(status), saved: saved)
}
func reasons(_ item: MediaItem, _ source: MediaSource? = nil) -> Set<FeedReason> {
    FeedPolicy.eligible(item: item, source: source, now: now, calendar: utc)
}

@Test func followBoundaryNeverTurnsOldCatalogIntoQueue() {
    let source = MediaSource(identity: channel, title: "Source", followed: true, feedSince: now)
    #expect(reasons(video(), source).isEmpty)
    #expect(reasons(video(saved: true), source) == [.saved])
    #expect(reasons(video(status: "In Progress")) == [.inProgress])
    #expect(reasons(video(status: "Priority")) == [.priority])
    #expect(reasons(video(release: nil), source).isEmpty)
}

@Test func overlappingReasonsDoNotDuplicateRecordsAndKindsCannotCollide() {
    let source = MediaSource(identity: channel, title: "Source", followed: true,
                             feedSince: now.addingTimeInterval(-86400))
    let item = video("42", saved: true, status: "In Progress")
    #expect(reasons(item, source) == [.saved, .inProgress, .newRelease])
    let article = MediaItem(identity: .init(kind: .article, id: "42"), title: "Article", saved: true)
    let cards = FeedPolicy.cards(items: [item, item, article], sources: [source], now: now, calendar: utc)
    #expect(cards.count == 2)
    #expect(Set(cards.map(\.identity)).count == 2)
}

@Test(arguments: ["Finished", "Gave Up", "Watched Parts"])
func savedDoesNotResetConsumption(status: String) {
    #expect(reasons(video(saved: true, status: status)).isEmpty)
}

@Test func tombstonesAndDeletedSourcesDoNotResurrectItems() {
    var source = MediaSource(identity: channel, title: "Source", followed: true,
                             feedSince: now.addingTimeInterval(-86400))
    source.isDeleted = true
    #expect(reasons(video(), source).isEmpty)
    #expect(reasons(video(saved: true), source) == [.saved])
    var deleted = video(saved: true)
    deleted.isDeleted = true
    #expect(reasons(deleted, source).isEmpty)
}

@Test func upcomingSaveIsVisibleButNotANewRelease() {
    let item = video(saved: true, release: .instant(now.addingTimeInterval(86400)))
    #expect(reasons(item) == [.saved])
    #expect(FeedPolicy.cards(items: [item], sources: [], now: now, calendar: utc).first?.isUpcoming == true)
}

@Test func defaultRankingAndNullOrderingRemainDeterministic() {
    var older = video("old", saved: true, release: .instant(now.addingTimeInterval(-86400)))
    older.durationMinutes = 4
    var newer = video("new", saved: true)
    newer.durationMinutes = 10
    let unknown = video("unknown", saved: true, release: nil)
    let progress = video("progress", status: "In Progress")
    let priority = video("priority", status: "Priority")
    let items = [unknown, older, newer, progress, priority]
    #expect(FeedPolicy.cards(items: items, sources: [], now: now, calendar: utc).map(\.identity.id) == ["priority", "progress", "new", "old", "unknown"])
    var preferences = FeedPreferences()
    preferences.sort = .shortest
    #expect(FeedPolicy.cards(items: [unknown, newer, older], sources: [], preferences: preferences, now: now, calendar: utc).map(\.identity.id) == ["old", "new", "unknown"])
    preferences.sort = .oldest
    #expect(FeedPolicy.cards(items: [unknown, newer, older], sources: [], preferences: preferences, now: now, calendar: utc).map(\.identity.id) == ["old", "new", "unknown"])
}

@Test func runtimeFiltersDoNotChangeRecords() {
    let item = video(saved: true)
    var preferences = FeedPreferences()
    preferences.kinds = [.article]
    #expect(FeedPolicy.cards(items: [item], sources: [], preferences: preferences, now: now, calendar: utc).isEmpty)
    #expect(item.saved && item.status == "Not Started")
    preferences.kinds = []
    preferences.search = "SOURCE"
    let source = MediaSource(identity: channel, title: "Source", followed: false)
    #expect(FeedPolicy.cards(items: [item], sources: [source], preferences: preferences, now: now, calendar: utc).count == 1)
}

func fixtureState(_ label: String) -> ConsumptionState {
    ["Not Started": .notStarted, "In Progress": .inProgress, "Priority": .priority, "Finished": .finished, "Gave Up": .gaveUp, "Watched Parts": .watchedParts][label]!
}
