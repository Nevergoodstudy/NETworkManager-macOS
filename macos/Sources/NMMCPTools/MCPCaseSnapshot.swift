import Darwin
import Foundation
import MCP
import NMCore

public struct MCPCaseSnapshot: Sendable {
    public let summaryJSON: String
    let summary: Value
    let caseID: UUID
    let generatedAt: Date
    let observations: [Observation]

    public init(path: String) throws {
        let limit = 1_048_576
        guard path.hasPrefix("/") else { throw Failure.invalidFile }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw Failure.invalidFile
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard (1...2).contains(snapshot.schemaVersion),
              !snapshot.caseRecord.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.caseRecord.title.count <= 160,
              snapshot.observations.count <= FieldIncident.maximumEntries,
              Set(snapshot.observations.map(\.id)).count == snapshot.observations.count else {
            throw Failure.invalidFile
        }
        let formatter = ISO8601DateFormatter()
        summary = [
            "schemaVersion": 1, "caseID": .string(snapshot.caseRecord.id.uuidString),
            "title": .string(DiagnosticEvidenceExporter.redact(snapshot.caseRecord.title)),
            "status": .string(snapshot.caseRecord.status.rawValue),
            "createdAt": .string(formatter.string(from: snapshot.caseRecord.createdAt)),
            "snapshotGeneratedAt": .string(formatter.string(from: snapshot.generatedAt)),
            "observationCount": .int(snapshot.observations.count)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        summaryJSON = String(decoding: try encoder.encode(summary), as: UTF8.self)
        caseID = snapshot.caseRecord.id
        generatedAt = snapshot.generatedAt
        observations = snapshot.observations
    }

    private enum Failure: Error { case invalidFile }

    private struct Snapshot: Decodable {
        let schemaVersion: Int
        let generatedAt: Date
        let caseRecord: CaseRecord
        let observations: [Observation]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, generatedAt, observations
            case caseRecord = "case"
        }

        struct CaseRecord: Decodable {
            let id: UUID
            let title: String
            let status: FieldIncidentStatus
            let createdAt: Date
        }
    }

    struct Observation: Decodable, Sendable {
        let id: UUID
        let kind: FieldIncidentEntryKind
        let occurredAt: Date
        let recordedAt: Date
        let detail: String
        let detailTruncated: Bool

        private enum CodingKeys: String, CodingKey {
            case id, kind, occurredAt, recordedAt, detail
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            kind = try values.decode(FieldIncidentEntryKind.self, forKey: .kind)
            occurredAt = try values.decode(Date.self, forKey: .occurredAt)
            recordedAt = try values.decode(Date.self, forKey: .recordedAt)
            let redacted = DiagnosticEvidenceExporter.redact(try values.decode(String.self, forKey: .detail))
            let preview = redacted.unicodeScalars.prefix(2_048)
            detailTruncated = preview.endIndex != redacted.unicodeScalars.endIndex
            detail = String(preview)
        }
    }

}
