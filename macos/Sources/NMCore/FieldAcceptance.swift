import Foundation

public struct FieldRequirement: Codable, Equatable, Identifiable, Sendable {
    public private(set) var id = UUID()
    public var title: String

    public init(title: String = "") { self.title = title }
}

public struct FieldMeasurementPoint: Codable, Equatable, Identifiable, Sendable {
    public private(set) var id = UUID()
    public var title: String

    public init(title: String = "") { self.title = title }
}

public enum FieldAcceptanceKind: String, Codable, CaseIterable, Sendable {
    case poc, acceptance

    public var title: String {
        switch self {
        case .poc: return "Proof of concept"
        case .acceptance: return "Acceptance check"
        }
    }
}

public enum FieldAcceptanceEvidenceSource: String, Codable, CaseIterable, Sendable {
    case engineer, customer, history, measurement

    public var title: String {
        switch self {
        case .engineer: return "Engineer notes"
        case .customer: return "Customer material"
        case .history: return "Attached diagnostic history"
        case .measurement: return "On-site measurement (entered manually)"
        }
    }
}

public struct FieldAcceptanceException: Codable, Equatable, Sendable {
    public var note = ""
    public var confirmedBy = ""
    public var confirmedAt = Date()
    public var retestPlan = ""

    public init() {}

    var isComplete: Bool {
        [note, confirmedBy, retestPlan].allSatisfy(\.hasFieldText)
    }
}

public struct FieldAcceptanceItem: Codable, Equatable, Identifiable, Sendable {
    public private(set) var id = UUID()
    public let kind: FieldAcceptanceKind
    public var requirementID: UUID?
    public var pointID: UUID?
    public var criterion = ""
    public var unit = ""
    public var conditions = ""
    public var evidence = ""
    public var evidenceSource: FieldAcceptanceEvidenceSource = .engineer
    public var owner = ""
    public var blockedReason = ""
    public var exception: FieldAcceptanceException?
    public var historicalCheck: FieldProjectCheck?
    var recordedResult: FieldCheckResult = .pending

    public init(kind: FieldAcceptanceKind) { self.kind = kind }

    func usesSameAssessmentInputs(as previous: Self) -> Bool {
        requirementID == previous.requirementID && pointID == previous.pointID &&
        criterion == previous.criterion && unit == previous.unit && conditions == previous.conditions &&
        evidence == previous.evidence && evidenceSource == previous.evidenceSource &&
        blockedReason == previous.blockedReason && historicalCheck == previous.historicalCheck
    }
}

public struct FieldAcceptanceDraft: Codable, Equatable, Sendable {
    public static let maximumRequirements = 24
    public static let maximumPoints = 24
    public static let maximumItems = 32

    public var planVersion = ""
    public var requirements: [FieldRequirement] = []
    public var points: [FieldMeasurementPoint] = []
    public var items: [FieldAcceptanceItem] = []

    public init() {}

    func requirement(for item: FieldAcceptanceItem) -> String {
        requirements.first { $0.id == item.requirementID }?.title ?? ""
    }

    func point(for item: FieldAcceptanceItem) -> String {
        points.first { $0.id == item.pointID }?.title ?? ""
    }

    var isValid: Bool {
        requirements.count <= Self.maximumRequirements && points.count <= Self.maximumPoints &&
        items.count <= Self.maximumItems && Set(requirements.map(\.id)).count == requirements.count &&
        Set(points.map(\.id)).count == points.count && Set(items.map(\.id)).count == items.count &&
        items.allSatisfy { item in
            (item.requirementID == nil || requirements.contains { $0.id == item.requirementID }) &&
            (item.pointID == nil || points.contains { $0.id == item.pointID })
        }
    }
}

public struct FieldAcceptanceSnapshotItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { item.id }
    public let item: FieldAcceptanceItem
    public let requirement: String
    public let point: String
    public let result: FieldCheckResult
    public let diagnostics: [FieldProjectDiagnosticEvidence]

    static func effectiveResult(
        for item: FieldAcceptanceItem, planVersion: String, requirement: String, point: String,
        diagnostics: [FieldProjectDiagnosticEvidence]
    ) -> FieldCheckResult {
        switch item.recordedResult {
        case .met, .notMet:
            let required = [planVersion, requirement, point, item.criterion, item.conditions]
            let hasEvidence = item.evidenceSource == .history ? !diagnostics.isEmpty : item.evidence.hasFieldText
            return required.allSatisfy(\.hasFieldText) && hasEvidence ? item.recordedResult : .pending
        case .blocked:
            return item.blockedReason.hasFieldText ? .blocked : .pending
        case .pending:
            return .pending
        }
    }
}

public struct FieldAcceptanceRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let number: Int
    public let createdAt: Date
    public let planVersion: String
    public let items: [FieldAcceptanceSnapshotItem]
}

public enum FieldAcceptanceReportField: String, CaseIterable, Sendable {
    case requirement, point, criterion, conditions, evidence, owner, blockedReason, exception, diagnostics

    public var title: String {
        switch self {
        case .requirement: return "Requirement"
        case .point: return "Measurement point"
        case .criterion: return "Criterion"
        case .conditions: return "Observation conditions"
        case .evidence: return "Evidence and notes"
        case .owner: return "Follow-up owner"
        case .blockedReason: return "Reason blocked"
        case .exception: return "Confirmed exception"
        case .diagnostics: return "Diagnostic details"
        }
    }

    func value(in row: FieldAcceptanceSnapshotItem, translate: (String) -> String) -> String {
        switch self {
        case .requirement: return row.requirement
        case .point: return row.point
        case .criterion: return [row.item.criterion, row.item.unit].filter(\.hasFieldText).joined(separator: " · ")
        case .conditions: return row.item.conditions
        case .owner: return row.item.owner
        case .blockedReason: return row.item.blockedReason
        case .evidence:
            return "\(translate(row.item.evidenceSource.title)) · \(row.item.evidence)"
        case .exception:
            guard let value = row.item.exception, value.isComplete else { return "" }
            return [value.note, value.confirmedBy, ISO8601DateFormatter().string(from: value.confirmedAt),
                    "\(translate("Retest plan")): \(value.retestPlan)"].joined(separator: " · ")
        case .diagnostics:
            let dateFormat = ISO8601DateFormatter()
            return row.diagnostics.map { evidence in
                var fields = [dateFormat.string(from: evidence.startedAt), evidence.source, evidence.device, evidence.target,
                              evidence.kind, evidence.status, translate(evidence.addressFamily.title), evidence.summary]
                if let latency = evidence.latency {
                    fields.append("\(translate("Latency")): \(String(format: "%.1f ms", latency * 1000))")
                }
                let context = evidence.networkContext.hasFieldText ? evidence.networkContext : translate("Not recorded")
                fields.append("\(translate("Context note (added when attaching)")): \(context)")
                return fields.joined(separator: " · ")
            }.joined(separator: "\n    ")
        }
    }
}

extension String {
    fileprivate var hasFieldText: Bool { !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum FieldAcceptanceError: LocalizedError {
    case invalidDocument, invalidResult, missingRevisionFields, revisionLimit, incompleteException

    var errorDescription: String? {
        switch self {
        case .invalidDocument: return t("This field project contains invalid acceptance records.")
        case .invalidResult: return t("Add the required assessment fields and evidence before recording this result.")
        case .missingRevisionFields: return t("Add a plan version and at least one acceptance check before creating a handoff revision.")
        case .revisionLimit: return t("This project already contains the maximum number of handoff revisions.")
        case .incompleteException: return t("Complete the exception, confirmer, and retest plan before creating a handoff revision.")
        }
    }
}
