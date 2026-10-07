import Foundation
import Testing

@testable import MediaKit

private func recordBinding(unit: DurationUnit? = .seconds) -> RecordBinding {
  .init(
    table: "clips",
    fields: [
      "id": "id", "title": "heading", "status": "state", "saved": "kept", "updatedAt": "updated_at",
      "hubAt": "hub_at", "deletedAt": "deleted_at", "sourceID": "parent", "release": "published",
      "duration": "length", "url": "link",
    ], statuses: ["Unseen": .notStarted, "Done": .finished], durationUnit: unit)
}
private var recordRow: CoreRow {
  [
    "id": .string("42"), "heading": .string("Example"), "state": .string("Unseen"),
    "kept": .number(0), "updated_at": .string("2026-01-01T00:00:00.000Z"), "hub_at": .null,
    "deleted_at": .null, "parent": .string("source"), "published": .string("2026-01-01"),
    "length": .number(120), "link": .string("https://example.test/item"),
  ]
}
@Test func runtimeFieldNamesUnitsAndReleasePrecisionArePreserved() throws {
  let record = try MediaRecord(kind: .youtubeVideo, row: recordRow, binding: recordBinding())
  #expect(record.item.durationMinutes == 2)
  #expect(record.item.release == .day(year: 2026, month: 1, day: 1))
  #expect(record.item.saved == false)
  #expect(record.item.source == .init(kind: .youtubeChannel, id: "source"))
  #expect(record.revision.hubAt == nil)
  #expect(
    try MediaRecord(kind: .youtubeVideo, row: recordRow, binding: recordBinding(unit: .minutes))
      .item.durationMinutes == 120)
  #expect(throws: (any Error).self) {
    try MediaRecord(kind: .youtubeVideo, row: recordRow, binding: recordBinding(unit: nil))
  }
}
@Test func malformedRowsDoNotInventSavedOrCompletedState() throws {
  for (key, value) in [
    ("kept", CoreJSONValue.string("true")), ("state", .string("unknown")),
    ("published", .string("2026-02-31")), ("length", .number(-1)),
  ] {
    var row = recordRow
    row[key] = value
    #expect(throws: (any Error).self) {
      try MediaRecord(kind: .youtubeVideo, row: row, binding: recordBinding())
    }
  }
  var row = recordRow
  row["link"] = .string("file:///private/item")
  #expect(try MediaRecord(kind: .youtubeVideo, row: row, binding: recordBinding()).item.url == nil)
  row["published"] = .null
  #expect(
    try MediaRecord(kind: .youtubeVideo, row: row, binding: recordBinding()).item.release == nil)
}
@Test func referenceMetadataAndExplicitDurationUnitValidate() throws {
  let binding = recordBinding()
  let scopes = Set(
    binding.fields.values.flatMap { ["tables:read:clips:\($0)", "catalog:read:clips:\($0)"] })
  let metadata = binding.fields.map { role, column in
    PropertyMetadata(
      column: column,
      type: role == "sourceID"
        ? "ref"
        : role == "duration"
          ? "int" : role == "saved" ? "bool" : role == "status" ? "select" : "text", readOnly: true)
  }
  try MediaBindings(items: ["youtubeVideo": binding], sources: [:]).validate(
    scopes: scopes, metadata: ["clips": metadata])
}
