import Foundation

public enum MediaRecordError: Error, Equatable { case invalidField(String) }

public struct MediaRecord: Codable, Equatable, Sendable {
  public let item: MediaItem
  public let revision: CoreRevision
  public let row: CoreRow
  public init(kind: MediaKind, row: CoreRow, binding: RecordBinding) throws {
    let reader = RecordReader(row: row, binding: binding)
    let id = try reader.requiredText("id")
    let status = try reader.requiredText("status")
    guard let state = binding.state(for: status) else {
      throw MediaRecordError.invalidField("status")
    }
    let duration = try reader.number("duration")
    var minutes: Double?
    if binding.fields["duration"] != nil {
      guard let unit = binding.durationUnit else {
        throw MediaRecordError.invalidField("durationUnit")
      }
      switch unit {
      case .seconds: minutes = duration.map { $0 / 60 }
      case .minutes: minutes = duration
      case .milliseconds: minutes = duration.map { $0 / 60000 }
      }
    }
    let sourceID = try reader.text("sourceID")
    let sourceKind: SourceKind?
    switch kind {
    case .tvEpisode: sourceKind = .tvShow
    case .youtubeVideo: sourceKind = .youtubeChannel
    case .article: sourceKind = .feed
    default: sourceKind = nil
    }
    if sourceID != nil && sourceKind == nil { throw MediaRecordError.invalidField("sourceID") }
    item = MediaItem(
      identity: .init(kind: kind, id: id), title: try reader.text("title") ?? "Untitled",
      source: sourceID.flatMap { id in sourceKind.map { .init(kind: $0, id: id) } },
      release: try reader.release("release"), durationMinutes: minutes,
      status: status, state: state, saved: try reader.boolean("saved") ?? false,
      isDeleted: try reader.text("deletedAt") != nil,
      season: try reader.integer("season"), episode: try reader.integer("episode"),
      isShort: try reader.boolean("isShort"), url: try reader.webURL("url"),
      imageURL: try reader.webURL("imageURL"))
    revision = try reader.revision()
    self.row = row
  }
}

struct RecordReader {
  let row: CoreRow
  let binding: RecordBinding
  func value(_ role: String) throws -> CoreJSONValue? {
    guard let column = binding.fields[role] else { return nil }
    guard let value = row[column] else { throw MediaRecordError.invalidField(role) }
    return value == .null ? nil : value
  }
  func text(_ role: String) throws -> String? {
    guard let value = try value(role) else { return nil }
    guard case .string(let text) = value else { throw MediaRecordError.invalidField(role) }
    return text
  }
  func requiredText(_ role: String) throws -> String {
    guard let value = try text(role), !value.isEmpty else {
      throw MediaRecordError.invalidField(role)
    }
    return value
  }
  func number(_ role: String) throws -> Double? {
    guard let value = try value(role) else { return nil }
    guard case .number(let number) = value, number.isFinite, number >= 0 else {
      throw MediaRecordError.invalidField(role)
    }
    return number
  }
  func integer(_ role: String) throws -> Int? {
    guard let value = try number(role) else { return nil }
    guard value.rounded() == value, value < Double(Int.max) else {
      throw MediaRecordError.invalidField(role)
    }
    return Int(value)
  }
  func boolean(_ role: String) throws -> Bool? {
    guard let value = try value(role) else { return nil }
    switch value {
    case .bool(let bool): return bool
    case .number(0): return false
    case .number(1): return true
    default: throw MediaRecordError.invalidField(role)
    }
  }
  func webURL(_ role: String) throws -> URL? {
    guard let text = try text(role), let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
      url.user == nil, url.password == nil
    else { return nil }
    return url
  }
  func release(_ role: String) throws -> MediaRelease? {
    guard let text = try text(role) else { return nil }
    if text.count == 10 {
      let parts = text.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
        let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
      else { throw MediaRecordError.invalidField(role) }
      let release = MediaRelease.day(year: year, month: month, day: day)
      guard release.orderingDate(calendar: Calendar(identifier: .gregorian)) != nil else {
        throw MediaRecordError.invalidField(role)
      }
      return release
    }
    guard let date = Self.instant(text) else { throw MediaRecordError.invalidField(role) }
    return .instant(date)
  }
  static func instant(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
  func revision() throws -> CoreRevision {
    let updatedAt = try requiredText("updatedAt")
    let hubAt = try text("hubAt")
    guard Self.instant(updatedAt) != nil, hubAt == nil || Self.instant(hubAt!) != nil else {
      throw MediaRecordError.invalidField("revision")
    }
    return .init(updatedAt: updatedAt, hubAt: hubAt)
  }
}

extension MediaSource {
  public init(kind: SourceKind, row: CoreRow, binding: RecordBinding) throws {
    let reader = RecordReader(row: row, binding: binding)
    let boundary = try reader.text("feedSince")
    if let boundary, RecordReader.instant(boundary) == nil {
      throw MediaRecordError.invalidField("feedSince")
    }
    self.init(
      identity: .init(kind: kind, id: try reader.requiredText("id")),
      title: try reader.text("title") ?? "Untitled source",
      followed: try reader.boolean("follow") ?? false,
      feedSince: boundary.flatMap(RecordReader.instant),
      isDeleted: try reader.text("deletedAt") != nil)
  }
}
