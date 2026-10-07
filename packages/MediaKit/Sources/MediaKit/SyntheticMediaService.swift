#if DEBUG
import Foundation
import Observation

/// Isolated UI-test/preview service. Release builds contain neither fixture records nor this service.
@Observable @MainActor public final class SyntheticMediaService: MediaService {
  public let connection: MediaConnection
  public let now: Date
  public var nextWriteError: HubError?
  public private(set) var writeCount = 0
  public private(set) var tables: [String: [CoreRow]] = [:]
  private var captures: [String: CaptureReceipt] = [:]
  public init(now: Date = Date(timeIntervalSince1970: 1_790_856_000)) throws {
    self.now = now
    let statuses: [String: ConsumptionState] = ["Unseen": .notStarted, "Next": .priority, "Watching": .inProgress, "Finished": .finished, "Abandoned": .gaveUp, "Some watched": .watchedParts]
    let common = ["id":"id", "title":"heading", "status":"state", "saved":"kept", "updatedAt":"updated_at", "hubAt":"hub_at", "deletedAt":"deleted_at", "release":"released", "url":"link", "consumedAt":"completed", "note":"notes", "tags":"labels"]
    var articles = common; articles["sourceID"] = "parent"
    var videos = articles; videos["duration"] = "seconds"; videos["isShort"] = "short"
    var episodes = articles; episodes["season"] = "season"; episodes["episode"] = "number"; episodes["duration"] = "minutes"
    let source = ["id":"id", "title":"heading", "follow":"followed", "feedSince":"since", "updatedAt":"updated_at", "hubAt":"hub_at", "deletedAt":"deleted_at"]
    let bindings = MediaBindings(items: [
      "article": .init(table: "reads", fields: articles, statuses: statuses),
      "youtubeVideo": .init(table: "videos", fields: videos, statuses: statuses, durationUnit: .seconds),
      "tvShow": .init(table: "series", fields: common, statuses: statuses),
      "tvEpisode": .init(table: "episodes", fields: episodes, statuses: statuses, durationUnit: .minutes)
    ], sources: ["feed": .init(table: "publishers", fields: source), "youtubeChannel": .init(table: "channels", fields: source), "tvShow": .init(table: "series", fields: source)])
    var metadata: [String: [PropertyMetadata]] = [:]
    var scopes = Set<String>()
    for binding in Array(bindings.items.values) + Array(bindings.sources.values) {
      for (role, column) in binding.fields {
        scopes.insert("tables:read:\(binding.table):\(column)")
        scopes.insert("catalog:read:\(binding.table):\(column)")
        let editable = ["status", "saved", "consumedAt", "note", "tags", "follow", "feedSince"].contains(role)
        if editable { scopes.insert("tables:patch:\(binding.table):\(column)") }
        let type: String
        switch role {
        case "status": type = "select"
        case "saved", "follow", "isShort": type = "bool"
        case "sourceID": type = "ref"
        case "tags": type = "multi_select"
        case "season", "episode", "duration": type = "int"
        case "consumedAt": type = "date"
        case "release": type = ["series", "episodes"].contains(binding.table) ? "date" : "datetime"
        case "updatedAt", "hubAt", "deletedAt", "feedSince": type = "datetime"
        default: type = "text"
        }
        if metadata[binding.table, default: []].contains(where: { $0.column == column }) { continue }
        metadata[binding.table, default: []].append(.init(column: column, type: type, readOnly: !editable,
          options: role == "status" ? statuses.keys.sorted() : role == "tags" ? ["Favorite", "For later"] : nil))
      }
    }
    scopes.formUnion(["captures:read:media", "captures:submit:media"])
    let revision = String(repeating: "a", count: 64)
    connection = MediaConnection(identity: try .init(endpoint: URL(string: "https://example.test")!, profile: "media-center", revision: revision, credentialID: "synthetic"),
      session: .init(name: "synthetic", scopes: scopes.sorted(), replica: .init(allowed: false, reason: nil), enrollmentProfile: .init(id: "media-center", revision: revision)),
      bindings: bindings, metadata: metadata, capabilities: .object(["row_query": .string("bounded-v1"), "captures": .object(["protocol": .string("receipt-v1"), "adapters": .array([.object(["id": .string("media"), "read": .bool(true), "submit": .bool(true)])])])]))
    func row(_ id: String, _ title: String, days: Double = -1, saved: Bool = false, status: String = "Unseen", parent: String? = nil) -> CoreRow {
      ["id": .string(id), "heading": .string(title), "state": .string(status), "kept": .bool(saved),
       "updated_at": .string(FeedQueryPlan.timestamp(now)), "hub_at": .null, "deleted_at": .null,
       "released": .string(FeedQueryPlan.timestamp(now.addingTimeInterval(days * 86400))), "link": .string("https://example.test/\(id)"),
       "completed": .null, "notes": .null, "labels": .string("[]"), "parent": parent.map(CoreJSONValue.string) ?? .null]
    }
    func sourceRow(_ id: String, _ title: String) -> CoreRow {
      ["id": .string(id), "heading": .string(title), "followed": .bool(true), "since": .string(FeedQueryPlan.timestamp(now.addingTimeInterval(-7 * 86400))),
       "updated_at": .string(FeedQueryPlan.timestamp(now)), "hub_at": .null, "deleted_at": .null]
    }
    tables["reads"] = [row("article-one", "The quiet city", saved: true, parent: "publisher-one"), row("article-history", "A finished story", days: -10, status: "Finished", parent: "publisher-one")]
    var video = row("video-one", "How a coastline changes", parent: "channel-one")
    video["seconds"] = .number(840); video["short"] = .bool(false)
    tables["videos"] = [video]
    var show = row("show-one", "North Shore", days: -100, status: "Finished")
    show["released"] = .string(FeedQueryPlan.day(now.addingTimeInterval(-100 * 86400), calendar: .current))
    show.merge(sourceRow("show-one", "North Shore")) { _, source in source }
    tables["series"] = [show]
    tables["episodes"] = [(-20.0, "episode-one", "First light", 1), (-2.0, "episode-two", "Second tide", 2), (7.0, "episode-three", "Beyond the headland", 3)].map { days, id, title, number in
      var episode = row(id, title, days: days, parent: "show-one")
      episode["released"] = .string(FeedQueryPlan.day(now.addingTimeInterval(days * 86400), calendar: .current))
      episode["season"] = .number(1); episode["number"] = .number(Double(number)); episode["minutes"] = .number(42)
      return episode
    }
    tables["publishers"] = [sourceRow("publisher-one", "Field Notes")]
    tables["channels"] = [sourceRow("channel-one", "Low Tide Studio")]
  }
  public func query(_ query: RowQuery) async throws -> RowPage {
    var rows = tables[query.table, default: []].filter { row in query.filter.map { accepts($0, row: row) } ?? true }
    var order = query.order ?? []
    if !order.contains(where: { $0.column == "id" }) { order.append(.init(column: "id", direction: "asc")) }
    rows.sort { lhs, rhs in
      for part in order {
        let l = lhs[part.column] ?? .null, r = rhs[part.column] ?? .null
        if l == r { continue }
        if l == .null { return false }; if r == .null { return true }
        let ascending = compare(l, r)
        return part.direction == "asc" ? ascending : !ascending
      }
      return false
    }
    let offset = query.cursor.flatMap(Int.init) ?? 0
    let page = Array(rows.dropFirst(offset).prefix(query.limit ?? 50))
    return .init(rows: page.map { row in Dictionary(uniqueKeysWithValues: query.columns.map { ($0, row[$0] ?? .null) }) }, nextCursor: offset + page.count < rows.count ? String(offset + page.count) : nil)
  }
  public func patch(_ edit: ConditionalEdit) async throws -> PatchReceipt {
    if let nextWriteError { throw nextWriteError }
    writeCount += 1
    guard edit.id != "episode-two" else { throw HubError.rejected(422) }
    guard let index = tables[edit.table]?.firstIndex(where: { $0["id"] == .string(edit.id) }), let old = tables[edit.table]?[index],
      old["updated_at"] == .string(edit.expectedRevision.updatedAt), old["hub_at"] == (edit.expectedRevision.hubAt.map(CoreJSONValue.string) ?? .null) else { throw HubError.conflict }
    var changed = old
    changed.merge(edit.values) { _, new in new }
    let revision = CoreRevision(updatedAt: FeedQueryPlan.timestamp(now.addingTimeInterval(Double(writeCount))), hubAt: nil)
    changed["updated_at"] = .string(revision.updatedAt)
    tables[edit.table]![index] = changed
    return .init(id: edit.id, revision: revision)
  }
  public func submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt {
    if let nextWriteError { throw nextWriteError }
    if let receipt = captures[request.requestId] { return receipt }
    writeCount += 1
    let id = "captured-" + request.requestId
    var row = tables["reads"]![0]
    row["id"] = .string(id); row["heading"] = .string("A newly saved article")
    row["kept"] = .bool(true); row["parent"] = .null
    tables["reads", default: []].append(row)
    let receipt = CaptureReceipt(requestId: request.requestId, state: "saved", item: .init(kind: "article", id: id))
    captures[request.requestId] = receipt
    return receipt
  }
  public func captureReceipt(id: String) async throws -> CaptureReceipt { captures[id] ?? .init(requestId: id, state: "uncertain") }
  public func close() {}
  private func compare(_ lhs: CoreJSONValue, _ rhs: CoreJSONValue) -> Bool {
    if case .number(let l) = lhs, case .number(let r) = rhs { return l < r }
    if case .string(let l) = lhs, case .string(let r) = rhs { return l.utf8.lexicographicallyPrecedes(r.utf8) }
    return false
  }
  private func accepts(_ filter: CoreJSONValue, row: CoreRow) -> Bool {
    guard case .object(let filter) = filter else { return false }
    if case .array(let children) = filter["and"] { return children.allSatisfy { accepts($0, row: row) } }
    if case .array(let children) = filter["or"] { return children.contains { accepts($0, row: row) } }
    guard case .string(let column) = filter["column"], case .string(let op) = filter["op"], let expected = filter["value"] else { return false }
    let actual = row[column] ?? .null
    switch op {
    case "eq": return actual == expected
    case "in": if case .array(let values) = expected { return values.contains(actual) }; return false
    case "is_null": return expected == .bool(actual == .null)
    case "gte": return actual != .null && (actual == expected || compare(expected, actual))
    case "lte": return actual != .null && (actual == expected || compare(actual, expected))
    case "contains": if case .string(let a) = actual, case .string(let e) = expected { return a.localizedCaseInsensitiveContains(e) }; return false
    default: return false
    }
  }
}
#endif
