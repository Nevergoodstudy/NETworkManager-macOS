import Foundation
import NMCore

enum FieldAcceptanceChecks {
    private static let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let firstPlan = "交付方案 A / Plan-A-private-fixture"
    private static let secondPlan = "交付方案 B / Plan-B-private-fixture"
    private static let revisedCriterion = "修订后 P95 时延不超过 80 / Revised-criterion-private-fixture"
    private static let legacyData = Data(#"{"schemaVersion":1,"customer":"虚构客户 / Customer-private-fixture","site":"虚构园区 / Site-private-fixture","projectScope":"Scope-private-fixture","checks":{"serviceBaseline":{"criterion":"原交付判据","evidence":"原验收手工记录","result":"met"}}}"#.utf8)

    static func run() throws {
        let legacy = try FieldProject.decode(legacyData)
        try check(legacy[.serviceBaseline].effectiveResult == .met && legacy.acceptanceRevisions.isEmpty,
                  "existing v1 notes survive without manufacturing structured acceptance history")

        var context = try makeDraft()
        let firstItem = context.acceptanceDraft.items[0]
        let secondItem = context.acceptanceDraft.items[1]
        let thirdItem = context.acceptanceDraft.items[2]
        let fourthItem = context.acceptanceDraft.items[3]
        let diagnostic = context[.serviceBaseline].attachedDiagnostics[0]
        try check(context.acceptanceResult(for: firstItem) == .pending,
                  "a complete item stays pending until the engineer records a result")

        var missingProof = context
        missingProof.acceptanceDraft.items[0].historicalCheck = nil
        try checkThrows("a pass based on history requires an attached diagnostic") {
            try missingProof.recordAcceptanceResult(.met, for: firstItem.id)
        }
        try check(missingProof.acceptanceResult(for: missingProof.acceptanceDraft.items[0]) == .pending,
                  "rejected pass does not alter the finding")

        var danglingLink = context
        danglingLink.acceptanceDraft.items[0].pointID = UUID()
        try checkThrows("acceptance rejects an item linked to an unknown measurement point") {
            try danglingLink.recordAcceptanceResult(.met, for: firstItem.id)
        }
        var missingBlockedReason = context
        missingBlockedReason.acceptanceDraft.items[1].blockedReason = " \n "
        try checkThrows("a blocked finding requires its reason") {
            try missingBlockedReason.recordAcceptanceResult(.blocked, for: secondItem.id)
        }

        var missingManualProof = context
        missingManualProof.acceptanceDraft.items[2].evidence = " \n "
        try checkThrows("an engineer-asserted failed finding requires evidence") {
            try missingManualProof.recordAcceptanceResult(.notMet, for: thirdItem.id)
        }

        try recordFirstFindings(in: &context)
        try check(context.acceptanceDraft.items.map { context.acceptanceResult(for: $0) } == [.met, .blocked, .notMet, .pending],
                  "positive, blocked, exception-backed failed, and pending findings remain separate")
        try check(context.acceptanceDraft.items[2].exception?.retestPlan == thirdItem.exception?.retestPlan,
                  "recording a failed finding retains its explicit exception and retest plan")
        var incompleteException = context
        incompleteException.acceptanceDraft.items[2].exception?.retestPlan = " \n "
        try checkThrows("a handoff revision refuses an exception without a retest plan") {
            try incompleteException.createAcceptanceRevision()
        }
        try check(incompleteException.acceptanceRevisions.isEmpty, "a rejected handoff leaves no partial revision")

        try context.createAcceptanceRevision()
        let firstRevision = context.acceptanceRevisions[0]
        let firstSnapshot = firstRevision.items[0]
        try check(firstRevision.number == 1 && firstRevision.planVersion == firstPlan &&
                  firstRevision.items.map(\.item.id) == [firstItem.id, secondItem.id, thirdItem.id, fourthItem.id] &&
                  firstRevision.items.map(\.result) == [.met, .blocked, .notMet, .pending],
                  "the first revision preserves all four traced findings in order")
        try check(firstSnapshot.item.kind == .acceptance &&
                  firstSnapshot.requirement == context.acceptanceDraft.requirements[0].title &&
                  firstSnapshot.point == context.acceptanceDraft.points[0].title &&
                  firstSnapshot.diagnostics.first?.runID == diagnostic.runID,
                  "the frozen entry captures the requirement, point, and historical diagnostic by value")

        var changedRequirement = context
        changedRequirement.acceptanceDraft.requirements[2].title += "（更正）"
        try check(changedRequirement.acceptanceResult(for: changedRequirement.acceptanceDraft.items[2]) == .pending &&
                  changedRequirement.acceptanceDraft.items[2].exception == nil &&
                  changedRequirement.acceptanceRevisions[0] == firstRevision,
                  "editing a linked requirement clears the draft finding and exception while preserving the revision")
        var changedPoint = context
        changedPoint.acceptanceDraft.points[0].title += "（更正）"
        try check(changedPoint.acceptanceResult(for: changedPoint.acceptanceDraft.items[0]) == .pending,
                  "editing a linked measurement point invalidates a draft result")
        var changedHistory = context
        var additionalDiagnostic = diagnostic
        additionalDiagnostic.runID = UUID()
        try check(changedHistory.attach(additionalDiagnostic, to: .serviceBaseline),
                  "attach another diagnostic to change the linked evidence while leaving the original available")
        try check(changedHistory.acceptanceResult(for: firstItem) == .pending &&
                  changedHistory.acceptanceRevisions[0].items[0].diagnostics.map(\.runID) == [diagnostic.runID],
                  "changing linked history invalidates the draft result and preserves the frozen evidence")
        try check(changedHistory.acceptanceResult(for: thirdItem) == .notMet &&
                  changedHistory.acceptanceDraft.items[2].exception == thirdItem.exception,
                  "the attachment edit preserves a manual finding and exception with a previously selected historical check")

        try finishSecondRevision(in: &context)
        try check(context.acceptanceRevisions.count == 2 && context.acceptanceRevisions[0] == firstRevision &&
                  context.acceptanceRevisions[1].number == 2 &&
                  context.acceptanceRevisions[1].planVersion == secondPlan &&
                  context.acceptanceRevisions[1].items[0].item.criterion == revisedCriterion,
                  "reopening acceptance under a revised plan creates a separate baseline")
        try check(context.maintenanceRevision?.id == firstRevision.id,
                  "maintenance can select the original baseline after a second revision exists")

        let encoded = try context.encoded()
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try check(json?["schemaVersion"] as? Int == 2, "structured acceptance uses the version-two file format")
        let reopened = try FieldProject.decode(encoded)
        try check(reopened == context && reopened.maintenanceRevision?.id == firstRevision.id &&
                  reopened[.serviceBaseline].effectiveResult == .met,
                  "saved acceptance revisions, draft, selected baseline, and original v1 notes survive reopen")
        try reportChecks(reopened, firstRevision: firstRevision, diagnostic: diagnostic)

        var fullHistory = reopened
        while fullHistory.acceptanceRevisions.count < FieldProject.maximumAcceptanceRevisions {
            try fullHistory.createAcceptanceRevision()
        }
        let lastRevision = fullHistory.acceptanceRevisions.last?.id
        try checkThrows("creating a handoff revision beyond the documented limit fails") {
            try fullHistory.createAcceptanceRevision()
        }
        try check(fullHistory.acceptanceRevisions.count == FieldProject.maximumAcceptanceRevisions &&
                  fullHistory.acceptanceRevisions.last?.id == lastRevision,
                  "a full history retains existing handoff revisions")
    }

    static func writeFixtures(to directory: URL) throws {
        var project = try makeDraft()
        try recordFirstFindings(in: &project)
        try project.createAcceptanceRevision()
        try finishSecondRevision(in: &project)
        try legacyData.write(to: directory.appendingPathComponent("acceptance-legacy-v1.nmfieldproject"), options: .withoutOverwriting)
        try project.encoded().write(to: directory.appendingPathComponent("acceptance-two-revisions-v2.nmfieldproject"), options: .withoutOverwriting)
    }

    private static func makeDraft() throws -> FieldProject {
        var project = try FieldProject.decode(legacyData)
        let requirements = [
            FieldRequirement(title: "业务时延 / Latency-private-fixture"),
            FieldRequirement(title: "备用接入 / Access-private-fixture"),
            FieldRequirement(title: "双栈解析 / DNS-private-fixture")
        ]
        let points = [
            FieldMeasurementPoint(title: "园区入口 / Uplink-private-fixture"),
            FieldMeasurementPoint(title: "办公区 / Office-private-fixture")
        ]
        let run = DiagnosticRun(
            kind: .tcp, status: .succeeded, startedAt: measuredAt,
            finishedAt: measuredAt.addingTimeInterval(0.04), summary: "token=raw-secret-fixture TCP-private-fixture",
            latency: 0.04, source: "Offline fixture", target: "192.0.2.44"
        )
        let item = DiagnosticEvidenceExporter.items(runs: [run], devices: [], useCurrentDeviceAddress: false)[0]
        let diagnostic = FieldProjectDiagnosticEvidence(item: item, networkContext: "VPN-private-fixture")
        try check(project.attach(diagnostic, to: .serviceBaseline), "attach fixture history to the service baseline")

        var latency = FieldAcceptanceItem(kind: .acceptance)
        latency.requirementID = requirements[0].id
        latency.pointID = points[0].id
        latency.criterion = "P95 时延不超过 100 / Criterion-private-fixture"
        latency.unit = "ms"
        latency.conditions = "客户 VPN 接入 / Conditions-private-fixture"
        latency.evidence = "10 次采样 / Evidence-private-fixture"
        latency.evidenceSource = .history
        latency.historicalCheck = .serviceBaseline
        latency.owner = "现场工程师 A / Owner-private-fixture"

        var access = FieldAcceptanceItem(kind: .acceptance)
        access.requirementID = requirements[1].id
        access.pointID = points[1].id
        access.criterion = "备用接入可用 / Access-criterion-private-fixture"
        access.unit = "状态"
        access.conditions = "客户启用备用端口 / Access-conditions-private-fixture"
        access.owner = "现场工程师 B / Access-owner-private-fixture"
        access.blockedReason = "端口尚未开通 / Blocked-private-fixture"

        var dns = FieldAcceptanceItem(kind: .acceptance)
        dns.requirementID = requirements[2].id
        dns.pointID = points[1].id
        dns.criterion = "IPv4 与 IPv6 均返回 / DNS-criterion-private-fixture"
        dns.unit = "状态"
        dns.conditions = "客户指定解析器 / DNS-conditions-private-fixture"
        dns.evidence = "仅有 A 记录 / DNS-evidence-private-fixture"
        dns.evidenceSource = .engineer
        dns.historicalCheck = .serviceBaseline // Retained when switching the row's evidence source to engineer notes.
        dns.owner = "现场工程师 C / DNS-owner-private-fixture"
        var exception = FieldAcceptanceException()
        exception.note = "等待 IPv6 变更窗口 / Exception-private-fixture"
        exception.confirmedBy = "客户代表 / Confirmer-private-fixture"
        exception.confirmedAt = measuredAt
        exception.retestPlan = "变更后从办公区复测 / Retest-private-fixture"
        dns.exception = exception

        var pendingPOC = FieldAcceptanceItem(kind: .poc)
        pendingPOC.requirementID = requirements[0].id
        pendingPOC.pointID = points[1].id
        pendingPOC.criterion = "办公区 P95 时延不超过 100 / POC-criterion-private-fixture"
        pendingPOC.unit = "ms"
        pendingPOC.conditions = "从办公区接入 / POC-conditions-private-fixture"
        pendingPOC.owner = "现场工程师 A / POC-owner-private-fixture"

        var draft = FieldAcceptanceDraft()
        draft.planVersion = firstPlan
        draft.requirements = requirements
        draft.points = points
        draft.items = [latency, access, dns, pendingPOC]
        project.acceptanceDraft = draft
        return project
    }

    private static func recordFirstFindings(in project: inout FieldProject) throws {
        let items = project.acceptanceDraft.items
        try project.recordAcceptanceResult(.met, for: items[0].id)
        try project.recordAcceptanceResult(.blocked, for: items[1].id)
        try project.recordAcceptanceResult(.notMet, for: items[2].id)
    }

    private static func finishSecondRevision(in project: inout FieldProject) throws {
        let firstRevision = project.acceptanceRevisions[0]
        project.acceptanceDraft.planVersion = secondPlan
        project.acceptanceDraft.items[0].criterion = revisedCriterion
        try check(project.acceptanceResult(for: project.acceptanceDraft.items[0]) == .pending,
                  "editing the plan and criterion requires a fresh explicit finding")
        project.acceptanceDraft.items[2].exception = firstRevision.items[2].item.exception
        try recordFirstFindings(in: &project)
        try project.createAcceptanceRevision()
        project.maintenanceRevisionID = firstRevision.id
    }

    private static func reportChecks(_ project: FieldProject, firstRevision: FieldAcceptanceRevision,
                                     diagnostic: FieldProjectDiagnosticEvidence) throws {
        let itemID = firstRevision.items[0].item.id
        let defaultReport = project.acceptanceReport(revisionID: firstRevision.id, selection: [:], translate: { $0 })
        try check(defaultReport.contains("Acceptance check — Criterion met") &&
                  defaultReport.contains("Acceptance check — Assessment blocked") &&
                  defaultReport.contains("Acceptance check — Criterion not met") &&
                  defaultReport.contains("Proof of concept — Not assessed") &&
                  defaultReport.contains("Attached diagnostic records: 1"),
                  "the default report shows distinct finding states and the attached count")
        for value in [firstPlan, secondPlan, "Customer-private-fixture", "Site-private-fixture", "Scope-private-fixture",
                      "Latency-private-fixture", "Uplink-private-fixture", "Criterion-private-fixture",
                      "Conditions-private-fixture", "Evidence-private-fixture", "Owner-private-fixture",
                      "Blocked-private-fixture", "Exception-private-fixture", "Retest-private-fixture",
                      "TCP-private-fixture", "VPN-private-fixture", "192.0.2.44", "40.0 ms", diagnostic.id.uuidString] {
            try check(!defaultReport.contains(value), "default acceptance report hides sensitive fixture field \(value)")
        }

        let explicitReport = project.acceptanceReport(
            revisionID: firstRevision.id, selection: [itemID: [.criterion, .diagnostics]], translate: { $0 }
        )
        try check(explicitReport.contains("Criterion-private-fixture") && explicitReport.contains("TCP-private-fixture") &&
                  explicitReport.contains("192.0.2.44") && explicitReport.contains("Latency: 40.0 ms") &&
                  !explicitReport.contains("raw-secret-fixture"),
                  "selecting criterion and diagnostics includes the frozen latency and applies credential redaction")
        try check(!explicitReport.contains(revisedCriterion) && !explicitReport.contains("Conditions-private-fixture") &&
                  !explicitReport.contains("Latency-private-fixture") && !explicitReport.contains("Uplink-private-fixture") &&
                  !explicitReport.contains("Owner-private-fixture") && !explicitReport.contains("Blocked-private-fixture") &&
                  !explicitReport.contains("Exception-private-fixture"),
                  "field-level selection neither leaks neighboring fields nor substitutes the new draft")
        let secondReport = project.acceptanceReport(
            revisionID: project.acceptanceRevisions[1].id, selection: [itemID: [.criterion]], translate: { $0 }
        )
        try check(secondReport.contains(revisedCriterion) && !secondReport.contains("Criterion-private-fixture") &&
                  !secondReport.contains("192.0.2.44") && !secondReport.contains("40.0 ms"),
                  "the second report uses only the selected revision and fields")
    }

    private static func checkThrows(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw CheckFailure(description: message)
    }
}
