import Foundation
import SwiftUI

public enum OperationAuditKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sshSessionOpened
    case readOnlyCommandSubmitted
    case confirmedCommandSubmitted
    case sshSessionClosed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sshSessionOpened: return t("SSH session opened")
        case .readOnlyCommandSubmitted: return t("Read-only command submitted")
        case .confirmedCommandSubmitted: return t("Confirmed command submitted")
        case .sshSessionClosed: return t("SSH session closed")
        }
    }
}

public struct OperationAuditRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var target: String
    public var kind: OperationAuditKind

    public init(id: UUID = UUID(), timestamp: Date = Date(), target: String, kind: OperationAuditKind) {
        self.id = id
        self.timestamp = timestamp
        self.target = target
        self.kind = kind
    }
}

/// A local audit trail that deliberately excludes command text and terminal output.
public final class OperationsAuditLog: ObservableObject {
    public static let shared = OperationsAuditLog()

    @Published public private(set) var records: [OperationAuditRecord] = []

    private let storageURL: URL
    private let recordLimit = 500

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? SettingsStore.supportDirectory.appendingPathComponent("operations-audit.json")
        load()
    }

    public func record(target: String, kind: OperationAuditKind) {
        let record = OperationAuditRecord(target: target, kind: kind)
        records.insert(record, at: 0)
        if records.count > recordLimit { records = Array(records.prefix(recordLimit)) }
        save()
    }

    public func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([OperationAuditRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Unable to save operation audit log: %@", error.localizedDescription)
        }
    }
}
