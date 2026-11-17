import Foundation

/// One IPv4/IPv6 socket visible to the account running the query.
public struct SocketEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let pid: Int
    public let user: String
    public let fileDescriptor: String
    public let family: String
    public let transport: String
    public let localAddress: String
    public let remoteAddress: String
    public let state: String

    public init(id: String = UUID().uuidString, command: String, pid: Int, user: String,
                fileDescriptor: String, family: String, transport: String,
                localAddress: String, remoteAddress: String, state: String) {
        self.id = id
        self.command = command
        self.pid = pid
        self.user = user
        self.fileDescriptor = fileDescriptor
        self.family = family
        self.transport = transport
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.state = state
    }
}

public enum SocketInventoryScope: String, Sendable {
    case all, connections, listeners

    fileprivate static func isUnclassifiedTCP(_ row: SocketEntry) -> Bool {
        guard row.transport.uppercased() == "TCP" else { return false }
        return !["CLOSED", "IDLE", "BOUND", "LISTEN", "LISTENING", "SYN_SENT", "SYN_RCVD", "SYN_RECV",
                 "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1", "FIN_WAIT_2", "FIN_WAIT1", "FIN_WAIT2",
                 "CLOSING", "LAST_ACK", "TIME_WAIT"].contains(row.state.uppercased())
    }

    fileprivate func includes(_ row: SocketEntry) -> Bool {
        if Self.isUnclassifiedTCP(row) { return self == .all }
        let isListener = ["LISTEN", "LISTENING"].contains(row.state.uppercased())
        switch self {
        case .all: return true
        case .connections: return !isListener
        case .listeners: return isListener
        }
    }
}

public enum SocketInventoryState: String, Sendable {
    case loaded, empty, partial, unavailable
}

/// Stable reasons; command text is evidence, never an error classifier.
public enum SocketInventoryIssue: String, Sendable {
    case missingExecutable, permissionDenied, busy, launchFailed, executionFailed
    case timedOut, cancelled, outputTruncated, cleanupIncomplete
    case unrecognizedOutput, unclassifiedTCPState, commandWarning
}

public struct SocketInventoryResult: Sendable {
    public let entries: [SocketEntry]
    public let issues: [SocketInventoryIssue]
    public let command: CommandResult
    public let unrecognizedRecordCount: Int
    /// Valid rows before scope/UDP filtering, including rows from a partial read.
    public let sourceEntryCount: Int

    /// Loaded/empty describe this query, not complete visibility of the system.
    /// A filtered partial result stays partial even when no rows match the filter.
    public var state: SocketInventoryState {
        if issues.isEmpty { return entries.isEmpty ? .empty : .loaded }
        return sourceEntryCount > 0 ? .partial : .unavailable
    }
}

public enum SocketInventory {
    // Use lsof's NUL-delimited field output. c is not the truncated COMMAND
    // column; u is numeric and avoids account-name lookup. -Ts requests TCP
    // state explicitly, independently of the selected T output field.
    static let arguments = ["-n", "-P", "-i", "-F0pcuftPnT", "-Ts"]

    public static func collect(scope: SocketInventoryScope = .all, includeUDP: Bool = true,
                               timeout: TimeInterval = 10,
                               cancellation: DiagnosticCancellation? = nil) async -> SocketInventoryResult {
        let command = await Shell.run("/usr/sbin/lsof", arguments, timeout: timeout,
                                      cancellation: cancellation)
        return interpret(command, scope: scope, includeUDP: includeUDP)
    }

    /// Blocking compatibility boundary; async callers should use collect().
    public static func collectSync(scope: SocketInventoryScope = .all, includeUDP: Bool = true,
                                   timeout: TimeInterval = 10,
                                   cancellation: DiagnosticCancellation? = nil) -> SocketInventoryResult {
        interpret(Shell.runSync("/usr/sbin/lsof", arguments, timeout: timeout,
                                cancellation: cancellation), scope: scope, includeUDP: includeUDP)
    }

    /// Legacy lossy projection. Existing callers keep their array API and
    /// empty-on-command-failure behavior; migrate to collect() for diagnostics.
    public static func list(includeUDP: Bool = true) -> [SocketEntry] {
        let result = collectSync(includeUDP: includeUDP)
        return result.command.succeeded ? result.entries : []
    }

