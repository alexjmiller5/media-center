import Foundation

public struct ItemPage: Sendable {
  public var items: [MediaItem]
  public var nextCursor: String?
  public init(items: [MediaItem], nextCursor: String? = nil) {
    self.items = items
    self.nextCursor = nextCursor
  }
}
public struct FeedPage: Sendable {
  public var items: [MediaItem]
  public var hasMore: Bool
  public var incomplete: Bool
}
public enum PagerError: Error, Equatable {
  case alreadyLoading, generationChanged, cursorRejected, stalledCursor, invalidPage
}

/// Merges bounded, consistently ordered streams. It does not promise a snapshot
/// across network requests. Reset whenever source configuration or filters change.
@MainActor public final class FeedPager {
  public typealias Fetch = @MainActor @Sendable (String, String?) async throws -> ItemPage
  private struct Stream {
    var id: String
    var buffer: [MediaItem] = []
    var cursor: String?
    var exhausted = false
    var lastFetched: MediaItem?
  }
  private let streamIDs: [String]
  private let pageSize: Int
  private let orderedBefore: @Sendable (MediaItem, MediaItem) -> Bool
  private let fetch: Fetch
  private var streams: [Stream]
  private var seen: Set<MediaIdentity> = []
  private var generation = 0
  private var activeLoad: UUID?
  private var restartError: PagerError?

  public init(
    streams: [String], pageSize: Int = 50,
    orderedBefore: @escaping @Sendable (MediaItem, MediaItem) -> Bool,
    fetch: @escaping Fetch
  ) {
    var unique: [String] = []
    for stream in streams where !unique.contains(stream) { unique.append(stream) }
    streamIDs = unique
    self.streams = unique.map { Stream(id: $0) }
    self.pageSize = min(200, max(1, pageSize))
    self.orderedBefore = orderedBefore
    self.fetch = fetch
  }

  public func reset() {
    generation += 1
    streams = streamIDs.map { Stream(id: $0) }
    seen = []
    activeLoad = nil
    restartError = nil
  }

  public func loadNext() async throws -> FeedPage {
    if let restartError { throw restartError }
    guard activeLoad == nil else { throw PagerError.alreadyLoading }
    let operation = UUID()
    let startedGeneration = generation
    activeLoad = operation
    defer { if activeLoad == operation { activeLoad = nil } }
    var working = streams
    var consumed = seen
    var result: [MediaItem] = []
    var incomplete = false
    do {
      while result.count < pageSize {
        try Task.checkCancellation()
        for index in working.indices
        where working[index].buffer.isEmpty && !working[index].exhausted {
          var emptyPages = 0
          while working[index].buffer.isEmpty && !working[index].exhausted {
            let cursor = working[index].cursor
            let page = try await fetch(working[index].id, cursor)
            try Task.checkCancellation()
            guard generation == startedGeneration else { throw PagerError.generationChanged }
            guard page.items.count <= 200, page.nextCursor != "" else {
              throw PagerError.invalidPage
            }
            if let next = page.nextCursor, next == cursor { throw PagerError.stalledCursor }
            if let previous = working[index].lastFetched, let first = page.items.first,
              orderedBefore(first, previous)
            {
              throw PagerError.invalidPage
            }
            for pair in zip(page.items, page.items.dropFirst()) where orderedBefore(pair.1, pair.0)
            {
              throw PagerError.invalidPage
            }
            working[index].buffer = page.items
            working[index].cursor = page.nextCursor
            working[index].exhausted = page.nextCursor == nil
            if let last = page.items.last { working[index].lastFetched = last }
            emptyPages += 1
            if emptyPages == 4 && page.items.isEmpty && page.nextCursor != nil {
              incomplete = true
              break
            }
          }
          if incomplete { break }
        }
        if incomplete { break }
        let heads = working.indices.filter { !working[$0].buffer.isEmpty }
        guard
          let next = heads.min(by: { orderedBefore(working[$0].buffer[0], working[$1].buffer[0]) })
        else { break }
        let item = working[next].buffer.removeFirst()
        if consumed.insert(item.identity).inserted { result.append(item) }
      }
      try Task.checkCancellation()
      guard generation == startedGeneration else { throw PagerError.generationChanged }
      streams = working
      seen = consumed
      return FeedPage(
        items: result, hasMore: working.contains { !$0.exhausted || !$0.buffer.isEmpty },
        incomplete: incomplete)
    } catch {
      if generation == startedGeneration,
        let error = error as? PagerError,
        [.cursorRejected, .stalledCursor, .invalidPage].contains(error)
      {
        restartError = error
      }
      throw error
    }
  }
}
