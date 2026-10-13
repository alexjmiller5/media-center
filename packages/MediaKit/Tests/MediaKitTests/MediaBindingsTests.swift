import Foundation
import Testing

@testable import MediaKit

@Test func statusLabelsAreRuntimeMappingsNotCompiledPersonalVocabulary() throws {
  let binding = RecordBinding(
    table: "items",
    fields: [
      "id": "key", "title": "label", "status": "progress", "saved": "queue",
      "updatedAt": "updated_at", "hubAt": "hub_at", "deletedAt": "deleted_at",
    ], statuses: ["Later": .priority, "Done": .finished])
  #expect(binding.state(for: "Later") == .priority)
  #expect(binding.state(for: "Done") == .finished)
  #expect(binding.state(for: "unexpected") == nil)
  let item = MediaItem(
    identity: .init(kind: .article, id: "one"), title: "Article", status: "Later", state: .priority)
  #expect(reasons(item) == [.priority])
}

@Test func runtimeBindingsRequireExactReadGrantsCompatibleFieldsAndRevisionIdentity() throws {
  let fields = [
    "id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at",
    "hubAt": "hub_at", "deletedAt": "deleted_at",
  ]
  var bindings = MediaBindings(
    items: [
      "article": RecordBinding(
        table: "items", fields: fields, statuses: ["Open": .notStarted, "Done": .finished])
    ], sources: [:])
  let properties = fields.values.map { column in
    PropertyMetadata(
      column: column, type: column == "saved" ? "bool" : column == "status" ? "select" : "text",
      readOnly: false, options: column == "status" ? ["Open", "Done"] : nil)
  }
  let scopes = Set(
    fields.values.flatMap { ["tables:read:items:\($0)", "catalog:read:items:\($0)"] })
  try bindings.validate(scopes: scopes, metadata: ["items": properties])
  #expect(bindings.items["movie"] == nil)
  #expect(throws: BindingError.insufficientScope("items", "hub_at")) {
    try bindings.validate(
      scopes: scopes.subtracting(["tables:read:items:hub_at"]), metadata: ["items": properties])
  }
  var badProperties = properties
  badProperties[badProperties.firstIndex(where: { $0.column == "saved" })!].type = "text"
  #expect(throws: BindingError.incompatibleType("items", "saved")) {
    try bindings.validate(scopes: scopes, metadata: ["items": badProperties])
  }
  bindings.items["article"]?.fields.removeValue(forKey: "updatedAt")
  #expect(throws: BindingError.missingField("article", "updatedAt")) {
    try bindings.validate(scopes: scopes, metadata: ["items": properties])
  }
}

@Test func statusMappingsMustExactlyMatchTheCatalogOptions() throws {
  let fields = [
    "id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at",
    "hubAt": "hub_at", "deletedAt": "deleted_at",
  ]
  let scopes = Set(
    fields.values.flatMap { ["tables:read:items:\($0)", "catalog:read:items:\($0)"] })
  func metadata(_ options: [String]?) -> [String: [PropertyMetadata]] {
    ["items": fields.values.map { column in
      PropertyMetadata(
        column: column, type: column == "saved" ? "bool" : column == "status" ? "select" : "text",
        readOnly: false, options: column == "status" ? options : nil)
    }]
  }
  let bindings = MediaBindings(
    items: ["article": RecordBinding(table: "items", fields: fields, statuses: ["Open": .notStarted, "Done": .finished])],
    sources: [:])
  try bindings.validate(scopes: scopes, metadata: metadata(["Done", "Open"]))
  for invalid in [nil, [], ["Open"], ["Open", "Done", "Archived"], ["Open", "Finished"]] as [[String]?] {
    #expect(throws: BindingError.invalidStatusMapping("article")) {
      try bindings.validate(scopes: scopes, metadata: metadata(invalid))
    }
  }
}

private let itemFields = [
  "id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at",
  "hubAt": "hub_at", "deletedAt": "deleted_at",
]
private func readScopes(_ columns: some Sequence<String>) -> Set<String> {
  Set(columns.flatMap { ["tables:read:items:\($0)", "catalog:read:items:\($0)"] })
}
private func itemMetadata(extra: [String: String] = [:]) -> [String: [PropertyMetadata]] {
  ["items": itemFields.values.map { column in
    PropertyMetadata(
      column: column, type: column == "saved" ? "bool" : column == "status" ? "select" : "text",
      readOnly: false, options: column == "status" ? ["Open", "Done"] : nil)
  } + extra.map { PropertyMetadata(column: $0.key, type: $0.value, readOnly: true) }]
}
private func itemBindings(_ extra: [String: String]) -> MediaBindings {
  MediaBindings(
    items: ["tvShow": RecordBinding(
      table: "items", fields: itemFields.merging(extra) { _, new in new },
      statuses: ["Open": .notStarted, "Done": .finished])],
    sources: [:])
}

@Test func seriesStatusIsAnOptionalTextRoleWithExactGrants() throws {
  let bindings = itemBindings(["seriesStatus": "production"])
  let scopes = readScopes(Array(itemFields.values) + ["production"])
  for type in ["text", "select"] {
    try bindings.validate(scopes: scopes, metadata: itemMetadata(extra: ["production": type]))
  }
  #expect(throws: BindingError.incompatibleType("items", "production")) {
    try bindings.validate(scopes: scopes, metadata: itemMetadata(extra: ["production": "int"]))
  }
  #expect(throws: BindingError.insufficientScope("items", "production")) {
    try bindings.validate(
      scopes: scopes.subtracting(["catalog:read:items:production"]),
      metadata: itemMetadata(extra: ["production": "text"]))
  }
  // Today's configuration does not bind it and keeps validating.
  try itemBindings([:]).validate(scopes: readScopes(itemFields.values), metadata: itemMetadata())
}

@Test func unknownRolesAreIgnoredWithoutWeakeningTheRolesInUse() throws {
  // A newer service configuration may bind a role this client does not read yet.
  let bindings = itemBindings(["futureRole": "future_column"])
  let scopes = readScopes(itemFields.values)
  try bindings.validate(scopes: scopes, metadata: itemMetadata())
  try bindings.validate(
    scopes: scopes.union(readScopes(["future_column"])),
    metadata: itemMetadata(extra: ["future_column": "json"]))
  #expect(throws: BindingError.insufficientScope("items", "hub_at")) {
    try bindings.validate(
      scopes: scopes.subtracting(["tables:read:items:hub_at"]), metadata: itemMetadata())
  }
  var wrongType = itemMetadata()
  wrongType["items"]![wrongType["items"]!.firstIndex { $0.column == "saved" }!].type = "text"
  #expect(throws: BindingError.incompatibleType("items", "saved")) {
    try bindings.validate(scopes: scopes, metadata: wrongType)
  }
  // An unknown role never stands in for a required one.
  var missing = bindings
  missing.items["tvShow"]?.fields.removeValue(forKey: "saved")
  missing.items["tvShow"]?.fields["futureSaved"] = "saved"
  #expect(throws: BindingError.missingField("tvShow", "saved")) {
    try missing.validate(scopes: scopes, metadata: itemMetadata())
  }
  #expect(throws: BindingError.invalidRole("book")) {
    try MediaBindings(items: ["book": bindings.items["tvShow"]!], sources: [:])
      .validate(scopes: scopes, metadata: itemMetadata())
  }
}
