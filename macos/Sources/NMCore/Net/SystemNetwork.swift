import Foundation

public enum SystemInventoryState: String, Sendable {
    case loaded, empty, partial, unavailable, limited
}

public enum SystemInventoryIssue: String, Sendable {
    case missingExecutable, permissionDenied, busy, launchFailed, executionFailed
    case timedOut, cancelled, outputTruncated, cleanupIncomplete, commandWarning
    case unrecognizedOutput, fieldsUnavailable
}

public struct SystemInventoryResult<Entry: Sendable>: Sendable {
    public let entries: [Entry]
    public let issues: [SystemInventoryIssue]
    public let command: CommandResult
    public let unrecognizedRecordCount: Int

    public var state: SystemInventoryState {
        if entries.isEmpty && issues.contains(.fieldsUnavailable) { return .limited }
        if issues.isEmpty { return entries.isEmpty ? .empty : .loaded }
        return entries.isEmpty ? .unavailable : .partial
    }

    public init(entries: [Entry], command: CommandResult,
                issues: [SystemInventoryIssue] = [], unrecognizedRecordCount: Int = 0) {
        self.entries = entries
        self.command = command
        self.unrecognizedRecordCount = max(0, unrecognizedRecordCount)

        var resolved = issues
        func add(_ issue: SystemInventoryIssue) {
            if !resolved.contains(issue) { resolved.append(issue) }
        }

        if command.cancelled { add(.cancelled) }
        if command.timedOut { add(.timedOut) }
        if let failure = command.failureCode {
            switch failure {
            case .missingExecutable: add(.missingExecutable)
            case .permissionDenied: add(.permissionDenied)
            case .busy: add(.busy)
            case .launch: add(.launchFailed)
            }
        }
        if !command.cleanupCompleted { add(.cleanupIncomplete) }
        if command.stdoutTruncated || command.stderrTruncated { add(.outputTruncated) }
        if command.status != 0 && !command.cancelled && !command.timedOut && command.failureCode == nil {
            add(.executionFailed)
        }
        if command.processEvidence?.terminationSignal != nil { add(.executionFailed) }
        if !command.stderr.isEmpty { add(.commandWarning) }
        if unrecognizedRecordCount > 0 { add(.unrecognizedOutput) }
        self.issues = resolved
    }
}

// MARK: - ARP / neighbor table

public struct NeighborEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let address: String
    public let macAddress: String
    public let interface: String
    public let state: String

    public init(id: String = UUID().uuidString, address: String, macAddress: String,
                interface: String, state: String) {
        self.id = id
        self.address = address
        self.macAddress = macAddress
        self.interface = interface
        self.state = state
    }
}

public enum NeighborTable {
    public static func collect(timeout: TimeInterval = 5,
                               cancellation: DiagnosticCancellation? = nil) async -> SystemInventoryResult<NeighborEntry> {
        let command = await Shell.run("/usr/sbin/arp", ["-an"], timeout: timeout, cancellation: cancellation)
        return interpret(command)
    }

    public static func collectSync(timeout: TimeInterval = 5,
                                   cancellation: DiagnosticCancellation? = nil) -> SystemInventoryResult<NeighborEntry> {
        interpret(Shell.runSync("/usr/sbin/arp", ["-an"], timeout: timeout, cancellation: cancellation))
    }

    public static func list() -> [NeighborEntry] {
        let result = collectSync()
        return result.command.succeeded ? result.entries : []
    }

    static func interpret(_ command: CommandResult) -> SystemInventoryResult<NeighborEntry> {
        let lines = command.stdout.split(whereSeparator: { $0.isNewline }).map(String.init)
        let entries = lines.compactMap(parseLine)
        let rejected = lines.filter { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parseLine(line) == nil
        }.count
        return SystemInventoryResult(entries: entries, command: command, unrecognizedRecordCount: rejected)
    }

    /// Parse output such as `? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0`.
    public static func parse(_ text: String) -> [NeighborEntry] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> NeighborEntry? {
        guard let left = line.firstIndex(of: "("),
              let right = line.firstIndex(of: ")"), right > left else { return nil }
        let address = String(line[line.index(after: left)..<right])
        let after = String(line[line.index(after: right)...])
        let tokens = after.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let at = tokens.firstIndex(of: "at"), at + 1 < tokens.count else { return nil }

        let mac = tokens[at + 1]
        let normalized = mac.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let isIncomplete = normalized.lowercased() == "incomplete" || tokens.contains("incomplete")
        let isMAC = mac.filter(\.isHexDigit).count == 12 &&
            mac.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" }
        guard isIncomplete || isMAC else { return nil }

        let interface = tokens.firstIndex(of: "on").map { $0 + 1 < tokens.count ? tokens[$0 + 1] : "" } ?? ""
        let state = tokens.contains("permanent") ? "Permanent" : (isIncomplete ? "Incomplete" : "Resolved")
        return NeighborEntry(address: address, macAddress: isIncomplete ? "" : Fmt.mac(mac), interface: interface, state: state)
    }
}

