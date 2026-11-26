import Foundation
@testable import NMCore

enum FieldInspectionChecks {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMInspection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"{"schemaVersion":1,"customer":"Legacy","site":"","projectScope":"","checks":{}}"#.utf8)
        var project = try FieldProject.decode(legacy)
        struct Schema: Decodable { let schemaVersion: Int }
        let oldBytes = try project.encoded()
        let oldSchema = try JSONDecoder().decode(Schema.self, from: oldBytes)
        try check(oldSchema.schemaVersion == 1, "Unused inspection fields do not upgrade a legacy project")
        var template = FieldInspectionTemplate(title: "Inspection-private", items: [
            FieldInspectionTemplateItem(title: "Link-private", target: "10.20.30.40", criterion: "No link errors")
        ])
        try project.saveInspectionTemplate(template)
        var first = try project.makeInspectionRecord(from: template.id, owner: "Engineer-private")
        first.items[0].result = .met
        try check(first.items[0].effectiveResult == .pending, "Missing evidence cannot pass")
        first.items[0].result = .blocked
        try check(first.items[0].effectiveResult == .pending, "Blocked requires a recorded reason")
        first.items[0].result = .notMet
        first.items[0].evidence = "Error counter 12; token=fixture-secret"
        first.items[0].followUpOwner = "Repair-private"
        first.items[0].dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        try project.saveInspectionRecord(first)
        let original = project.inspectionRecords[0]
        template.version = "2"
        template.items[0].criterion = "Updated criterion"
        try project.saveInspectionTemplate(template)
        var second = try project.makeInspectionRecord(from: template.id, owner: "Next-private")
        second.items[0].evidence = "Observed counters unchanged"
        second.items[0].result = .met
        try project.saveInspectionRecord(second)
        try check(first.id != second.id && project.inspectionRecords[0] == original &&
                  second.templateVersion == "2" && second.items[0].criterion == "Updated criterion",
                  "A new inspection copies the latest template without rewriting the older snapshot")
        let url = directory.appendingPathComponent("inspection.nmfieldproject")
        try project.encoded().write(to: url, options: .atomic)
        let reopened = try FieldProject.decode(Data(contentsOf: url))
        let bytes = try Data(contentsOf: url)
        let schema = try JSONDecoder().decode(Schema.self, from: bytes)
        try check(schema.schemaVersion == 6 && reopened == project, "Schema 6 preserves records, owners and deadlines on disk")
        let summary = reopened.report(includeDetails: false, translate: { $0 })
        for marker in ["Inspection-private", "Link-private", "10.20.30.40", "Engineer-private", "Repair-private", "fixture-secret"] {
            try check(!summary.contains(marker), "Default reports exclude editable inspection fields")
        }
        let detailed = reopened.report(includeDetails: true, translate: { $0 })
        try check(detailed.contains("No link errors") && detailed.contains("Repair-private") &&
                  detailed.contains("Remediation due") && !detailed.contains("fixture-secret"),
                  "Detailed reports retain the original criterion and follow-up, redacting recognizable credentials")
        var invalid = first
        invalid.owner = ""
        do {
            try project.saveInspectionRecord(invalid)
            throw CheckFailure(description: "Missing inspection owner was accepted")
        } catch FieldInspectionError.invalidRecord {}
        try check(project == reopened, "Rejected edits do not alter the document")
        var tooManyItems = template
        tooManyItems.items = (0...FieldInspectionTemplate.maximumItems).map {
            FieldInspectionTemplateItem(title: "Item \($0)")
        }
        do {
            try project.saveInspectionTemplate(tooManyItems)
            throw CheckFailure(description: "An oversized template was accepted")
        } catch FieldInspectionError.invalidTemplate {}
        let downgraded = Data(String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: #""schemaVersion" : 6"#, with: #""schemaVersion" : 5"#).utf8)
        do {
            _ = try FieldProject.decode(downgraded)
            throw CheckFailure(description: "Schema 5 accepted inspection fields")
        } catch FieldInspectionError.invalidRecord {}
    }
}