    public static func listeners() -> [SocketEntry] {
        list().filter { ["LISTEN", "LISTENING"].contains($0.state.uppercased()) }
    }

    public static func connections() -> [SocketEntry] {
        list().filter { !["LISTEN", "LISTENING"].contains($0.state.uppercased()) }
    }

    static func interpret(_ command: CommandResult, scope: SocketInventoryScope = .all,
                          includeUDP: Bool = true) -> SocketInventoryResult {
        let parsed = parseFields(command.stdout)
        var issues: [SocketInventoryIssue] = []
        if command.cancelled { issues.append(.cancelled) }
        if command.timedOut { issues.append(.timedOut) }
        if let failure = command.failureCode {
            switch failure {
            case .missingExecutable: issues.append(.missingExecutable)
            case .permissionDenied: issues.append(.permissionDenied)
            case .busy: issues.append(.busy)
            case .launch: issues.append(.launchFailed)
            }
        }
        if !command.cleanupCompleted { issues.append(.cleanupIncomplete) }
        if command.stdoutTruncated || command.stderrTruncated { issues.append(.outputTruncated) }

        // lsof uses 1 both for no selected files and for errors. Only the fixed
        // query's completely silent, clean status-1 result counts as no matches.
        // An empty retained prefix is insufficient if the runtime observed data.
        let noMatches = command.status == 1 && command.stdout.isEmpty && command.stderr.isEmpty &&
            command.stdoutBytesObserved == 0 && command.stderrBytesObserved == 0 && issues.isEmpty &&
            command.processEvidence?.terminationSignal == nil
        if (command.status != 0 && !noMatches || command.processEvidence?.terminationSignal != nil) &&
            !command.cancelled && !command.timedOut && command.failureCode == nil {
            issues.append(.executionFailed)
        }
        if parsed.unrecognizedRecordCount > 0 { issues.append(.unrecognizedOutput) }
        if scope != .all && parsed.entries.contains(where: SocketInventoryScope.isUnclassifiedTCP) {
            issues.append(.unclassifiedTCPState)
        }
        if !command.stderr.isEmpty { issues.append(.commandWarning) }

        return SocketInventoryResult(
            entries: parsed.entries.filter { scope.includes($0) && (includeUDP || $0.transport.uppercased() != "UDP") },
            issues: issues, command: command, unrecognizedRecordCount: parsed.unrecognizedRecordCount,
            sourceEntryCount: parsed.entries.count
        )
    }

    private struct ParsedFields {
        var entries: [SocketEntry] = []
        var unrecognizedRecordCount = 0
    }

    private struct ProcessFields {
        let pid: Int
        let command: String
        let user: String
    }