// MARK: - WiFi summary

public struct WiFiSummary: Identifiable, Sendable {
    public var id: String { "\(interface):\(ssid):\(bssid)" }
    public let interface: String
    public let ssid: String
    public let bssid: String
    public let channel: String
    public let security: String
    public let signal: String
    public let raw: String

    public init(interface: String, ssid: String, bssid: String, channel: String,
                security: String, signal: String, raw: String) {
        self.interface = interface
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.security = security
        self.signal = signal
        self.raw = raw
    }
}

public enum WiFiInventory {
    public static func collect(timeout: TimeInterval = 20,
                               cancellation: DiagnosticCancellation? = nil) async -> SystemInventoryResult<WiFiSummary> {
        let path = Shell.which("system_profiler") ?? "/usr/sbin/system_profiler"
        let command = await Shell.run(path, ["SPAirPortDataType", "-detailLevel", "mini"],
                                      timeout: timeout, cancellation: cancellation)
        return interpret(command)
    }

    public static func collectSync(timeout: TimeInterval = 20,
                                   cancellation: DiagnosticCancellation? = nil) -> SystemInventoryResult<WiFiSummary> {
        let path = Shell.which("system_profiler") ?? "/usr/sbin/system_profiler"
        return interpret(Shell.runSync(path, ["SPAirPortDataType", "-detailLevel", "mini"],
                                       timeout: timeout, cancellation: cancellation))
    }

    public static func current() -> [WiFiSummary] {
        let result = collectSync()
        return result.command.succeeded ? result.entries : []
    }

    static func interpret(_ command: CommandResult) -> SystemInventoryResult<WiFiSummary> {
        let entries = parse(command.stdout)
        let unrecognizedLines = entries.isEmpty && command.succeeded
            ? unrecognizedOutputLineCount(command.stdout)
            : 0
        return SystemInventoryResult(entries: entries, command: command,
                                      issues: unrecognizedLines > 0 ? [.unrecognizedOutput] : [],
                                      unrecognizedRecordCount: unrecognizedLines)
    }

    private static func unrecognizedOutputLineCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isNewline }).reduce(into: 0) { count, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            let candidate = line.hasSuffix(":") ? String(line.dropLast()) : line
            let lowercased = candidate.lowercased()
            let isSection = ["airport", "wi-fi", "wifi", "interfaces", "current network information"]
                .contains(lowercased)
            let isInterface = ["en", "awdl", "llw", "p2p"].contains { prefix in
                let suffix = candidate.dropFirst(prefix.count)
                return candidate.hasPrefix(prefix) && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
            }
            if !isSection && !isInterface { count += 1 }
        }
    }

    /// `system_profiler` is intentionally parsed conservatively. Unknown keys
    /// are retained in raw output so future macOS releases remain useful.
    public static func parse(_ text: String) -> [WiFiSummary] {
        var rows: [WiFiSummary] = []
        var interface = ""
        var ssid = ""
        var bssid = ""
        var channel = ""
        var security = ""
        var signal = ""
        var inCurrentNetwork = false

        func flush() {
            guard !ssid.isEmpty else { return }
            rows.append(WiFiSummary(interface: interface, ssid: ssid, bssid: bssid,
                                    channel: channel, security: security, signal: signal, raw: text))
            ssid = ""; bssid = ""; channel = ""; security = ""; signal = ""
        }

        for raw in text.split(whereSeparator: { $0.isNewline }).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") && !trimmed.contains(" ") && !trimmed.contains("(") {
                let candidate = String(trimmed.dropLast())
                if ["AirPort", "Wi-Fi", "WiFi", "Interfaces"].contains(candidate) { continue }
                if candidate.hasPrefix("en") || candidate.hasPrefix("awdl") || candidate.hasPrefix("llw") || candidate.hasPrefix("p2p") {
                    flush()
                    interface = candidate
                    continue
                }
                if inCurrentNetwork {
                    if !ssid.isEmpty { flush() }
                    ssid = candidate
                    inCurrentNetwork = false
                    continue
                }
                continue
            }
            if trimmed.hasSuffix(":") && trimmed.lowercased().hasPrefix("current network information") {
                inCurrentNetwork = true
                continue
            }
            if inCurrentNetwork && trimmed.hasSuffix(":") && !trimmed.contains("/") {
                let candidate = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && !candidate.lowercased().contains("network") {
                    if !ssid.isEmpty { flush() }
                    ssid = candidate
                    inCurrentNetwork = false
                    continue
                }
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "current network information":
                if !ssid.isEmpty { flush() }
                ssid = value
            case "bssid": bssid = value
            case "channel": channel = value
            case "security": security = value
            case "signal / noise": signal = value
            default: continue
            }
        }
        flush()
        return rows
    }
}

