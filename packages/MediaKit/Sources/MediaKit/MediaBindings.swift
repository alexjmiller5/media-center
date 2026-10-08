import Foundation

public enum ConsumptionState: String, Codable, CaseIterable, Sendable {
  case notStarted, inProgress, priority, finished, gaveUp, watchedParts, other
  public var isActive: Bool { ![Self.finished, .gaveUp, .watchedParts].contains(self) }
}
public enum DurationUnit: String, Codable, Sendable { case seconds, minutes, milliseconds }
public struct RecordBinding: Codable, Equatable, Sendable {
  public var table: String
  public var fields: [String: String]
  public var statuses: [String: ConsumptionState]
  public var durationUnit: DurationUnit?
  public init(
    table: String, fields: [String: String], statuses: [String: ConsumptionState] = [:],
    durationUnit: DurationUnit? = nil
  ) {
    self.table = table
    self.fields = fields
    self.statuses = statuses
    self.durationUnit = durationUnit
  }
  public func state(for status: String) -> ConsumptionState? { statuses[status] }
}
public struct PropertyMetadata: Codable, Equatable, Sendable {
  public var column: String
  public var type: String
  public var readOnly: Bool
  public var required: Bool
  public var description: String?
  public var options: [String]?
  public init(
    column: String, type: String, readOnly: Bool, required: Bool = false,
    description: String? = nil, options: [String]? = nil
  ) {
    self.column = column
    self.type = type
    self.readOnly = readOnly
    self.required = required
    self.description = description
    self.options = options
  }
}
public enum BindingError: Error, Equatable {
  case invalidRole(String)
  case missingField(String, String)
  case insufficientScope(String, String)
  case incompatibleType(String, String)
  case unsupportedIdentity(String)
  case invalidStatusMapping(String)
}
public struct MediaBindings: Codable, Equatable, Sendable {
  public var items: [String: RecordBinding]
  public var sources: [String: RecordBinding]
  public init(items: [String: RecordBinding], sources: [String: RecordBinding]) {
    self.items = items
    self.sources = sources
  }
  public func validate(scopes: Set<String>, metadata: [String: [PropertyMetadata]]) throws {
    for (role, binding) in items {
      guard MediaKind(rawValue: role) != nil else { throw BindingError.invalidRole(role) }
      try validate(
        binding, role: role,
        required: ["id", "title", "status", "saved", "updatedAt", "hubAt", "deletedAt"],
        scopes: scopes, metadata: metadata)
      guard !binding.statuses.isEmpty else { throw BindingError.invalidStatusMapping(role) }
      // Every catalog option needs a consumption meaning, and nothing outside the catalog is offered.
      guard let statusColumn = binding.fields["status"],
        let options = metadata[binding.table]?.first(where: { $0.column == statusColumn })?.options,
        !options.isEmpty, Set(options) == Set(binding.statuses.keys)
      else { throw BindingError.invalidStatusMapping(role) }
    }
    for (role, binding) in sources {
      guard SourceKind(rawValue: role) != nil else { throw BindingError.invalidRole(role) }
      try validate(
        binding, role: role,
        required: ["id", "title", "follow", "feedSince", "updatedAt", "hubAt", "deletedAt"],
        scopes: scopes, metadata: metadata)
    }
  }
  private func validate(
    _ binding: RecordBinding, role: String, required: [String],
    scopes: Set<String>, metadata: [String: [PropertyMetadata]]
  ) throws {
    if binding.fields["duration"] != nil && binding.durationUnit == nil {
      throw BindingError.missingField(role, "durationUnit")
    }
    for field in required where binding.fields[field] == nil {
      throw BindingError.missingField(role, field)
    }
    guard binding.fields["id"] == "id" else { throw BindingError.unsupportedIdentity(role) }
    let text: Set<String> = ["text", "url"]
    let date: Set<String> = ["text", "date", "datetime", "date_or_datetime"]
    let allowed: [String: Set<String>] = [
      "id": text, "title": text, "status": ["select"], "saved": ["bool"], "follow": ["bool"],
      "updatedAt": date, "hubAt": date, "deletedAt": date, "feedSince": date,
      "release": date, "consumedAt": date, "duration": ["int", "number", "float"],
      "season": ["int"], "episode": ["int"], "isShort": ["bool"], "sourceID": text.union(["ref"]),
      "url": text, "imageURL": text, "tags": ["multi_select"], "note": text,
    ]
    for (field, column) in binding.fields {
      guard scopes.contains("tables:read:\(binding.table):\(column)"),
        scopes.contains("catalog:read:\(binding.table):\(column)")
      else {
        throw BindingError.insufficientScope(binding.table, column)
      }
      let candidates = metadata[binding.table, default: []].filter { $0.column == column }
      guard candidates.count == 1, let property = candidates.first,
        allowed[field]?.contains(property.type) == true
      else {
        throw BindingError.incompatibleType(binding.table, column)
      }
    }
  }
}
