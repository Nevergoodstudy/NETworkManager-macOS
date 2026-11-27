import Foundation

public enum FieldIncidentStatus: String, Codable, CaseIterable, Sendable {
    case open, monitoring, resolved

    public var title: String {
        switch self {
        case .open: return "Incident open"
        case .monitoring: return "Monitoring recovery"
        case .resolved: return "Incident resolved"
        }
    }
}

public enum FieldIncidentEntryKind: String, Codable, CaseIterable, Sendable {
    case reported, responded, escalated, temporarilyRestored, retested, note, metricObserved

    public var title: String {
        switch self {
        case .reported: return "Fault reported"
        case .responded: return "Response started"
        case .escalated: return "Escalated"
        case .temporarilyRestored: return "Temporary recovery"
        case .retested: return "Retest recorded"
        case .note: return "Incident note"
        case .metricObserved: return "Metric observation"
        }
    }
}

/// A portable association snapshot. Removing or renumbering the source asset
/// does not replace the address recorded when this incident was associated.
public struct FieldIncidentAssetReference: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let name: String
    public let address: String
    public let externalIdentity: ExternalAssetIdentity?

    public init(device: AssetDevice) {
        deviceID = device.id
        name = device.name
        address = device.address
        externalIdentity = device.externalIdentity
    }

    var isValid: Bool {
        name.count <= 200 && address.count <= 500 && externalIdentity?.isValid != false
    }
}

public struct FieldMetricObservation: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let seconds: Int
        public let nanoseconds: Int
        public let rawValue: String

        public init(seconds: Int, nanoseconds: Int, rawValue: String) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
            self.rawValue = rawValue
        }

        public var timestamp: String { "\(seconds)\(String(format: ".%09d", nanoseconds))" }
    }

    public private(set) var source: String
    public let instanceID: String
    public let eventID: String
    public let hostID: String
    public private(set) var hostName: String
    public let itemID: String
    public private(set) var itemName: String
    public private(set) var unit: String
    public private(set) var configuredInterval: String
    public let queriedAt: Date
    public let alertSecond: Int
    public let window: ClosedRange<Int>
    public let samples: [Sample]
    public let beforeOrAtLimitReached: Bool
    public let afterLimitReached: Bool
    public let afterWindowOpen: Bool

    public init(source: String, instanceID: String, eventID: String, hostID: String, hostName: String,
                itemID: String, itemName: String, unit: String, configuredInterval: String,
                queriedAt: Date, alertSecond: Int, window: ClosedRange<Int>, samples: [Sample],
                beforeOrAtLimitReached: Bool, afterLimitReached: Bool, afterWindowOpen: Bool) {
        self.source = DiagnosticEvidenceExporter.redact(source)
        self.instanceID = instanceID
        self.eventID = eventID
        self.hostID = hostID
        self.hostName = DiagnosticEvidenceExporter.redact(hostName)
        self.itemID = itemID
        self.itemName = DiagnosticEvidenceExporter.redact(itemName)
        self.unit = DiagnosticEvidenceExporter.redact(unit)
        self.configuredInterval = DiagnosticEvidenceExporter.redact(configuredInterval)
        self.queriedAt = queriedAt
        self.alertSecond = alertSecond
        self.window = window
        self.samples = samples
        self.beforeOrAtLimitReached = beforeOrAtLimitReached
        self.afterLimitReached = afterLimitReached
        self.afterWindowOpen = afterWindowOpen
    }

    func redactedForExport() -> Self {
        var safe = self
        safe.source = DiagnosticEvidenceExporter.redact(source)
        safe.hostName = DiagnosticEvidenceExporter.redact(hostName)
        safe.itemName = DiagnosticEvidenceExporter.redact(itemName)
        safe.unit = DiagnosticEvidenceExporter.redact(unit)
        safe.configuredInterval = DiagnosticEvidenceExporter.redact(configuredInterval)
        return safe
    }

    public var states: [String] {
        var states: [String] = []
        if samples.isEmpty { states.append("Zabbix returned no samples in this window.") }
        if beforeOrAtLimitReached { states.append("History at or before the alert was truncated.") }
        if afterLimitReached { states.append("History after the alert was truncated.") }
        if afterWindowOpen { states.append("Post-alert window was still open at query time.") }
        return states
    }

    var isValid: Bool {
        guard !source.isEmpty, source.utf8.count <= 512, instanceID.utf8.count == 64,
              instanceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              [eventID, hostID, itemID].allSatisfy({ UInt64($0).map { $0 > 0 } == true }),
              [hostName, itemName, unit, configuredInterval].allSatisfy({ $0.utf8.count <= 2_048 }),
              queriedAt.timeIntervalSinceReferenceDate.isFinite, alertSecond > 0,
              window.lowerBound >= 0, window.contains(alertSecond),
              window.upperBound - window.lowerBound <= 3_600, samples.count <= 1_000,
              samples.allSatisfy({ window.contains($0.seconds) && (0..<1_000_000_000).contains($0.nanoseconds) &&
                  $0.rawValue.utf8.count <= 64 && Double($0.rawValue)?.isFinite == true }) else { return false }
        let beforeOrAtCount = samples.count { $0.seconds <= alertSecond }
        return beforeOrAtCount <= 500 && samples.count - beforeOrAtCount <= 500
    }
}

