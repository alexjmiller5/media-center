import Foundation
import Testing
@testable import MediaKit

@Test func statusLabelsAreRuntimeMappingsNotCompiledPersonalVocabulary() throws {
    let binding = RecordBinding(table: "items", fields: ["id": "key", "title": "label", "status": "progress", "saved": "queue", "updatedAt": "updated_at", "hubAt": "hub_at", "deletedAt": "deleted_at"], statuses: ["Later": .priority, "Done": .finished])
    #expect(binding.state(for: "Later") == .priority)
    #expect(binding.state(for: "Done") == .finished)
    #expect(binding.state(for: "unexpected") == nil)
    let item = MediaItem(identity: .init(kind: .article, id: "one"), title: "Article", status: "Later", state: .priority)
    #expect(reasons(item) == [.priority])
}

@Test func runtimeBindingsRequireExactReadGrantsCompatibleFieldsAndRevisionIdentity() throws {
    let fields = ["id": "id", "title": "title", "status": "status", "saved": "saved", "updatedAt": "updated_at", "hubAt": "hub_at", "deletedAt": "deleted_at"]
    var bindings = MediaBindings(items: ["article": RecordBinding(table: "items", fields: fields, statuses: ["Open": .notStarted, "Done": .finished])], sources: [:])
    let properties = fields.values.map { column in
        PropertyMetadata(column: column, type: column == "saved" ? "bool" : column == "status" ? "select" : "text", readOnly: false)
    }
    let scopes = Set(fields.values.flatMap { ["tables:read:items:\($0)", "catalog:read:items:\($0)"] })
    try bindings.validate(scopes: scopes, metadata: ["items": properties])
    #expect(bindings.items["movie"] == nil)
    #expect(throws: BindingError.insufficientScope("items", "hub_at")) {
        try bindings.validate(scopes: scopes.subtracting(["tables:read:items:hub_at"]), metadata: ["items": properties])
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
