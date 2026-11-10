import Foundation

/// Exportable, deliberately secret-free representation of diagnostic evidence.
public struct DiagnosticEvidenceItem: Codable, Hashable, Sendable {
    public var id: UUID
    public var device: String
    public var address: String
    public var kind: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var parameters: [String: String]
    public var summary: String
    public var detail: String
    public var latency: TimeInterval?
    public var source: String
    public var evidence: DiagnosticRuntimeEvidence?
}

public enum DiagnosticEvidenceExporter {
    public static func items(runs: [DiagnosticRun], devices: [AssetDevice]) -> [DiagnosticEvidenceItem] {
        let lookup = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return runs.sorted { $0.startedAt < $1.startedAt }.map { run in
            let device = run.deviceID.flatMap { lookup[$0] }
            return DiagnosticEvidenceItem(
                id: run.id,
                device: redact(device?.name ?? "Standalone diagnostic"),
                address: redact(run.target ?? device?.address ?? "Unknown address"),
                kind: run.kind.rawValue.uppercased(),
                status: run.status.rawValue,
                startedAt: run.startedAt,
                finishedAt: run.finishedAt,
                parameters: redact(parameters: run.parameters),
                summary: redact(run.summary),
                detail: redact(run.detail),
                latency: run.latency,
                source: redact(run.source),
                evidence: redact(evidence: run.evidence)
            )
        }
    }

    public static func json(runs: [DiagnosticRun], devices: [AssetDevice]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(items(runs: runs, devices: devices))
    }

    public static func markdown(runs: [DiagnosticRun], devices: [AssetDevice]) -> String {
        let values = items(runs: runs, devices: devices)
        var lines = ["# NETworkManager diagnostic evidence", "", "Generated: \(ISO8601DateFormatter().string(from: Date()))", ""]
        if values.isEmpty {
            lines.append("No diagnostic runs were selected.")
            return lines.joined(separator: "\n") + "\n"
        }
        lines += ["| Time | Device | Target | Check | Status | Latency | Source |", "|---|---|---|---|---|---:|---|"]
        for value in values {
            let time = ISO8601DateFormatter().string(from: value.startedAt)
            let latency = value.latency.map { String(format: "%.1f ms", $0 * 1000) } ?? ""
            lines.append("| \(time) | \(value.device) | `\(value.address)` | \(value.kind) | \(value.status) | \(latency) | \(value.source) |")
            if !value.summary.isEmpty || !value.detail.isEmpty {
                lines.append("|  |  |  |  |  |  | \(value.summary) \(value.detail) |")
            }
        }
        for value in values {
            guard let evidence = value.evidence else { continue }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(evidence) {
                let json = String(decoding: data, as: UTF8.self)
                let longestFence = json.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longestFence + 1))
                lines += ["", "Runtime evidence: \(value.id.uuidString)", "", fence + "json", json, fence]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func redact(evidence: DiagnosticRuntimeEvidence?) -> DiagnosticRuntimeEvidence? {
        guard let evidence, let encoded = try? JSONEncoder().encode(evidence),
              let object = try? JSONSerialization.jsonObject(with: encoded) else { return nil }
        func redacted(_ value: Any) -> Any {
            if let text = value as? String { return redact(text) }
            if let values = value as? [String: Any] { return values.mapValues(redacted) }
            if let values = value as? [Any] { return values.map(redacted) }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: redacted(object)) else { return nil }
        return try? JSONDecoder().decode(DiagnosticRuntimeEvidence.self, from: data)
    }

    private static func redact(parameters: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: parameters.map { key, value in
            let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
            let secret = ["password", "passphrase", "token", "secret", "community", "privatekey", "apikey", "sshkey", "keypath", "authorization", "basicauth", "cookie", "credential", "username"]
                .contains { normalized.contains($0) }
            return (key, secret ? "[REDACTED]" : redact(value))
        })
    }

    private static func redact(_ text: String) -> String {
        var value = text
        let patterns: [(String, String)] = [
            (#"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#, "$1[REDACTED]@"),
            (#"(?i)(["'][^"']*(?:password|passphrase|token|secret|community|private[_-]?key|api[_-]?key|authorization|cookie|set-cookie|username|user[_-]?name|credential)[^"']*["']\s*:\s*")((?:\\.|[^"\\])*)(")"#, "$1[REDACTED]$3"),
            (#"(?i)(["'][^"']*(?:password|passphrase|token|secret|community|private[_-]?key|api[_-]?key|authorization|cookie|set-cookie|username|user[_-]?name|credential)[^"']*["']\s*:\s*')((?:\\.|[^'\\])*)(')"#, "$1[REDACTED]$3"),
            (#"(?im)(set-cookie|cookie)\s*:\s*[^\r\n]+"#, "$1: [REDACTED]"),
            (#"(?i)(authorization\s*[:=]\s*)(?:basic|bearer)\s+[A-Za-z0-9._~+/=-]+"#, "$1[REDACTED]"),
            (#"(?i)((?:password|passphrase|token|secret|community|private[_-]?key|api[_-]?key|authorization|cookie|set-cookie|username|user[_-]?name|credential)\s*[:=]\s*")((?:\\.|[^"\\])*)(")"#, "$1[REDACTED]$3"),
            (#"(?i)((?:password|passphrase|token|secret|community|private[_-]?key|api[_-]?key|authorization|cookie|set-cookie|username|user[_-]?name|credential)\s*[:=]\s*')((?:\\.|[^'\\])*)(')"#, "$1[REDACTED]$3"),
            (#"(?i)(password|passphrase|token|secret|community|private[_-]?key|api[_-]?key|authorization|cookie|set-cookie|username|user[_-]?name|credential)\s*[:=]\s*[^\s,;&]+"#, "$1=[REDACTED]"),
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        return value
    }
}
