import Foundation
import Testing
@testable import MediaKit

@Suite @MainActor struct MediaLibraryTests {
  @Test func explicitActionsAndPartialBulkReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: service.now)
    await library.refresh()
    #expect(library.cards.contains { $0.title == "North Shore" })
    #expect(library.cards.first { $0.title == "North Shore" }?.nextEpisode?.title == "First light")
    let video = MediaIdentity(kind: .youtubeVideo, id: "video-one")
    library.opened(video)
    library.leaveUnchanged()
    #expect(service.writeCount == 0)
    await library.loadEpisodes(showID: "show-one")
    let preview = library.airedEpisodes(season: 1)
    #expect(preview.count == 2)
    await library.finish(preview)
    #expect(library.bulkResults.filter(\.committed).count == 1)
    #expect(library.bulkResults.first { !$0.committed }?.title == "Second tide")
    #expect(service.tables["series"]?.first?["state"] == .string("Finished"))
    #expect(service.tables["episodes"]?.last?["state"] == .string("Unseen"))
  }
  @Test func saveIsIndependentOfConsumptionAndCaptureRefreshesFeed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: service.now)
    await library.refresh()
    let video = MediaIdentity(kind: .youtubeVideo, id: "video-one")
    #expect(await library.edit(video, role: "saved", value: .bool(true)))
    #expect(service.tables["videos"]?.first?["state"] == .string("Unseen"))
    #expect(!library.canEdit(video, role: "title"))
    let draft = MediaDraft(input: "https://example.test/new", intent: .save)
    await library.capture(draft)
    #expect(workspace.captureReceipts[draft.id]?.state == "saved")
    #expect(library.cards.contains { $0.title == "A newly saved article" })
  }
  @Test func followingUsesCurrentRevisionAndActivationBoundary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: service.now)
    await library.refresh()
    let source = SourceIdentity(kind: .youtubeChannel, id: "channel-one")
    #expect(await library.follow(source, value: false))
    #expect(service.tables["channels"]?.first?["followed"] == .bool(false))
    #expect(await library.follow(source, value: true))
    #expect(service.tables["channels"]?.first?["since"] == .string(FeedQueryPlan.timestamp(service.now)))
    #expect(service.tables["videos"]?.first?["state"] == .string("Unseen"))
    #expect(!library.cards.contains { $0.identity.kind == .youtubeVideo })
  }
  @Test func consumptionStatusAndDateShareOneConditionalPatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: service.now)
    await library.refresh()
    let video = MediaIdentity(kind: .youtubeVideo, id: "video-one")
    #expect(await library.setConsumption(video, status: "Finished", date: service.now))
    #expect(service.writeCount == 1)
    #expect(service.tables["videos"]?.first?["state"] == .string("Finished"))
    #expect(service.tables["videos"]?.first?["completed"] == .string(FeedQueryPlan.day(service.now, calendar: .current)))
    #expect(service.tables["videos"]?.first?["kept"] == .bool(false))
  }
  @Test func userFieldsApplyTogetherAndRejectSourceFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: service.now)
    await library.refresh()
    let video = MediaIdentity(kind: .youtubeVideo, id: "video-one")
    #expect(!(await library.editFields(video, values: ["note": .string("Keep"), "title": .string("Changed")])))
    #expect(service.writeCount == 0)
    #expect(await library.editFields(video, values: ["note": .string("Keep"), "tags": .string("[\"For later\"]")]))
    #expect(service.writeCount == 1)
    #expect(library.records[video]?.row["notes"] == .string("Keep"))
    #expect(library.records[video]?.item.status == "Unseen")
  }

  @Test func followingUsesActionTimeAfterAppHasBeenOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    try await workspace.connect(identity: service.connection.identity, service: service)
    var current = service.now
    let library = MediaLibrary(connection: service.connection, workspace: workspace, now: current)
    await library.refresh()
    current.addTimeInterval(3600)
    #expect(await library.follow(.init(kind: .youtubeChannel, id: "channel-one"), value: true))
    #expect(service.tables["channels"]?.first?["since"] == .string(FeedQueryPlan.timestamp(current)))
  }

  @Test func filtersPersistLocallyWithoutChangingRecords() async throws {
    let name = "org.example.media-center.preferences." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try SyntheticMediaService()
    let workspace = MediaWorkspace(drafts: DraftStore(directory: root))
    let first = MediaLibrary(connection: service.connection, workspace: workspace, defaults: defaults)
    first.preferences.kinds = [.article]
    first.preferences.includeShorts = false
    let second = MediaLibrary(connection: service.connection, workspace: workspace, defaults: defaults)
    #expect(second.preferences.kinds == [.article])
    #expect(!second.preferences.includeShorts)
    #expect(service.writeCount == 0)
  }

}
