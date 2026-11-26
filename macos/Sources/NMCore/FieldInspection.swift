import Foundation

public struct FieldInspectionTemplateItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var target: String
    public var criterion: String

    public init(id: UUID = UUID(), title: String, target: String = "", criterion: String = "") {
        self.id = id
        self.title = title
        self.target = target
        self.criterion = criterion
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 &&
            target.count <= 300 && criterion.count <= 1_000
    }
}

public struct FieldInspectionTemplate: Codable, Equatable, Identifiable, Sendable {
    public static let maximumItems = 40
    public var id: UUID
    public var title: String
    public var version: String
    public var items: [FieldInspectionTemplateItem]

    public init(id: UUID = UUID(), title: String, version: String = "1", items: [FieldInspectionTemplateItem]) {
        self.id = id
        self.title = title
        self.version = version
        self.items = items
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 &&
            !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && version.count <= 40 &&
            !items.isEmpty && items.count <= Self.maximumItems &&
            Set(items.map(\.id)).count == items.count && items.allSatisfy(\.isValid)
    }
}

public struct FieldInspectionRecordItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let target: String
    public let criterion: String
    public var result: FieldCheckResult
    public var evidence: String
    public var followUpOwner: String
    public var dueAt: Date?

    public init(templateItem: FieldInspectionTemplateItem) {
        id = templateItem.id
        title = templateItem.title
        target = templateItem.target
        criterion = templateItem.criterion
        result = .pending
        evidence = ""
        followUpOwner = ""
        dueAt = nil
    }

    public var effectiveResult: FieldCheckResult {
        switch result {
        case .met, .notMet: return hasRequiredEvidence ? result : .pending
        case .blocked: return evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .pending : result
        case .pending: return .pending
        }
    }

    var hasRequiredEvidence: Bool {
        [criterion, evidence].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 &&
            target.count <= 300 && criterion.count <= 1_000 && evidence.count <= 2_000 &&
            followUpOwner.count <= 120 && dueAt?.timeIntervalSinceReferenceDate.isFinite != false
    }
}

public struct FieldInspectionRecord: Codable, Equatable, Identifiable, Sendable {
    public static let maximumItems = FieldInspectionTemplate.maximumItems
    public let id: UUID
    public let templateID: UUID
    public let templateTitle: String
    public let templateVersion: String
    public var owner: String
    public var recordedAt: Date
    public var items: [FieldInspectionRecordItem]

    public init(id: UUID = UUID(), templateID: UUID, templateTitle: String, templateVersion: String,
                owner: String, recordedAt: Date = Date(), items: [FieldInspectionRecordItem]) {
        self.id = id
        self.templateID = templateID
        self.templateTitle = templateTitle
        self.templateVersion = templateVersion
        self.owner = owner
        self.recordedAt = recordedAt
        self.items = items
    }

    var isValid: Bool {
        !templateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && templateTitle.count <= 160 &&
            !templateVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && templateVersion.count <= 40 &&
            !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && owner.count <= 120 &&
            recordedAt.timeIntervalSinceReferenceDate.isFinite && !items.isEmpty &&
            items.count <= Self.maximumItems && Set(items.map(\.id)).count == items.count && items.allSatisfy(\.isValid)
    }
}

public enum FieldInspectionError: LocalizedError {
    case invalidTemplate, templateLimit, invalidRecord, recordLimit, missingTemplate

    public var errorDescription: String? {
        switch self {
        case .invalidTemplate: return t("Inspection template fields are missing, too long, or invalid.")
        case .templateLimit: return t("A field project can contain up to 20 inspection templates.")
        case .invalidRecord: return t("Inspection fields are missing, too long, or invalid.")
        case .recordLimit: return t("A field project can contain up to 30 inspection records.")
        case .missingTemplate: return t("The inspection template is unavailable.")
        }
    }
}
