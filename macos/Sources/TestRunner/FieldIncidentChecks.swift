import Foundation
import NMCore

enum FieldIncidentChecks {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() throws {
        var project = try baselineProject()
        let revisionID = project.acceptanceRevisions[0].id
        let identity = ExternalAssetIdentity(instance: "https://inventory.example", objectType: "dcim.device", remoteID: "42")
        var device = AssetDevice(siteID: UUID(), name: "Asset-private", address: "192.0.2.44", externalIdentity: identity)
        let first = FieldIncident(title: "Incident-private", owner: "Owner-private", ticketReference: "TICKET-private",
                                  baselineRevisionID: revisionID, asset: FieldIncidentAssetReference(device: device))
        let second = FieldIncident(title: "Second incident", owner: "Second owner", baselineRevisionID: revisionID)
        try project.saveIncident(first)
        try project.saveIncident(second)
        let later = FieldIncidentEntry(kind: .responded, occurredAt: now, recordedAt: now,
                                       author: "Author-private", detail: "Note-private token=secret-fixture")
        let earlier = FieldIncidentEntry(kind: .reported, occurredAt: now.addingTimeInterval(-60),
                                         recordedAt: now.addingTimeInterval(10), author: "Author-private", detail: "Earlier note")
        try project.appendIncidentEntry(later, to: first.id)
        try project.appendIncidentEntry(earlier, to: first.id)
        try check(project.incidents[0].timeline.map(\.id) == [earlier.id, later.id] && project.incidents[1].entries.isEmpty,
                  "backfilled entries sort by occurrence and do not bleed into another incident")
        device.address = "2001:db8::44"
        try check(project.incidents[0].asset?.address == "192.0.2.44" && project.incidents[0].asset?.externalIdentity == identity,
                  "incident asset snapshots retain their original address and external identity")
        let run = retest(baseline: revisionID)
        try check(project.attachRetestRun(run) == .attached, "v4 projects still attach completed retests")
        let linked = FieldIncidentEntry(kind: .retested, occurredAt: now, author: "Author-private", detail: "Reviewed retest",
                                        retestRunID: run.id)
        try project.appendIncidentEntry(linked, to: first.id)
        let reopened = try FieldProject.decode(project.encoded())
        try check(reopened == project && reopened.incidents.count == 2 && reopened.retestRuns == [run],
                  "v4 round trip preserves incidents, snapshots, timestamps and retest references")
        let summary = project.report(includeDetails: false, translate: { $0 })
        let details = project.report(includeDetails: true, translate: { $0 })
        for value in ["Customer-private", "TICKET-private", "Incident-private", "Owner-private", "Asset-private", "192.0.2.44", "Author-private", "Note-private"] {
            try check(!summary.contains(value) && details.contains(value), "incident report hides \(value) until details are selected")
        }
        try check(!details.contains("secret-fixture") && details.contains("[REDACTED]"),
                  "incident report details redact known credential forms")
        var invalid = first
        invalid.baselineRevisionID = UUID()
        try rejects { try project.saveIncident(invalid) }
        invalid = second
        invalid.baselineRevisionID = project.acceptanceRevisions[1].id
        invalid.entries = [linked]
        try rejects { try project.saveIncident(invalid) }
        var wrongKind = linked
        wrongKind.kind = .note
        try rejects { try project.appendIncidentEntry(wrongKind, to: second.id) }
        try rejects { try project.appendIncidentEntry(later, to: first.id) }
        try rejects { try project.appendIncidentEntry(later, to: UUID()) }
        try check(project == reopened, "invalid incident mutations leave the project unchanged")
        project.removeRetestRun(id: run.id)
        let afterRemoval = try FieldProject.decode(project.encoded())
        try check(afterRemoval.incidents[0].entries.count == 3 && afterRemoval.incidents[0].entries.allSatisfy { $0.retestRunID == nil },
                  "removing retest evidence clears only its link and preserves manual timeline entries")
        try compatibilityAndLimits()
    }

    private static func compatibilityAndLimits() throws {
        let legacy = Data(#"{"schemaVersion":1,"customer":"Legacy","site":"","projectScope":"","checks":{}}"#.utf8)
        let v1 = try FieldProject.decode(legacy)
        let v2 = try baselineProject()
        var v3 = v2
        try check(v3.attachRetestRun(retest(baseline: v2.acceptanceRevisions[0].id)) == .attached, "v3 fixture attaches")
        for original in [v1, v2, v3] {
            let reopened = try FieldProject.decode(original.encoded())
            try check(reopened.incidents.isEmpty && reopened == original, "v1-v3 documents reopen without invented incidents")
        }
        var full = v1
        for number in 0..<FieldProject.maximumIncidents {
            try full.saveIncident(FieldIncident(title: "Incident \(number)", owner: "Fixture"))
        }
        try rejects { try full.saveIncident(FieldIncident(title: "Excess", owner: "Fixture")) }
        let fullBefore = full
        var incident = full.incidents[0]
        incident.title = " "
        try rejects { try full.saveIncident(incident) }
        incident = full.incidents[0]
        incident.entries = (0..<FieldIncident.maximumEntries).map {
            FieldIncidentEntry(kind: .note, author: "Fixture", detail: "Entry \($0)")
        }
        try full.saveIncident(incident)
        try rejects { try full.appendIncidentEntry(FieldIncidentEntry(kind: .note, author: "Fixture", detail: "Excess"), to: incident.id) }
        try check(full.incidents.count == fullBefore.incidents.count && full.incidents[0].title == fullBefore.incidents[0].title,
                  "limits and missing fields do not replace valid metadata")
        var json = try JSONSerialization.jsonObject(with: full.encoded()) as! [String: Any]
        json["schemaVersion"] = 3
        let downgraded = try JSONSerialization.data(withJSONObject: json)
        try rejects { _ = try FieldProject.decode(downgraded) }
    }

    private static func baselineProject() throws -> FieldProject {
        var project = FieldProject()
        project.customer = "Customer-private"
        var draft = project.acceptanceDraft
        draft.planVersion = "Plan A"
        draft.items = [FieldAcceptanceItem(kind: .acceptance)]
        project.acceptanceDraft = draft
        try project.createAcceptanceRevision()
        project.acceptanceDraft.planVersion = "Plan B"
        try project.createAcceptanceRevision()
        return project
    }

    private static func retest(baseline: UUID) -> FieldRetestRecord {
        let request = FieldRetestRequest(
            baselineRevisionID: baseline, target: "service.example", method: .systemDNS,
            authorization: FieldRetestAuthorization(reference: "CHG-fixture", confirmedBy: "Fixture",
                confirmedAt: now.addingTimeInterval(-5), windowStart: now.addingTimeInterval(-60),
                windowEnd: now.addingTimeInterval(60), confirmed: true), networkContext: "Fixture context"
        )
        return FieldRetestRecord(request: request, status: .succeeded, startedAt: now,
                                 finishedAt: now.addingTimeInterval(0.2), actualTarget: "127.0.0.1",
                                 addressFamily: .ipv4, dnsMode: .system, summary: "Resolved", executedLayers: [.dns])
    }

    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw CheckFailure(description: "Expected incident validation to reject the operation")
    }
}
