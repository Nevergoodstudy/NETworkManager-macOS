import Foundation

// MARK: - Number / size formatting

public enum Fmt {
    public static var locale: Locale { Loc.shared.locale }

    /// Format a byte count with binary units (KiB, MiB, ...).
    public static func bytes(_ value: Double, decimals: Int = 2) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var v = value
        var idx = 0
        while abs(v) >= 1024, idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        return String(format: "%.\(decimals)f %@", v, units[idx])
    }

    /// Format a bit rate (bit/s).
    public static func bitRate(_ bitsPerSecond: Double) -> String {
        let units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"]
        var v = bitsPerSecond
        var idx = 0
        while abs(v) >= 1000, idx < units.count - 1 {
            v /= 1000
            idx += 1
        }
        return String(format: "%.2f %@", v, units[idx])
    }

    /// Format a byte rate.
    public static func byteRate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond, decimals: 2) + "/s"
    }

    /// Format a duration in seconds into a compact human readable form.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 0.001 { return String(format: "%.0f µs", seconds * 1_000_000) }
        if seconds < 1 { return String(format: "%.1f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)m \(rest)s"
    }

    /// Latency in milliseconds with one decimal.
    public static func ms(_ seconds: Double?) -> String {
        guard let seconds else { return "–" }
        return String(format: "%.1f ms", seconds * 1000)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.1f %%", value * 100)
    }

    public static func number(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func integer(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// Compact MAC address (`AA:BB:CC:DD:EE:FF`).
    public static func mac(_ raw: String) -> String {
        let hex = raw.filter { $0.isHexDigit }
        guard hex.count >= 12 else { return raw }
        var parts: [String] = []
        var idx = hex.startIndex
        for _ in 0..<6 {
            let end = hex.index(idx, offsetBy: 2)
            parts.append(String(hex[idx..<end]).uppercased())
            idx = end
        }
        return parts.joined(separator: ":")
    }
}

// MARK: - CSV export

public enum CSV {
    public static func make(headers: [String], rows: [[String]]) -> String {
        func escape(_ field: String) -> String {
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        var lines = [headers.map(escape).joined(separator: ",")]
        for row in rows {
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @discardableResult
    public static func write(_ content: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

import AppKit
import UniformTypeIdentifiers
