import Foundation
import NMCore

enum FieldIncidentExportChecks {
    static func run() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let linkedRetestID = UUID()
        let earlier = FieldIncidentEntry(id: UUID(), kind: .reported,
                                         occurredAt: generatedAt.addingTimeInterval(-120),
                                         recordedAt: generatedAt.addingTimeInterval(-110),
                                         author: "username=owner-secret", detail: "password=observation-secret")
        let later = FieldIncidentEntry(id: UUID(), kind: .retested,
                                       occurredAt: generatedAt.addingTimeInterval(-60),
                                       recordedAt: generatedAt.addingTimeInterval(-50), author: "Engineer",
                                       detail: "Retest completed", retestRunID: linkedRetestID)
        let incident = FieldIncident(title: "# Outage | `edge`", owner: "Engineer",
                                      ticketReference: "token=ticket-secret", createdAt: generatedAt,
                                      asset: FieldIncidentAssetReference(device: AssetDevice(siteID: UUID(),
                                        name: "Gateway", address: "198.51.100.8",
                                        externalIdentity: ExternalAssetIdentity(
                                            instance: "https://inventory.example", objectType: "device", remoteID: "42"))),
                                      entries: [later, earlier])
        let linkedRetest = FieldRetestRecord(id: linkedRetestID, request: FieldRetestRequest(), status: .succeeded,
                                             startedAt: generatedAt.addingTimeInterval(-45), actualTarget: "https://user:pass@edge.example")
        let unlinkedRetest = FieldRetestRecord(request: FieldRetestRequest(), status: .failed,
                                               startedAt: generatedAt, actualTarget: "192.0.2.99")

        let jsonData = try FieldIncidentExporter.json(for: incident, retestRuns: [linkedRetest, unlinkedRetest], generatedAt: generatedAt)
        let json = String(decoding: jsonData, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        let caseRecord = object?["case"] as? [String: Any]
        let observations = object?["observations"] as? [[String: Any]]
        try check(Set(object?.keys.map { $0 } ?? []) == Set(["schemaVersion", "generatedAt", "case", "observations"]),
                  "JSON contains only the selected case, observations and export metadata")
        try check(caseRecord?["title"] as? String == incident.title && observations?.count == 2,
                  "JSON contains the selected case and its observations only")
        try check(observations?.first?["id"] as? String == earlier.id.uuidString,
                  "Observations export in chronological timeline order")
        try check(observations?.last?["retest"] != nil && !json.contains("192.0.2.99"),
                  "Only retests explicitly linked from the selected timeline are included")
        for secret in ["owner-secret", "observation-secret", "ticket-secret", "user:pass", "customer", "site", "projectScope"] {
            try check(!json.localizedCaseInsensitiveContains(secret), "JSON redacts credentials and excludes project-wide fields")
        }
        try check(!json.contains("sourceID") && !json.contains("/private/"), "JSON does not disclose local source paths")

        let markdown = FieldIncidentExporter.markdown(for: incident, retestRuns: [linkedRetest], generatedAt: generatedAt)
        try check(markdown.contains("\\# Outage \\| \\`edge\\`") && markdown.contains("password=\\[REDACTED\\]"),
                  "Markdown escapes dynamic structure characters and redacts credentials")
        try check(markdown.contains("198\\.51\\.100\\.8") && markdown.contains(t("Retest recorded")) && !markdown.contains("user:pass"),
                  "Markdown retains the device snapshot and linked retest summary while redacting URLs")
        try check(!markdown.contains("192.0.2.99"), "Markdown excludes unrelated project retests")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(description: message) }
    }
}
