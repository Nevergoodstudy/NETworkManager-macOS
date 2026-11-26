import Foundation

public enum FieldIncidentExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case json

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}

public enum FieldIncidentExporter {
    public static func data(for incident: FieldIncident, retestRuns: [FieldRetestRecord],
                            format: FieldIncidentExportFormat, generatedAt: Date = Date()) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown(for: incident, retestRuns: retestRuns, generatedAt: generatedAt).utf8)
        case .json:
            return try json(for: incident, retestRuns: retestRuns, generatedAt: generatedAt)
        }
    }

    public static func json(for incident: FieldIncident, retestRuns: [FieldRetestRecord],
                            generatedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload(for: incident, retestRuns: retestRuns, generatedAt: generatedAt))
    }

    public static func markdown(for incident: FieldIncident, retestRuns: [FieldRetestRecord],
                                generatedAt: Date = Date()) -> String {
        let payload = payload(for: incident, retestRuns: retestRuns, generatedAt: generatedAt)
        let formatter = ISO8601DateFormatter()
        func field(_ label: String, _ value: String) -> String {
            "- **\(t(label))**: \(markdownText(value))"
        }

        var lines = ["# \(t("Case and observation export"))", "", "\(t("Generated")): \(formatter.string(from: payload.generatedAt))", "",
                     "## \(t("Incident"))", field("Incident title", payload.caseRecord.title),
                     field("Incident status", t(FieldIncidentStatus(rawValue: payload.caseRecord.status)?.title ?? payload.caseRecord.status)),
                     field("Owner", payload.caseRecord.owner)]
        if !payload.caseRecord.ticketReference.isEmpty {
            lines.append(field("External ticket reference", payload.caseRecord.ticketReference))
        }
        lines.append(field("Created at", formatter.string(from: payload.caseRecord.createdAt)))
        if let asset = payload.caseRecord.asset {
            lines.append(field("Associated asset snapshot", "\(asset.name) · \(asset.address)"))
            if let identity = asset.externalIdentity {
                lines.append(field("Remote object", "\(identity.instance) · \(identity.objectType) · \(identity.remoteID)"))
            }
        }

        lines += ["", "## \(t("Observations"))"]
        if payload.observations.isEmpty { lines.append(t("No timeline entries.")) }
        for observation in payload.observations {
            let author = observation.packetCaptureSummary == nil ? observation.author : t(observation.author)
            lines += ["", "### \(formatter.string(from: observation.occurredAt)) · \(t(observation.kindTitle))",
                      field(observation.packetCaptureSummary == nil ? "Recorded at" : "Imported at", formatter.string(from: observation.recordedAt)),
                      field("Recorded by", author)]
            if observation.packetCaptureSummary == nil { lines.append(field("Evidence and notes", observation.detail)) }
            if let retest = observation.retest {
                lines.append(field("Attached retest result", "\(t(retest.statusTitle)) · \(retest.target) · \(formatter.string(from: retest.startedAt))"))
                if let service = retest.serviceEvidence {
                    if let method = retest.method { lines.append(field("Method", t(method.title))) }
                    lines += service.detail.split(separator: "\n").map { "- \(markdownText(DiagnosticEvidenceExporter.redact(String($0))))" }
                }
            }
            if let capture = observation.packetCaptureSummary {
                lines += [field("SHA-256", capture.sha256), field("Captured packets", String(capture.packets)),
                          field("Capture file size", "\(capture.fileBytes) B"), field("Capture parser", capture.parser)]
            }
            if let metric = observation.metricObservation {
                let windowStart = formatter.string(from: Date(timeIntervalSince1970: Double(metric.window.lowerBound)))
                let windowEnd = formatter.string(from: Date(timeIntervalSince1970: Double(metric.window.upperBound)))
                lines += [field("Source", metric.source), field("Instance ID", metric.instanceID),
                          field("Event ID", metric.eventID), field("Host", "\(metric.hostName) · \(metric.hostID)"),
                          field("Monitoring item", "\(metric.itemName) · \(metric.itemID)"),
                          field("Unit", metric.unit), field("Configured interval", metric.configuredInterval),
                          field("Query time", formatter.string(from: metric.queriedAt)),
                          field("Time window", "\(windowStart) – \(windowEnd)")]
                lines += metric.states.map { "- \(t($0))" }
                if !metric.samples.isEmpty {
                    lines += ["", "| \(t("Unix timestamp")) | \(t("Value")) |", "| --- | --- |"]
                    lines += metric.samples.map { "| `\($0.timestamp)` | `\($0.rawValue)` |" }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func payload(for incident: FieldIncident, retestRuns: [FieldRetestRecord], generatedAt: Date) -> Payload {
        Payload(
            schemaVersion: incident.entries.contains { $0.metricObservation != nil } ? 2 : 1,
            generatedAt: generatedAt,
            caseRecord: Payload.CaseRecord(
                id: incident.id,
                title: DiagnosticEvidenceExporter.redact(incident.title),
                status: incident.status.rawValue,
                owner: DiagnosticEvidenceExporter.redact(incident.owner),
                ticketReference: DiagnosticEvidenceExporter.redact(incident.ticketReference),
                createdAt: incident.createdAt,
                asset: incident.asset.map { asset in
                    Payload.AssetSnapshot(
                        name: DiagnosticEvidenceExporter.redact(asset.name),
                        address: DiagnosticEvidenceExporter.redact(asset.address),
                        externalIdentity: asset.externalIdentity.map {
                            Payload.ExternalIdentity(instance: DiagnosticEvidenceExporter.redact($0.instance),
                                                     objectType: DiagnosticEvidenceExporter.redact($0.objectType),
                                                     remoteID: DiagnosticEvidenceExporter.redact($0.remoteID))
                        }
                    )
                }
            ),
            observations: incident.timeline.map { entry in
                let retest = entry.retestRunID.flatMap { id in retestRuns.first { $0.id == id } }
                return Payload.Observation(
                    id: entry.id,
                    kind: entry.kind.rawValue,
                    kindTitle: entry.title,
                    occurredAt: entry.occurredAt,
                    recordedAt: entry.recordedAt,
                    author: DiagnosticEvidenceExporter.redact(entry.author),
                    detail: DiagnosticEvidenceExporter.redact(entry.detail),
                    retest: retest.map {
                        Payload.Retest(status: $0.status.rawValue, statusTitle: $0.status.title,
                                       target: DiagnosticEvidenceExporter.redact($0.actualTarget), startedAt: $0.startedAt,
                                       method: $0.serviceEvidence == nil ? nil : $0.request.method,
                                       serviceEvidence: $0.serviceEvidence)
                    },
                    metricObservation: entry.metricObservation?.redactedForExport(),
                    packetCaptureSummary: entry.packetCaptureSummary
                )
            }
        )
    }

    private static func markdownText(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            var escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|"] {
                escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
            }
            return escaped
        }.joined(separator: "  \n  ")
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let caseRecord: CaseRecord
        let observations: [Observation]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, generatedAt, observations
            case caseRecord = "case"
        }

        struct CaseRecord: Codable {
            let id: UUID
            let title: String
            let status: String
            let owner: String
            let ticketReference: String
            let createdAt: Date
            let asset: AssetSnapshot?
        }

        struct AssetSnapshot: Codable {
            let name: String
            let address: String
            let externalIdentity: ExternalIdentity?
        }

        struct ExternalIdentity: Codable {
            let instance: String
            let objectType: String
            let remoteID: String
        }

        struct Observation: Codable {
            let id: UUID
            let kind: String
            let kindTitle: String
            let occurredAt: Date
            let recordedAt: Date
            let author: String
            let detail: String
            let retest: Retest?
            let metricObservation: FieldMetricObservation?
            let packetCaptureSummary: PacketCaptureSummary?
        }

        struct Retest: Codable {
            let status: String
            let statusTitle: String
            let target: String
            let startedAt: Date
            let method: FieldRetestMethod?
            let serviceEvidence: ServiceProbeEvidence?
        }
    }
}