public struct FieldIncidentEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: FieldIncidentEntryKind
    public var occurredAt: Date
    public var recordedAt: Date
    public var author: String
    public var detail: String
    public var retestRunID: UUID?
    public let metricObservation: FieldMetricObservation?
    public let packetCaptureSummary: PacketCaptureSummary?

    public init(id: UUID = UUID(), kind: FieldIncidentEntryKind, occurredAt: Date = Date(),
                recordedAt: Date = Date(), author: String, detail: String, retestRunID: UUID? = nil,
                metricObservation: FieldMetricObservation? = nil, packetCaptureSummary: PacketCaptureSummary? = nil) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.author = author
        self.detail = detail
        self.retestRunID = retestRunID
        self.metricObservation = metricObservation
        self.packetCaptureSummary = packetCaptureSummary
    }

    public var title: String {
        packetCaptureSummary == nil ? kind.title : "Packet capture summary"
    }

    var isValid: Bool {
        occurredAt.timeIntervalSinceReferenceDate.isFinite && recordedAt.timeIntervalSinceReferenceDate.isFinite &&
            !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && author.count <= 120 &&
            !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && detail.count <= 2_000 &&
            (retestRunID == nil || kind == .retested) &&
            (kind == .metricObserved) == (metricObservation != nil) && metricObservation?.isValid != false &&
            (packetCaptureSummary == nil || kind == .note)
    }
}

public struct FieldIncident: Codable, Equatable, Identifiable, Sendable {
    public static let maximumEntries = 60
    public var id: UUID
    public var title: String
    public var owner: String
    public var ticketReference: String
    public var status: FieldIncidentStatus
    public var createdAt: Date
    public var baselineRevisionID: UUID?
    public var asset: FieldIncidentAssetReference?
    public var entries: [FieldIncidentEntry]

    public init(id: UUID = UUID(), title: String, owner: String, ticketReference: String = "",
                status: FieldIncidentStatus = .open, createdAt: Date = Date(),
                baselineRevisionID: UUID? = nil, asset: FieldIncidentAssetReference? = nil,
                entries: [FieldIncidentEntry] = []) {
        self.id = id
        self.title = title
        self.owner = owner
        self.ticketReference = ticketReference
        self.status = status
        self.createdAt = createdAt
        self.baselineRevisionID = baselineRevisionID
        self.asset = asset
        self.entries = entries
    }

    public var timeline: [FieldIncidentEntry] {
        entries.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 &&
            !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && owner.count <= 120 &&
            ticketReference.count <= 200 && createdAt.timeIntervalSinceReferenceDate.isFinite &&
            asset?.isValid != false && entries.count <= Self.maximumEntries &&
            Set(entries.map(\.id)).count == entries.count && entries.allSatisfy(\.isValid)
    }
}

public enum FieldIncidentError: LocalizedError {
    case invalidRecord, incidentLimit, entryLimit, missingIncident, invalidReference

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: return t("Incident fields are missing, too long, or invalid.")
        case .incidentLimit: return t("A field project can contain up to 20 incidents.")
        case .entryLimit: return t("An incident can contain up to 60 timeline entries.")
        case .missingIncident: return t("The selected incident is unavailable.")
        case .invalidReference: return t("The incident baseline or retest reference is unavailable or does not match.")
        }
    }
}