    /// NUL terminates fields; LF terminates each process/file set. Incomplete
    /// sets are discarded, so an output cap cannot create a plausible last row.
    private static func parseFields(_ text: String) -> ParsedFields {
        var parsed = ParsedFields()
        var process: ProcessFields?
        var fields: [String] = []
        var bytes: [UInt8] = []
        var identities = Set<String>()

        func value(_ identifier: Character, in fields: [String]) -> String? {
            let matches = fields.filter { $0.first == identifier }
            guard matches.count == 1, !matches[0].dropFirst().isEmpty else { return nil }
            return String(matches[0].dropFirst())
        }

        func consumeSet() {
            guard let first = fields.first?.first, !fields.contains(where: \.isEmpty) else {
                process = nil
                parsed.unrecognizedRecordCount += 1
                return
            }
            switch first {
            case "p":
                // Always clear identity first: a malformed process must never
                // lend the preceding process's PID/command to subsequent files.
                process = nil
                guard !fields.contains(where: { ["f", "t", "P", "n", "T"].contains(String($0.prefix(1))) }),
                      let pidText = value("p", in: fields), let pid = Int32(pidText), pid > 0,
                      pidText.utf8.allSatisfy({ (48...57).contains($0) }),
                      let command = value("c", in: fields),
                      let uid = value("u", in: fields), UInt32(uid) != nil,
                      uid.utf8.allSatisfy({ (48...57).contains($0) }),
                      fields.filter({ $0.first == "L" }).count <= 1 else {
                    parsed.unrecognizedRecordCount += 1
                    return
                }
                process = ProcessFields(pid: Int(pid), command: command, user: value("L", in: fields) ?? uid)
            case "f":
                if fields.contains(where: { ["p", "c", "u", "L"].contains(String($0.prefix(1))) }) {
                    // A lost set separator may have joined a new process to
                    // this file. No later descriptor can safely reuse identity.
                    process = nil
                    parsed.unrecognizedRecordCount += 1
                    return
                }
                guard let process,
                      let descriptor = value("f", in: fields),
                      let family = value("t", in: fields), ["IPv4", "IPv6"].contains(family),
                      let transport = value("P", in: fields),
                      let name = value("n", in: fields),
                      let endpoints = endpoints(name) else {
                    parsed.unrecognizedRecordCount += 1
                    return
                }
                // T is a repeated field family (ST, QR, QS, ...). Only ST is
                // state; other members and unknown future fields are harmless.
                let states = fields.filter { $0.hasPrefix("TST=") }.map { String($0.dropFirst(4)) }
                guard states.count <= 1, states.first?.isEmpty != true else {
                    parsed.unrecognizedRecordCount += 1
                    return
                }
                let identity = "\(process.pid):\(descriptor):\(family):\(transport):\(name)"
                guard identities.insert(identity).inserted else {
                    parsed.unrecognizedRecordCount += 1
                    return
                }
                parsed.entries.append(SocketEntry(
                    id: identity, command: process.command, pid: process.pid, user: process.user,
                    fileDescriptor: descriptor, family: family, transport: transport,
                    localAddress: endpoints.local, remoteAddress: endpoints.remote, state: states.first ?? ""
                ))
            default:
                // Unknown set boundaries cannot establish which process owns a
                // following file. Ignore unknown fields only inside known sets.
                process = nil
                parsed.unrecognizedRecordCount += 1
            }
        }

        for byte in text.utf8 {
            if byte == 0 {
                fields.append(String(decoding: bytes, as: UTF8.self))
                bytes.removeAll(keepingCapacity: true)
            } else if byte == 10 && bytes.isEmpty {
                consumeSet()
                fields.removeAll(keepingCapacity: true)
            } else {
                bytes.append(byte)
            }
        }
        if !bytes.isEmpty || !fields.isEmpty { parsed.unrecognizedRecordCount += 1 }
        if !text.isEmpty && parsed.entries.isEmpty && parsed.unrecognizedRecordCount == 0 {
            // Process metadata without any selected file does not establish a
            // valid empty inventory for this fixed -i query.
            parsed.unrecognizedRecordCount = 1
        }
        return parsed
    }

    private static func endpoints(_ name: String) -> (local: String, remote: String)? {
        guard let arrow = name.range(of: "->") else { return (name, "") }
        let local = String(name[..<arrow.lowerBound])
        let remote = String(name[arrow.upperBound...])
        guard !local.isEmpty, !remote.isEmpty, !remote.contains("->") else { return nil }
        return (local, remote)
    }

    /// Compatibility parser for saved/default-column output. New queries use
    /// field mode exclusively; do not silently fall back to a column guess.
    public static func parse(_ text: String) -> [SocketEntry] {
        var rows: [SocketEntry] = []
        for line in text.split(whereSeparator: { $0.isNewline }).map(String.init) {
            if line.hasPrefix("COMMAND ") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 9, let pid = Int(columns[1]) else { continue }
            let type = columns[4]
            guard type == "IPv4" || type == "IPv6" else { continue }
            let name = columns[8...].joined(separator: " ")
            let state: String
            if let open = name.lastIndex(of: "("), name.last == ")" {
                state = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            } else { state = "" }
            let endpoint = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
            guard let addresses = endpoints(endpoint) else { continue }
            rows.append(SocketEntry(command: columns[0], pid: pid, user: columns[2], fileDescriptor: columns[3],
                                    family: type, transport: columns[7], localAddress: addresses.local,
                                    remoteAddress: addresses.remote, state: state))
        }
        return rows
    }
}
