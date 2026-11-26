import Foundation
import Darwin
import NMCore

enum FieldProjectChecks {
    static func run() throws {
        var project = FieldProject()
        let allChecks = FieldProjectPhase.allCases.flatMap(\.checks)
        try check(Set(allChecks).count == allChecks.count && Set(allChecks) == Set(FieldProjectCheck.allCases),
                  "field project templates cover each stable check once")
        try check(allChecks.allSatisfy { project[$0].effectiveResult == .pending },
                  "new field projects start unassessed")

        project.customer = "Cust-private-fixture"
        project.site = "Site-private-fixture"
        project.projectScope = "Scope-private-fixture"
        project[.serviceBaseline].result = .met
        project[.serviceBaseline].criterion = "Criterion-private-fixture"
        project[.serviceBaseline].evidence = " \n "
        try check(project[.serviceBaseline].effectiveResult == .pending,
                  "blank evidence cannot support an acceptance finding")
        project[.serviceBaseline].evidence = "Evidence-private-fixture"
        project[.incident].result = .blocked
        project[.retest].result = .notMet
        try check(project[.serviceBaseline].effectiveResult == .met && project[.incident].effectiveResult == .blocked &&
                  project[.retest].effectiveResult == .pending,
                  "acceptance, blocked, and unfinished findings remain distinct")

        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runID = UUID()
        let selectedRun = DiagnosticRun(
            id: runID,
            kind: .tcp,
            status: .succeeded,
            startedAt: measuredAt,
            finishedAt: measuredAt.addingTimeInterval(0.25),
            summary: "token=private-token Summary-private-fixture " + String(repeating: "x", count: 1_100),
            latency: 0.025,
            source: "TCP probe",
            target: "https://user:private-password@example.test:443"
        )
        let exportedRun = DiagnosticEvidenceExporter.items(runs: [selectedRun], devices: []).first!
        let attached = FieldProjectDiagnosticEvidence(
            item: exportedRun,
            networkContext: String(repeating: "VPN uplink ", count: 60)
        )
        try check(attached.summary.count == 1_000 && attached.networkContext.count == 500,
                  "attached summaries and engineer-entered network notes are bounded")
        try check(attached.summary.contains("[REDACTED]") && !attached.summary.contains("private-token") &&
                  !attached.target.contains("private-password"),
                  "field evidence is created from the existing redacted exporter output")
        try check(attached.addressFamily == .notRecorded,
                  "a hostname or URL does not inherit the current interface address family")

        let ipv4 = FieldProjectDiagnosticEvidence(item: exportedItem(target: "192.0.2.15"))
        let ipv6 = FieldProjectDiagnosticEvidence(item: exportedItem(target: "2001:db8::15"))
        let dualStackEvidence = DiagnosticRuntimeEvidence(tcpAttempts: [
            TCPProbeAttempt(address: "192.0.2.15", family: AF_INET, stage: .connect, elapsed: 0.01),
            TCPProbeAttempt(address: "2001:db8::15", family: AF_INET6, stage: .connect, elapsed: 0.02)
        ])
        let dualStack = FieldProjectDiagnosticEvidence(
            item: exportedItem(target: "service.example", evidence: dualStackEvidence)
        )
        try check(ipv4.addressFamily == .ipv4 && ipv6.addressFamily == .ipv6 &&
                  dualStack.addressFamily == .dualStack,
                  "address family reflects only the selected historical run evidence")

        let device = AssetDevice(siteID: UUID(), name: "Renumbered device", address: "192.0.2.99")
        let historicalRun = DiagnosticRun(deviceID: device.id, kind: .ping, status: .interrupted)
        let historicalItems = DiagnosticEvidenceExporter.items(runs: [historicalRun], devices: [device],
                                                               useCurrentDeviceAddress: false)
        try check(historicalItems.first?.address == "Unknown address" &&
                  historicalItems.first.map { FieldProjectDiagnosticEvidence(item: $0).addressFamily } == .notRecorded,
                  "a missing historical target is not populated from the current device address")

        var evidenceProject = FieldProject()
        try check(evidenceProject.attach(attached, to: .connectivity) &&
                  !evidenceProject.attach(attached, to: .connectivity),
                  "the same history run cannot be attached twice to one check")
        for index in 1..<10 {
            let item = FieldProjectDiagnosticEvidence(item: exportedItem(
                id: UUID(), target: "192.0.2.\(index)", summary: "Fixture \(index)"
            ))
            try check(evidenceProject.attach(item, to: .connectivity),
                      "evidence can be added up to the per-check limit")
        }
        let eleventh = FieldProjectDiagnosticEvidence(item: exportedItem(id: UUID(), target: "192.0.2.250"))
        try check(evidenceProject[.connectivity].attachedDiagnostics.count == 10 &&
                  !evidenceProject.attach(eleventh, to: .connectivity),
                  "the model rejects an eleventh diagnostic record even outside the UI")
        let running = DiagnosticRun(kind: .ping, target: "127.0.0.1")
        let runningItem = DiagnosticEvidenceExporter.items(runs: [running], devices: [])[0]
        try check(!evidenceProject.attach(FieldProjectDiagnosticEvidence(item: runningItem), to: .incident),
                  "running records cannot be attached even outside the picker")
        try check(evidenceProject.attach(ipv4, to: .incident) && evidenceProject.attach(attached, to: .retest),
                  "a selected diagnostic snapshot can be reused on a separate check when relevant")

        var nearlyFullProject = FieldProject()
        let emptyProjectSize = try nearlyFullProject.encoded().count
        nearlyFullProject.projectScope = String(repeating: "x", count: FieldProject.fileSizeLimit - emptyProjectSize - 64)
        let beforeAttachment = try nearlyFullProject.encoded()
        try check(!nearlyFullProject.attach(attached, to: .connectivity),
                  "attachment rejects a project that would exceed the file size limit")
        var attachmentError: String?
        do {
            try nearlyFullProject.attachDiagnostic(attached, to: .connectivity)
        } catch {
            attachmentError = error.localizedDescription
        }
        try check(attachmentError == t("The field project exceeds the 512 KB limit."),
                  "over-limit attachment reports the document size error to the picker")
        let afterAttachment = try nearlyFullProject.encoded()
        try check(afterAttachment == beforeAttachment && nearlyFullProject[.connectivity].attachedDiagnostics.isEmpty,
                  "rejected attachment preserves the saveable project")

        let savedData = try project.encoded()
        let reopened = try FieldProject.decode(savedData)
        try check(reopened == project, "field project survives save and reopen across phases")
        let summary = reopened.report(includeDetails: false, translate: { $0 })
        let full = reopened.report(includeDetails: true, translate: { $0 })
        for value in [project.customer, project.site, project.projectScope, project[.serviceBaseline].criterion,
                      project[.serviceBaseline].evidence] {
            try check(!summary.contains(value) && full.contains(value),
                      "summary omits entered text and full preview includes it")
        }
        try check(summary.contains("Service performance baseline — Criterion met") &&
                  summary.contains("Incident impact and timeline — Assessment blocked") &&
                  summary.contains("Remediation and retest — Not assessed"),
                  "report uses supported findings instead of raw UI selection")

        evidenceProject[.connectivity].criterion = "Connectivity-private-fixture"
        evidenceProject[.connectivity].evidence = "Evidence-private-fixture"
        let evidenceRoundTrip = try FieldProject.decode(evidenceProject.encoded())
        try check(evidenceRoundTrip == evidenceProject &&
                  evidenceRoundTrip[.connectivity].attachedDiagnostics.first?.runID == runID,
                  "attached diagnostic snapshots survive save and reopen independent of their source run")
        let evidenceSummary = evidenceRoundTrip.report(includeDetails: false, translate: { $0 })
        let evidenceFull = evidenceRoundTrip.report(includeDetails: true, translate: { $0 })
        try check(evidenceSummary.contains("Attached diagnostic records: 10") &&
                  !evidenceSummary.contains("192.0.2.") && !evidenceSummary.contains("private-token") &&
                  !evidenceSummary.contains("VPN uplink") && !evidenceSummary.contains("TCP probe") &&
                  !evidenceSummary.contains("Summary-private-fixture") && !evidenceSummary.contains(runID.uuidString),
                  "default report reveals only the number of attached records")
        try check(evidenceFull.contains("192.0.2.15") && evidenceFull.contains("TCP probe") &&
                  evidenceFull.contains("Address family: IPv4") && evidenceFull.contains("Context note (added when attaching)") &&
                  evidenceFull.contains("Not recorded") && evidenceFull.contains("VPN uplink") &&
                  evidenceFull.contains("Measured at: \(ISO8601DateFormatter().string(from: measuredAt))") &&
                  !evidenceFull.contains("private-token") && !evidenceFull.contains("private-password"),
                  "explicit detail report includes measurement source, address-family, and the unrecorded-context state")

        evidenceProject.removeDiagnosticEvidence(id: runID, from: .connectivity)
        try check(evidenceProject[.connectivity].attachedDiagnostics.count == 9 &&
                  evidenceProject[.retest].attachedDiagnostics.first?.id == runID &&
                  evidenceProject.attach(eleventh, to: .connectivity),
                  "removal only affects the chosen check and frees an attachment slot")

        let legacyData = Data(#"{"schemaVersion":1,"customer":"Legacy customer","site":"Legacy site","projectScope":"Legacy scope","checks":{"serviceBaseline":{"criterion":"Latency under 80 ms","evidence":"Measured on site","result":"met"}}}"#.utf8)
        let legacyProject = try FieldProject.decode(legacyData)
        let legacyReopened = try FieldProject.decode(legacyProject.encoded())
        try check(legacyProject[.serviceBaseline].attachedDiagnostics.isEmpty &&
                  legacyProject.customer == "Legacy customer" &&
                  legacyReopened == legacyProject,
                  "version-one field projects without diagnostic snapshots remain readable and writable")

        var unsupported = try JSONSerialization.jsonObject(with: savedData) as? [String: Any] ?? [:]
        unsupported["schemaVersion"] = Int.max
        let unsupportedData = try JSONSerialization.data(withJSONObject: unsupported)
        let invalidProjects: [(Data, String)] = [
            (unsupportedData, "This field project uses an unsupported format version."),
            (Data("{}".utf8), "The field project is damaged or has an invalid format."),
            (Data("{damaged".utf8), "The field project is damaged or has an invalid format."),
            (Data(repeating: 0x20, count: 512 * 1024 + 1), "The field project exceeds the 512 KB limit.")
        ]
        for (invalidData, expectedReason) in invalidProjects {
            var actualReason: String?
            do {
                _ = try FieldProject.decode(invalidData)
            } catch {
                actualReason = error.localizedDescription
            }
            try check(actualReason == t(expectedReason),
                      "invalid project preserves its specific user-facing failure reason")
        }
    }

    private static func exportedItem(
        id: UUID = UUID(),
        target: String,
        summary: String = "",
        evidence: DiagnosticRuntimeEvidence? = nil
    ) -> DiagnosticEvidenceItem {
        let run = DiagnosticRun(
            id: id,
            kind: .tcp,
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: summary,
            source: "TCP probe",
            target: target,
            evidence: evidence
        )
        return DiagnosticEvidenceExporter.items(runs: [run], devices: []).first!
    }
}
