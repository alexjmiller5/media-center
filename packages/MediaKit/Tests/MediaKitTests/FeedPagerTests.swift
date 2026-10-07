import Foundation
import Testing

@testable import MediaKit

func byID(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
  if lhs.identity.id != rhs.identity.id { return lhs.identity.id < rhs.identity.id }
  return lhs.identity.kind.rawValue < rhs.identity.kind.rawValue
}

@MainActor @Test func pagerMergesAllStreamHeadsAndDeduplicatesCompoundIdentities() async throws {
  let article = MediaItem(identity: .init(kind: .article, id: "42"), title: "Article", saved: true)
  let pager = FeedPager(streams: ["videos", "articles", "empty"], pageSize: 2, orderedBefore: byID)
  { stream, cursor in
    switch stream {
    case "videos":
      return cursor == nil
        ? ItemPage(items: [video("10"), video("42")], nextCursor: "next")
        : ItemPage(items: [video("42"), video("90")])
    case "articles": return ItemPage(items: [article])
    default: return ItemPage(items: [])
    }
  }
  let first = try await pager.loadNext()
  #expect(first.items.map(\.identity.id) == ["10", "42"])
  #expect(first.items.last?.identity.kind == .article)
  #expect(first.hasMore && !first.incomplete)
  let second = try await pager.loadNext()
  #expect(second.items.map(\.identity.id) == ["42", "90"])
  #expect(second.items.first?.identity.kind == .youtubeVideo)
  let final = try await pager.loadNext()
  #expect(final.items.isEmpty && !final.hasMore)
}

@MainActor @Test func emptyCursorPagesStayTruthfullyIncompleteUntilAHeadIsAvailable() async throws {
  var page = 0
  let pager = FeedPager(streams: ["one"], pageSize: 2, orderedBefore: byID) { _, _ in
    page += 1
    return page <= 5
      ? ItemPage(items: [], nextCursor: String(page)) : ItemPage(items: [video("one")])
  }
  let first = try await pager.loadNext()
  #expect(first.items.isEmpty && first.hasMore && first.incomplete)
  let second = try await pager.loadNext()
  #expect(second.items.map(\.identity.id) == ["one"] && !second.hasMore)
}

@MainActor @Test func sourceOrConfigurationResetRejectsAStaleLoad() async throws {
  let (starts, started) = AsyncStream<Void>.makeStream()
  var reply: CheckedContinuation<ItemPage, Never>?
  var calls = 0
  let pager = FeedPager(streams: ["one"], orderedBefore: byID) { _, _ in
    calls += 1
    if calls > 1 { return ItemPage(items: [video("new")]) }
    return await withCheckedContinuation { continuation in
      reply = continuation
      started.yield(())
    }
  }
  let old = Task { try await pager.loadNext() }
  var iterator = starts.makeAsyncIterator()
  await iterator.next()
  pager.reset()
  reply?.resume(returning: ItemPage(items: [video("old")]))
  await #expect(throws: PagerError.generationChanged) { try await old.value }
  #expect(try await pager.loadNext().items.map(\.identity.id) == ["new"])
  started.finish()
}

@MainActor @Test func canceledLoadsDoNotConsumeTheirResults() async throws {
  let (starts, started) = AsyncStream<Void>.makeStream()
  var calls = 0
  let pager = FeedPager(streams: ["one"], orderedBefore: byID) { _, _ in
    calls += 1
    if calls == 1 {
      started.yield(())
      try await Task.sleep(for: .seconds(60))
    }
    return ItemPage(items: [video("one")])
  }
  let pending = Task { try await pager.loadNext() }
  var iterator = starts.makeAsyncIterator()
  await iterator.next()
  pending.cancel()
  await #expect(throws: CancellationError.self) { try await pending.value }
  #expect(try await pager.loadNext().items.map(\.identity.id) == ["one"])
  started.finish()
}

@MainActor @Test func rejectedOrStalledCursorsRequireAnExplicitRestart() async throws {
  var rejected = true
  let pager = FeedPager(streams: ["one"], orderedBefore: byID) { _, _ in
    if rejected { throw PagerError.cursorRejected }
    return ItemPage(items: [video("one")])
  }
  await #expect(throws: PagerError.cursorRejected) { try await pager.loadNext() }
  rejected = false
  await #expect(throws: PagerError.cursorRejected) { try await pager.loadNext() }
  pager.reset()
  #expect(try await pager.loadNext().items.count == 1)
  let stalled = FeedPager(streams: ["one"], orderedBefore: byID) { _, _ in
    ItemPage(items: [], nextCursor: "same")
  }
  await #expect(throws: PagerError.stalledCursor) { try await stalled.loadNext() }
}
