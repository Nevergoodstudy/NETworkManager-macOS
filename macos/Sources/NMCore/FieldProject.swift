import Foundation
import Darwin

public enum FieldProjectPhase: String, CaseIterable, Hashable, Sendable {
    case survey, acceptance, maintenance

    public var title: String {
        switch self {
        case .survey: return "Presales survey"
        case .acceptance: return "Delivery acceptance"
        case .maintenance: return "After-sales maintenance"
        }
    }

    public var checks: [FieldProjectCheck] {
        switch self {
        case .survey: return [.scope, .currentNetwork, .designRisks]
        case .acceptance: return [.connectivity, .serviceBaseline, .handoff]
        case .maintenance: return [.incident, .baselineComparison, .retest]
        }
    }
}

public enum FieldProjectCheck: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case scope, currentNetwork, designRisks, connectivity, serviceBaseline, handoff
    case incident, baselineComparison, retest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scope: return "Requirements and authorized scope"
        case .currentNetwork: return "Existing network and constraints"
        case .designRisks: return "Design assumptions and open risks"
        case .connectivity: return "Connectivity and network access"
        case .serviceBaseline: return "Service performance baseline"
        case .handoff: return "Exceptions and handoff confirmation"
        case .incident: return "Incident impact and timeline"
        case .baselineComparison: return "Comparison with delivery baseline"
        case .retest: return "Remediation and retest"
        }
    }
}

public enum FieldCheckResult: String, Codable, CaseIterable, Hashable, Sendable {
    case pending, met, notMet, blocked

    public var title: String {
        switch self {
        case .pending: return "Not assessed"
        case .met: return "Criterion met"
        case .notMet: return "Criterion not met"
        case .blocked: return "Assessment blocked"
        }
    }
}

public enum FieldProjectAddressFamily: String, Codable, Sendable {
    case ipv4, ipv6, dualStack, notRecorded

    public var title: String {
        switch self {
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .dualStack: return "Dual stack"
        case .notRecorded: return "Not recorded"
        }
    }
}

