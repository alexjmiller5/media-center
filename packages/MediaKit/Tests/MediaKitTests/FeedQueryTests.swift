import Foundation
import Testing
@testable import MediaKit

@Test @MainActor func feedQueriesBoundFollowConditionsAndKeepSavesIndependent() throws {
  let binding = RecordBinding(table: "clips", fields: ["id":"id", "status":"state", "saved":"kept", "release":"released", "sourceID":"parent", "deletedAt":"deleted"], statuses: ["Unseen": .notStarted, "Next": .priority, "Watching": .inProgress, "Done": .finished])
  let sources = (0..<90).map { MediaSource(identity: .init(kind: .youtubeChannel, id: "source-\($0)"), title: "Example", followed: true, feedSince: Date(timeIntervalSince1970: 100)) }
  let plan = FeedQueryPlan.streams(bindings: .init(items: ["youtubeVideo":binding], sources: [:]), metadata: ["clips":[.init(column: "released", type: "datetime", readOnly: true)]], sources: sources, preferences: .init(), now: Date(timeIntervalSince1970: 1000), calendar: Calendar(identifier: .gregorian))
  #expect(plan.count > 3)
  #expect(plan.count <= 8) // Following more sources must not multiply the independent priority/progress reads.
  let policy = try EnrollmentPolicy()
  for stream in plan {
    let _: CoreRowsQueryRequest = try policy.invoke("normalizeRowsQuery", stream.query)
  }
  let wire = try String(data: JSONEncoder().encode(plan.map(\.query)), encoding: .utf8)!
  #expect(wire.contains("source-89"))
  #expect(wire.contains("kept"))
  #expect(!wire.contains("Done"))
}

@Test @MainActor func feedOrderingKeepsPriorityBeforeUndatedSavesAndConvertsDuration() throws {
  let now = Date(timeIntervalSince1970: 1000)
  let priority = MediaItem(identity: .init(kind: .article, id: "priority"), title: "Example", state: .priority)
  let saved = MediaItem(identity: .init(kind: .youtubeVideo, id: "saved"), title: "Example", release: .instant(now), saved: true)
  #expect(FeedQueryPlan.precedes(priority, saved, sort: .recommended, calendar: .current))
  #expect(!FeedQueryPlan.precedes(priority, saved, sort: .newest, calendar: .current))
}

@Test @MainActor func nonRecommendedSortStillQueriesFollowedUnseenReleases() throws {
  let service = try SyntheticMediaService()
  let binding = service.connection.bindings.sources["youtubeChannel"]!
  let source = try MediaSource(kind: .youtubeChannel, row: service.tables["channels"]![0], binding: binding)
  for sort in [FeedSort.newest, .oldest, .shortest, .longest] {
    var preferences = FeedPreferences(); preferences.sort = sort
    let streams = FeedQueryPlan.streams(bindings: service.connection.bindings, metadata: service.connection.metadata, sources: [source], preferences: preferences, now: service.now, calendar: .current)
    let queries = try String(data: JSONEncoder().encode(streams.filter { $0.kind == .youtubeVideo }.map(\.query)), encoding: .utf8)!
    #expect(queries.contains("channel-one"))
  }
}
