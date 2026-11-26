import CryptoKit
import Darwin
import Foundation

public enum ConfigurationComparison {
    public enum Format: String, CaseIterable, Sendable {
        case ciscoIOS = "Cisco IOS"
        case junosSet = "Junos display set"
    }

    public struct Change: Identifiable, Sendable {
        public enum Kind: String, Sendable { case removed, added }
        public let kind: Kind
        public let line: Int
        public let text: String
        public var id: String { "\(kind.rawValue):\(line)" }
    }

    public struct Report: Sendable {
        public let beforeSHA256: String
        public let afterSHA256: String
        public let changes: [Change]
        public let omittedLinesChanged: Bool
    }

    public enum Failure: Error { case unreadable, limit, invalidText }
    package enum CaptureFailure: Error { case incomplete, timedOut, cancelled }

    package enum Input: Sendable {
        case file(URL)
        case capture(Data, source: String, at: Date)

        package var title: String {
            switch self {
            case .file(let url): url.lastPathComponent
            case .capture(_, let source, let date): "\(source) · \(Fmt.dateTime(date))"
            }
        }

        fileprivate func data() throws -> Data {
            switch self {
            case .file(let url): try ConfigurationComparison.read(url)
            case .capture(let data, _, _): data
            }
        }
    }

    public static func compare(before: URL, after: URL, format: Format) async throws -> Report {
        try await compare(before: .file(before), after: .file(after), format: format)
    }

    package static func compare(before: Input, after: Input, format: Format) async throws -> Report {
        let result = await runBlockingDiagnostic {
            Result { try compare(before: before.data(), after: after.data(), format: format) }
        }
        return try result.get()
    }

    package static let maximumBytes = 512 * 1_024

    package static func capture(_ result: CommandResult, format: Format, target: String) throws -> Input {
        if result.cancelled { throw CaptureFailure.cancelled }
        if result.timedOut { throw CaptureFailure.timedOut }
        if result.stdoutTruncated { throw Failure.limit }
        let text = result.stdout
        let data = Data(text.utf8)
        guard result.succeeded, data.count == result.stdoutBytesObserved,
              text.last?.isNewline == true, !text.contains("\0"), !text.contains("\u{FFFD}"),
              !text.contains("--More--"), !text.contains("---(more)---") else { throw CaptureFailure.incomplete }
        let lines = text.split(whereSeparator: \.isNewline)
        guard data.count <= maximumBytes, lines.count < 2_000 else { throw Failure.limit }
        switch format {
        case .ciscoIOS:
            guard lines.contains(where: { $0.hasPrefix("Current configuration") }),
                  lines.last == "end",
                  !lines.contains(where: { $0.hasPrefix("%") }) else { throw CaptureFailure.incomplete }
        case .junosSet:
            guard !text.contains("ACCESS-DENIED"), lines.contains(where: { $0.hasPrefix("set ") }),
                  lines.allSatisfy({ $0.hasPrefix("set ") || $0.hasPrefix("deactivate ") || $0.hasPrefix("##") }) else {
                throw CaptureFailure.incomplete
            }
        }
        return .capture(data, source: target, at: Date())
    }

    private static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL else { throw Failure.unreadable }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        let byteLimit = maximumBytes
        guard info.st_size <= byteLimit, let data = try handle.read(upToCount: byteLimit + 1),
              data.count <= byteLimit else { throw Failure.limit }
        return data
    }

    static func compare(before: Data, after: Data, format: Format) throws -> Report {
        // Show only structural commands with tightly scoped arguments. Treat
        // other lines, including unknown vendor directives, as sensitive.
        let visiblePattern = switch format {
        case .ciscoIOS:
            #"^(?:interface [A-Za-z][A-Za-z0-9./:-]*|(?:ip(?:v6)? address|ip route) [0-9A-Fa-f.:/ ]+|(?:no )?shutdown|mtu [0-9]+)$"#
        case .junosSet:
            #"^set interfaces [A-Za-z][A-Za-z0-9./:-]* (?:disable|mtu [0-9]+|unit [0-9]+ family inet6? address [0-9A-Fa-f.:/]+)$"#
        }
        let visible = try NSRegularExpression(pattern: visiblePattern)
        let iosDelimitedMessage = #/(?i:banner\s+\S+|aaa\s+authentication\s+(?:banner|fail-message)|menu\s+\S+\s+(?:title|prompt)|vacant-message)\s+(\S.*)/#
        func split(_ data: Data) throws -> (lines: [(offset: Int, value: String, context: String)], omitted: [String]) {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.invalidText }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard lines.count <= 2_000 else { throw Failure.limit }
            var permitted: [(offset: Int, value: String, context: String)] = []
            var omitted: [String] = []
            var interface = ""
            var bannerDelimiter: String?
            for (offset, line) in lines.enumerated() {
                let value = line.trimmingCharacters(in: .whitespaces)
                if let delimiter = bannerDelimiter {
                    omitted.append(interface + "\n" + value)
                    if value.contains(delimiter) { bannerDelimiter = nil }
                    continue
                }
                if value.isEmpty { continue }
                if format == .ciscoIOS {
                    if line.first?.isWhitespace == false { interface = "" }
                    if let message = value.prefixMatch(of: iosDelimitedMessage),
                       let first = message.1.first {
                        let delimiter = message.1.hasPrefix("^C") ? "^C" : String(first)
                        if !message.1.dropFirst(delimiter.count).contains(delimiter) { bannerDelimiter = delimiter }
                        omitted.append(interface + "\n" + value)
                        continue
                    }
                }
                guard value.utf8.count <= 200,
                      visible.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil else {
                    omitted.append(interface + "\n" + value)
                    continue
                }
                if format == .ciscoIOS, value.hasPrefix("interface ") { interface = value }
                permitted.append((offset + 1, value, interface))
            }
            return (permitted, omitted)
        }
        let original = try split(before)
        let updated = try split(after)
        // Include interface context in IOS comparisons so moving the same
        // address between interfaces is still visible.
        let difference = updated.lines.map { $0.context + "\n" + $0.value }
            .difference(from: original.lines.map { $0.context + "\n" + $0.value })
        let changes = difference.map { change in
            switch change {
            case .remove(let offset, _, _):
                let line = original.lines[offset]
                return Change(kind: .removed, line: line.offset,
                              text: line.value == line.context || line.context.isEmpty ? line.value : "\(line.context) / \(line.value)")
            case .insert(let offset, _, _):
                let line = updated.lines[offset]
                return Change(kind: .added, line: line.offset,
                              text: line.value == line.context || line.context.isEmpty ? line.value : "\(line.context) / \(line.value)")
            }
        }
        return Report(beforeSHA256: SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(),
                      afterSHA256: SHA256.hash(data: after).map { String(format: "%02x", $0) }.joined(),
                      changes: changes, omittedLinesChanged: original.omitted != updated.omitted)
    }
}