/// Compact snapshot of one selected history run. The source workspace may later change or be removed.
public struct FieldProjectDiagnosticEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { runID }
    public var runID: UUID
    public var device: String
    public var target: String
    public var kind: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var summary: String
    public var latency: TimeInterval?
    public var source: String
    public var addressFamily: FieldProjectAddressFamily
    /// Entered when the old run is attached; it was not automatically collected with the source run.
    public var networkContext: String

    public init(item: DiagnosticEvidenceItem, networkContext: String = "") {
        runID = item.id
        device = item.device
        target = item.address
        kind = item.kind
        status = item.status
        startedAt = item.startedAt
        finishedAt = item.finishedAt
        summary = String(item.summary.prefix(1_000))
        latency = item.latency
        source = item.source
        addressFamily = Self.addressFamily(target: item.address, evidence: item.evidence)
        self.networkContext = String(networkContext.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    private static func addressFamily(target: String, evidence: DiagnosticRuntimeEvidence?) -> FieldProjectAddressFamily {
        let observed = Set((evidence?.tcpAttempts ?? []).map(\.family).filter { $0 == AF_INET || $0 == AF_INET6 })
        if observed.contains(AF_INET), observed.contains(AF_INET6) { return .dualStack }
        if observed.contains(AF_INET) { return .ipv4 }
        if observed.contains(AF_INET6) { return .ipv6 }

        var literal = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        guard !literal.utf8.contains(0) else { return .notRecorded }
        var address4 = in_addr()
        if inet_pton(AF_INET, literal, &address4) == 1 { return .ipv4 }
        if let zone = literal.firstIndex(of: "%") { literal = String(literal[..<zone]) }
        var address6 = in6_addr()
        if inet_pton(AF_INET6, literal, &address6) == 1 { return .ipv6 }
        return .notRecorded
    }
}

public struct FieldCheckRecord: Codable, Equatable, Sendable {
    public var criterion = ""
    public var evidence = ""
    public var result: FieldCheckResult = .pending
    private var diagnosticEvidence: [FieldProjectDiagnosticEvidence]?

    public init() {}

    public var hasRequiredEvidence: Bool {
        [criterion, evidence].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var effectiveResult: FieldCheckResult {
        switch result {
        case .met, .notMet: return hasRequiredEvidence ? result : .pending
        case .pending, .blocked: return result
        }
    }

    public fileprivate(set) var attachedDiagnostics: [FieldProjectDiagnosticEvidence] {
        get { diagnosticEvidence ?? [] }
        set { diagnosticEvidence = newValue.isEmpty ? nil : newValue }
    }
}

public enum FieldProjectRetestAttachmentResult: Equatable, Sendable {
    case attached, duplicate, limitReached, invalidRecord, invalidBaseline, documentLimit
}

/// A portable, user-owned site record. Stable check IDs keep saved documents independent of UI language.
public struct FieldProject: Codable, Equatable, Sendable {
    private var schemaVersion = 1
    public var customer = ""
    public var site = ""
    public var projectScope = ""
    private var checks: [String: FieldCheckRecord] = [:]
    private var structuredAcceptance: FieldAcceptanceDraft?
    private var savedAcceptanceRevisions: [FieldAcceptanceRevision]?
    private var selectedAcceptanceRevisionID: UUID?
    private var savedRetestRuns: [FieldRetestRecord]?
    private var savedIncidents: [FieldIncident]?
    private var savedInspectionTemplates: [FieldInspectionTemplate]?
    private var savedInspectionRecords: [FieldInspectionRecord]?

    public init() {}

    public subscript(check: FieldProjectCheck) -> FieldCheckRecord {
        get { checks[check.rawValue] ?? FieldCheckRecord() }
        set {
            let diagnosticsChanged = self[check].attachedDiagnostics != newValue.attachedDiagnostics
            checks[check.rawValue] = newValue
            if diagnosticsChanged, var draft = structuredAcceptance {
                for index in draft.items.indices where draft.items[index].evidenceSource == .history &&
                    draft.items[index].historicalCheck == check {
                    draft.items[index].recordedResult = .pending
                    draft.items[index].exception = nil
                }
                structuredAcceptance = draft
            }
        }
    }

    @discardableResult
    public mutating func attach(_ evidence: FieldProjectDiagnosticEvidence, to check: FieldProjectCheck) -> Bool {
        (try? attachDiagnostic(evidence, to: check)) != nil
    }

    public mutating func attachDiagnostic(_ evidence: FieldProjectDiagnosticEvidence, to check: FieldProjectCheck) throws {
        var record = self[check]
        guard !record.attachedDiagnostics.contains(where: { $0.runID == evidence.runID }) else {
            throw FieldProjectError.duplicateDiagnosticEvidence
        }
        guard record.attachedDiagnostics.count < Self.maximumDiagnosticEvidencePerCheck else {
            throw FieldProjectError.diagnosticEvidenceLimit
        }
        guard Self.isValid(evidence) else { throw FieldProjectError.invalidDiagnosticEvidence }
        record.attachedDiagnostics.append(evidence)
        var updated = self
        updated[check] = record
        _ = try updated.encoded()
        self = updated
    }

    public mutating func removeDiagnosticEvidence(id: UUID, from check: FieldProjectCheck) {
        var record = self[check]
        record.attachedDiagnostics.removeAll { $0.id == id }
        self[check] = record
    }

    public static let fileSizeLimit = 512 * 1024
    public static let maximumDiagnosticEvidencePerCheck = 10
    public static let maximumRetestRuns = 30

    public var retestRuns: [FieldRetestRecord] { savedRetestRuns ?? [] }

    /// Records an explicit selection without changing the maintenance judgement or historical evidence.
    @discardableResult
    public mutating func attachRetestRun(_ run: FieldRetestRecord) -> FieldProjectRetestAttachmentResult {
        guard !retestRuns.contains(where: { $0.id == run.id }) else { return .duplicate }
        guard retestRuns.count < Self.maximumRetestRuns else { return .limitReached }
        guard validRetest(run) else { return .invalidRecord }
        guard validRetestBaseline(run.request) else { return .invalidBaseline }
        var updated = self
        updated.schemaVersion = max(updated.schemaVersion, run.request.method == .tls || run.request.method == .http ? 5 : 3)
        updated.savedRetestRuns = retestRuns + [run]
        guard (try? updated.encoded()) != nil else { return .documentLimit }
        self = updated
        return .attached
    }

    public mutating func removeRetestRun(id: UUID) {
        savedRetestRuns?.removeAll { $0.id == id }
        // Keep the manually recorded event, but remove the deleted evidence link.
        if var incidents = savedIncidents {
            for incidentIndex in incidents.indices {
                for entryIndex in incidents[incidentIndex].entries.indices
                    where incidents[incidentIndex].entries[entryIndex].retestRunID == id {
                    incidents[incidentIndex].entries[entryIndex].retestRunID = nil
                }
            }
            savedIncidents = incidents
        }
    }

    private func validRetest(_ run: FieldRetestRecord) -> Bool {
        run.request.check == .retest && run.finishedAt != nil &&
            run.status != .pending && run.status != .running && (try? run.validate()) != nil
    }

    private func validRetestBaseline(_ request: FieldRetestRequest) -> Bool {
        guard let revisionID = request.baselineRevisionID else {
            return request.acceptanceItemID == nil && request.baselineEvidenceID == nil
        }
        guard let revision = acceptanceRevisions.first(where: { $0.id == revisionID }) else { return false }
        guard let itemID = request.acceptanceItemID else { return request.baselineEvidenceID == nil }
        guard let item = revision.items.first(where: { $0.id == itemID }) else { return false }
        guard let evidenceID = request.baselineEvidenceID else { return true }
        return item.diagnostics.contains { $0.id == evidenceID }
    }

    private func validateRetests() throws {
        guard schemaVersion >= 5 || !retestRuns.contains(where: { $0.request.method == .tls || $0.request.method == .http }),
              schemaVersion >= 3 || savedRetestRuns == nil,
              retestRuns.count <= Self.maximumRetestRuns,
              Set(retestRuns.map(\.id)).count == retestRuns.count,
              retestRuns.allSatisfy({ validRetest($0) && validRetestBaseline($0.request) }) else {
            throw FieldRetestValidationError.invalidRecord
        }
    }

    private static func isValid(_ item: FieldProjectDiagnosticEvidence) -> Bool {
        guard let status = DiagnosticRunStatus(rawValue: item.status), status != .running else { return false }
        return item.summary.count <= 1_000 && item.networkContext.count <= 500
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= fileSizeLimit else { throw FieldProjectError.fileTooLarge }
        let project: Self
        do {
            project = try JSONDecoder().decode(Self.self, from: data)
        } catch is DecodingError {
            throw FieldProjectError.invalidFormat
        }
        guard (1...8).contains(project.schemaVersion) else {
            throw FieldProjectError.unsupportedVersion
        }
        guard project.checks.keys.allSatisfy({ FieldProjectCheck(rawValue: $0) != nil }) else {
            throw FieldProjectError.invalidCheck
        }
        guard project.checks.values.allSatisfy({ record in
            validEvidence(record.attachedDiagnostics)
        }) else {
            throw FieldProjectError.invalidDiagnosticEvidence
        }
        try project.validateAcceptance()
        try project.validateRetests()
        try project.validateIncidents()
        try project.validateInspections()
        return project
    }

    public func encoded() throws -> Data {
        try validateAcceptance()
        try validateRetests()
        try validateIncidents()
        try validateInspections()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.fileSizeLimit else { throw FieldProjectError.fileTooLarge }
        return data
    }

    /// Status-only output excludes every editable field. Full reports contain exactly the text shown in preview.
    public func report(includeDetails: Bool, translate: (String) -> String) -> String {
        var lines = [translate("Network field project report")]
        if includeDetails {
            lines += ["", "\(translate("Customer")): \(customer)", "\(translate("Site")): \(site)",
                      "\(translate("Project scope")): \(projectScope)"]
        }
        for phase in FieldProjectPhase.allCases {
            lines += ["", translate(phase.title)]
            for check in phase.checks {
                let record = self[check]
                lines.append("- \(translate(check.title)) — \(translate(record.effectiveResult.title))")
                if !record.attachedDiagnostics.isEmpty {
                    lines.append("  \(translate("Attached diagnostic records")): \(record.attachedDiagnostics.count)")
                }
                if includeDetails {
                    if !record.criterion.isEmpty { lines.append("  \(translate("Criterion")): \(record.criterion)") }
                    if !record.evidence.isEmpty { lines.append("  \(translate("Evidence and notes")): \(record.evidence)") }
                    for item in record.attachedDiagnostics {
                        lines.append("  \(translate("Diagnostic run")): \(item.runID.uuidString)")
                        lines.append("    \(translate("Measured at")): \(ISO8601DateFormatter().string(from: item.startedAt)) · \(translate("Source")): \(item.source)")
                        lines.append("    \(translate("Target")): \(item.device) · \(item.target) · \(item.kind) · \(item.status)")
                        lines.append("    \(translate("Address family")): \(translate(item.addressFamily.title))")
                        if let latency = item.latency {
                            lines.append("    \(translate("Latency")): \(String(format: "%.1f ms", latency * 1000))")
                        }
                        if !item.summary.isEmpty { lines.append("    \(translate("Summary")): \(item.summary)") }
                        let contextNote = item.networkContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? translate("Not recorded") : item.networkContext
                        lines.append("    \(translate("Context note (added when attaching)")): \(contextNote)")
                    }
                }
            }
        }
        if !retestRuns.isEmpty {
            lines += ["", "\(translate("Attached retest results")): \(retestRuns.count)"]
            if includeDetails {
                let formatter = ISO8601DateFormatter()
                for run in retestRuns {
                    lines.append("- \(translate(run.request.method.title)) — \(translate(run.status.title))")
                    lines.append("  \(translate("Authorization reference")): \(run.request.authorization.reference)")
                    lines.append("  \(translate("Confirmed by")): \(run.request.authorization.confirmedBy)")
                    lines.append("  \(translate("Window start")): \(formatter.string(from: run.request.authorization.windowStart))")
                    lines.append("  \(translate("Window end")): \(formatter.string(from: run.request.authorization.windowEnd))")
                    lines.append("  \(translate("Measured at")): \(formatter.string(from: run.startedAt))")
                    lines.append("  \(translate("Target")): \(run.request.normalizedTarget)")
                    if run.request.method == .http {
                        lines.append("  HTTP HEAD: \(run.request.httpScheme ?? "https") · \(run.request.tcpPort ?? 443) · \(run.request.httpPath ?? "/")")
                    }
                    lines.append("  \(translate("Actual target")): \(run.actualTarget)")
                    lines.append("  \(translate("Address family")): \(translate(run.addressFamily.title))")
                    if let dnsMode = run.dnsMode {
                        lines.append("  \(translate("DNS mode")): \(translate(dnsMode.title))")
                    }
                    if let resolver = run.resolver {
                        lines.append("  \(translate("Resolver")): \(resolver)")
                    }
                    lines.append("  \(translate("Current network conditions")): \(run.request.networkContext)")
                    lines.append("  \(translate("Approved baseline network conditions")): \(run.request.baselineNetworkContext)")
                    lines.append("  \(translate("Compared with baseline")): \(translate(run.comparisonState.title))")
                    if let reason = run.notComparableReason {
                        lines.append("  \(translate("Comparison note")): \(reason)")
                    }
                    if !run.observedPath.isEmpty {
                        lines.append("  \(translate("Observed path")): \(run.observedPath)")
                    }
                    if !run.summary.isEmpty { lines.append("  \(translate("Summary")): \(run.summary)") }
                    if !run.detail.isEmpty { lines.append("  \(translate("Diagnostic details")): \(run.detail)") }
                }
            }
        }
        if !incidents.isEmpty {
            lines += ["", "\(translate("Maintenance incidents")): \(incidents.count)"]
            for (index, incident) in incidents.enumerated() {
                lines.append("- #\(index + 1) — \(translate(incident.status.title)) · \(translate("Timeline entries")): \(incident.entries.count)")
                if includeDetails {
                    lines += incidentReportDetails(incident, translate: translate)
                }
            }
        }
        if !inspectionRecords.isEmpty {
            lines += ["", "\(translate("Inspection records")): \(inspectionRecords.count)"]
            for record in inspectionRecords {
                let assessed = record.items.filter { $0.effectiveResult != .pending }.count
                lines.append("- \(translate("Manual inspection")) · \(assessed)/\(record.items.count) · \(record.items.filter { $0.effectiveResult == .notMet }.count) \(translate("items need follow-up"))")
                if !includeDetails { continue }
                let formatter = ISO8601DateFormatter()
                lines.append("  \(translate("Inspection template")): \(DiagnosticEvidenceExporter.redact(record.templateTitle)) · \(DiagnosticEvidenceExporter.redact(record.templateVersion))")
                lines.append("  \(translate("Owner")): \(DiagnosticEvidenceExporter.redact(record.owner))")
                lines.append("  \(translate("Recorded at")): \(formatter.string(from: record.recordedAt))")
                for item in record.items {
                    lines.append("  - \(DiagnosticEvidenceExporter.redact(item.title)) — \(translate(item.effectiveResult.title))")
                    if !item.target.isEmpty { lines.append("    \(translate("Target")): \(DiagnosticEvidenceExporter.redact(item.target))") }
                    if !item.criterion.isEmpty { lines.append("    \(translate("Criterion")): \(DiagnosticEvidenceExporter.redact(item.criterion))") }
                    if !item.evidence.isEmpty { lines.append("    \(translate("Evidence and notes")): \(DiagnosticEvidenceExporter.redact(item.evidence))") }
                    if !item.followUpOwner.isEmpty { lines.append("    \(translate("Follow-up owner")): \(DiagnosticEvidenceExporter.redact(item.followUpOwner))") }
                    if let dueAt = item.dueAt { lines.append("    \(translate("Remediation due")): \(formatter.string(from: dueAt))") }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension FieldProject {
    public static let maximumInspectionTemplates = 20
    public static let maximumInspectionRecords = 30

    public var inspectionTemplates: [FieldInspectionTemplate] { savedInspectionTemplates ?? [] }
    public var inspectionRecords: [FieldInspectionRecord] { savedInspectionRecords ?? [] }

    public mutating func saveInspectionTemplate(_ template: FieldInspectionTemplate) throws {
        guard template.isValid else { throw FieldInspectionError.invalidTemplate }
        let values = inspectionTemplates.filter { $0.id != template.id } + [template]
        guard values.count <= Self.maximumInspectionTemplates else { throw FieldInspectionError.templateLimit }
        var updated = self
        updated.schemaVersion = max(schemaVersion, 6)
        updated.savedInspectionTemplates = values
        _ = try updated.encoded()
        self = updated
    }

    public func makeInspectionRecord(from templateID: UUID, owner: String) throws -> FieldInspectionRecord {
        guard let template = inspectionTemplates.first(where: { $0.id == templateID }) else {
            throw FieldInspectionError.missingTemplate
        }
        guard inspectionRecords.count < Self.maximumInspectionRecords else { throw FieldInspectionError.recordLimit }
        return FieldInspectionRecord(templateID: template.id, templateTitle: template.title,
                                     templateVersion: template.version, owner: owner,
                                     items: template.items.map(FieldInspectionRecordItem.init(templateItem:)))
    }

    public mutating func saveInspectionRecord(_ record: FieldInspectionRecord) throws {
        guard record.isValid else { throw FieldInspectionError.invalidRecord }
        guard inspectionTemplates.contains(where: { $0.id == record.templateID }) else {
            throw FieldInspectionError.missingTemplate
        }
        let values = inspectionRecords.filter { $0.id != record.id } + [record]
        guard values.count <= Self.maximumInspectionRecords else { throw FieldInspectionError.recordLimit }
        var updated = self
        updated.schemaVersion = max(schemaVersion, 6)
        updated.savedInspectionRecords = values
        _ = try updated.encoded()
        self = updated
    }

    private func validateInspections() throws {
        guard inspectionTemplates.count <= Self.maximumInspectionTemplates else { throw FieldInspectionError.templateLimit }
        guard inspectionRecords.count <= Self.maximumInspectionRecords else { throw FieldInspectionError.recordLimit }
        guard inspectionTemplates.allSatisfy(\.isValid) else { throw FieldInspectionError.invalidTemplate }
        guard schemaVersion >= 6 || (savedInspectionTemplates == nil && savedInspectionRecords == nil),
              Set(inspectionTemplates.map(\.id)).count == inspectionTemplates.count,
              Set(inspectionRecords.map(\.id)).count == inspectionRecords.count,
              inspectionRecords.allSatisfy(\.isValid),
              inspectionRecords.allSatisfy({ record in
                  inspectionTemplates.contains(where: { $0.id == record.templateID })
              }) else { throw FieldInspectionError.invalidRecord }
    }
}

extension FieldProject {
    public static let maximumIncidents = 20

    public var incidents: [FieldIncident] { savedIncidents ?? [] }

    /// Validate and stage the complete document before changing the caller's value.
    public mutating func saveIncident(_ incident: FieldIncident) throws {
        guard incident.isValid else { throw FieldIncidentError.invalidRecord }
        var values = incidents
        if let index = values.firstIndex(where: { $0.id == incident.id }) {
            values[index] = incident
        } else {
            guard values.count < Self.maximumIncidents else { throw FieldIncidentError.incidentLimit }
            values.append(incident)
        }
        var updated = self
        updated.schemaVersion = max(schemaVersion, 4)
        if incident.entries.contains(where: { $0.metricObservation != nil }) {
            updated.schemaVersion = max(updated.schemaVersion, 7)
        }
        if incident.entries.contains(where: { $0.packetCaptureSummary != nil }) {
            updated.schemaVersion = 8
        }
        updated.savedIncidents = values
        _ = try updated.encoded()
        self = updated
    }

    public mutating func appendIncidentEntry(_ entry: FieldIncidentEntry, to incidentID: UUID) throws {
        guard var incident = incidents.first(where: { $0.id == incidentID }) else {
            throw FieldIncidentError.missingIncident
        }
        guard incident.entries.count < FieldIncident.maximumEntries else { throw FieldIncidentError.entryLimit }
        incident.entries.append(entry)
        try saveIncident(incident)
    }

    public mutating func removePacketCaptureSummary(_ entryID: UUID, from incidentID: UUID) throws {
        guard var incident = incidents.first(where: { $0.id == incidentID }) else {
            throw FieldIncidentError.missingIncident
        }
        guard let index = incident.entries.firstIndex(where: { $0.id == entryID && $0.packetCaptureSummary != nil }) else { return }
        incident.entries.remove(at: index)
        try saveIncident(incident)
    }

    private func validateIncidents() throws {
        guard schemaVersion >= 4 || savedIncidents == nil,
              incidents.count <= Self.maximumIncidents,
              Set(incidents.map(\.id)).count == incidents.count,
              incidents.allSatisfy(\.isValid) else { throw FieldIncidentError.invalidRecord }
        for incident in incidents {
            guard schemaVersion >= 7 || !incident.entries.contains(where: { $0.metricObservation != nil }),
                  schemaVersion >= 8 || !incident.entries.contains(where: { $0.packetCaptureSummary != nil }) else {
                throw FieldIncidentError.invalidRecord
            }
            if let revisionID = incident.baselineRevisionID,
               !acceptanceRevisions.contains(where: { $0.id == revisionID }) {
                throw FieldIncidentError.invalidReference
            }
            for entry in incident.entries {
                guard let runID = entry.retestRunID else { continue }
                guard let run = retestRuns.first(where: { $0.id == runID }),
                      run.request.baselineRevisionID == incident.baselineRevisionID else {
                    throw FieldIncidentError.invalidReference
                }
            }
        }
    }

    private func incidentReportDetails(_ incident: FieldIncident, translate: (String) -> String) -> [String] {
        let formatter = ISO8601DateFormatter()
        func field(_ key: String, _ value: String) -> String {
            "  \(translate(key)): \(DiagnosticEvidenceExporter.redact(value))"
        }
        var lines = [field("Incident title", incident.title), field("Owner", incident.owner)]
        if !incident.ticketReference.isEmpty { lines.append(field("External ticket reference", incident.ticketReference)) }
        if let revision = acceptanceRevisions.first(where: { $0.id == incident.baselineRevisionID }) {
            lines.append(field("Handoff revision", "#\(revision.number) · \(revision.planVersion)"))
        }
        if let asset = incident.asset {
            lines.append(field("Associated asset snapshot", "\(asset.name) · \(asset.address)"))
            if let identity = asset.externalIdentity {
                lines.append(field("Remote object", "\(identity.instance) · \(identity.objectType) · \(identity.remoteID)"))
            }
        }
        for entry in incident.timeline {
            lines.append("  \(formatter.string(from: entry.occurredAt)) · \(translate(entry.title))")
            lines.append(field(entry.packetCaptureSummary == nil ? "Recorded at" : "Imported at", formatter.string(from: entry.recordedAt)))
            lines.append(field("Recorded by", entry.packetCaptureSummary == nil ? entry.author : translate(entry.author)))
            if let capture = entry.packetCaptureSummary {
                lines += [field("SHA-256", capture.sha256), field("Captured packets", String(capture.packets)),
                          field("Capture file size", "\(capture.fileBytes) B"), field("Capture parser", capture.parser)]
            } else {
                lines.append(field("Evidence and notes", entry.detail))
            }
            if let run = retestRuns.first(where: { $0.id == entry.retestRunID }) {
                lines.append(field("Attached retest result", "\(run.id.uuidString) · \(translate(run.status.title)) · \(run.actualTarget)"))
            }
        }
        return lines
    }
}

private enum FieldProjectError: LocalizedError {
    case fileTooLarge, invalidFormat, unsupportedVersion, invalidCheck, invalidDiagnosticEvidence
    case duplicateDiagnosticEvidence, diagnosticEvidenceLimit

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return t("The field project exceeds the 512 KB limit.")
        case .invalidFormat: return t("The field project is damaged or has an invalid format.")
        case .unsupportedVersion: return t("This field project uses an unsupported format version.")
        case .invalidCheck: return t("This field project contains an unknown check.")
        case .invalidDiagnosticEvidence: return t("This field project contains invalid diagnostic evidence.")
        case .duplicateDiagnosticEvidence: return t("This diagnostic is already attached to this check.")
        case .diagnosticEvidenceLimit: return t("Each check can include at most 10 diagnostic records.")
        }
    }
}


extension FieldProject {
    public static let maximumAcceptanceRevisions = 8

    public var acceptanceDraft: FieldAcceptanceDraft {
        get { structuredAcceptance ?? FieldAcceptanceDraft() }
        set {
            let previous = acceptanceDraft
            var draft = newValue
            for index in draft.items.indices {
                var item = draft.items[index]
                if let id = item.requirementID, !draft.requirements.contains(where: { $0.id == id }) {
                    item.requirementID = nil
                }
                if let id = item.pointID, !draft.points.contains(where: { $0.id == id }) {
                    item.pointID = nil
                }
                if let oldItem = previous.items.first(where: { $0.id == item.id }),
                   draft.planVersion == previous.planVersion,
                   draft.requirement(for: item) == previous.requirement(for: oldItem),
                   draft.point(for: item) == previous.point(for: oldItem),
                   item.usesSameAssessmentInputs(as: oldItem) {
                    item.recordedResult = oldItem.recordedResult
                } else {
                    item.recordedResult = .pending
                    if let oldItem = previous.items.first(where: { $0.id == item.id }),
                       item.exception == oldItem.exception {
                        item.exception = nil
                    }
                }
                draft.items[index] = item
            }
            if draft != previous {
                schemaVersion = max(schemaVersion, 2)
                structuredAcceptance = draft
            }
        }
    }

    public var acceptanceRevisions: [FieldAcceptanceRevision] { savedAcceptanceRevisions ?? [] }

    public var maintenanceRevisionID: UUID? {
        get { selectedAcceptanceRevisionID }
        set {
            if newValue == nil || acceptanceRevisions.contains(where: { $0.id == newValue }) {
                selectedAcceptanceRevisionID = newValue
            }
        }
    }

    public var maintenanceRevision: FieldAcceptanceRevision? {
        acceptanceRevisions.first { $0.id == maintenanceRevisionID }
    }

    public func acceptanceResult(for item: FieldAcceptanceItem) -> FieldCheckResult {
        let draft = acceptanceDraft
        guard let stored = draft.items.first(where: { $0.id == item.id }) else { return .pending }
        return snapshot(of: stored, in: draft).result
    }

    public mutating func recordAcceptanceResult(_ result: FieldCheckResult, for id: UUID) throws {
        var draft = acceptanceDraft
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else {
            throw FieldAcceptanceError.invalidResult
        }
        draft.items[index].recordedResult = result
        guard snapshot(of: draft.items[index], in: draft).result == result else {
            throw FieldAcceptanceError.invalidResult
        }
        schemaVersion = max(schemaVersion, 2)
        structuredAcceptance = draft
    }

    public mutating func createAcceptanceRevision() throws {
        let draft = acceptanceDraft
        guard acceptanceRevisions.count < Self.maximumAcceptanceRevisions else {
            throw FieldAcceptanceError.revisionLimit
        }
        guard !draft.planVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.items.contains(where: { $0.kind == .acceptance }) else {
            throw FieldAcceptanceError.missingRevisionFields
        }
        guard draft.items.allSatisfy({ $0.exception?.isComplete != false }) else {
            throw FieldAcceptanceError.incompleteException
        }
        let revision = FieldAcceptanceRevision(
            id: UUID(), number: acceptanceRevisions.count + 1, createdAt: Date(),
            planVersion: draft.planVersion, items: draft.items.map { snapshot(of: $0, in: draft) }
        )
        var updated = self
        updated.schemaVersion = max(updated.schemaVersion, 2)
        updated.savedAcceptanceRevisions = acceptanceRevisions + [revision]
        _ = try updated.encoded()
        self = updated
    }

    public func acceptanceReport(
        revisionID: UUID?, selection: [UUID: Set<FieldAcceptanceReportField>], translate: (String) -> String
    ) -> String {
        let rows: [FieldAcceptanceSnapshotItem]
        let title: String
        if let revisionID {
            guard let revision = acceptanceRevisions.first(where: { $0.id == revisionID }) else {
                return translate("Handoff revision unavailable") + "\n"
            }
            rows = revision.items
            title = "\(translate("Handoff revision")) #\(revision.number)"
        } else {
            let draft = acceptanceDraft
            rows = draft.items.map { snapshot(of: $0, in: draft) }
            title = translate("Acceptance draft")
        }
        var lines = [translate("Acceptance report"), title, ""]
        for (index, row) in rows.enumerated() {
            lines.append("\(index + 1). \(translate(row.item.kind.title)) — \(translate(row.result.title))")
            lines.append("   \(translate("Attached diagnostic records")): \(row.diagnostics.count)")
            for field in FieldAcceptanceReportField.allCases where selection[row.id]?.contains(field) == true {
                let value = DiagnosticEvidenceExporter.redact(field.value(in: row, translate: translate))
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("   \(translate(field.title)): \(value)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func snapshot(of item: FieldAcceptanceItem, in draft: FieldAcceptanceDraft) -> FieldAcceptanceSnapshotItem {
        let requirement = draft.requirement(for: item)
        let point = draft.point(for: item)
        let diagnostics = item.evidenceSource == .history
            ? (item.historicalCheck.map { self[$0].attachedDiagnostics } ?? []) : []
        return FieldAcceptanceSnapshotItem(
            item: item, requirement: requirement, point: point,
            result: FieldAcceptanceSnapshotItem.effectiveResult(
                for: item, planVersion: draft.planVersion, requirement: requirement, point: point, diagnostics: diagnostics
            ), diagnostics: diagnostics
        )
    }

    private static func validEvidence(_ evidence: [FieldProjectDiagnosticEvidence]) -> Bool {
        evidence.count <= maximumDiagnosticEvidencePerCheck &&
        Set(evidence.map(\.runID)).count == evidence.count && evidence.allSatisfy(isValid)
    }

    private func validateAcceptance() throws {
        if schemaVersion == 1 {
            guard structuredAcceptance == nil, savedAcceptanceRevisions == nil, selectedAcceptanceRevisionID == nil else {
                throw FieldAcceptanceError.invalidDocument
            }
            return
        }
        let revisions = acceptanceRevisions
        guard acceptanceDraft.isValid, revisions.count <= Self.maximumAcceptanceRevisions,
              Set(revisions.map(\.id)).count == revisions.count,
              selectedAcceptanceRevisionID == nil || maintenanceRevision != nil else {
            throw FieldAcceptanceError.invalidDocument
        }
        for (index, revision) in revisions.enumerated() {
            guard revision.number == index + 1,
                  !revision.planVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revision.items.count <= FieldAcceptanceDraft.maximumItems,
                  revision.items.contains(where: { $0.item.kind == .acceptance }),
                  Set(revision.items.map(\.id)).count == revision.items.count else {
                throw FieldAcceptanceError.invalidDocument
            }
            for row in revision.items {
                let expected = FieldAcceptanceSnapshotItem.effectiveResult(
                    for: row.item, planVersion: revision.planVersion, requirement: row.requirement,
                    point: row.point, diagnostics: row.diagnostics
                )
                guard Self.validEvidence(row.diagnostics), row.result == expected,
                      row.item.exception?.isComplete != false else {
                    throw FieldAcceptanceError.invalidDocument
                }
            }
        }
    }
}
