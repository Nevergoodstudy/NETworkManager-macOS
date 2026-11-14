import Foundation
import Darwin
@testable import NMCore

/// Synthetic lsof records keep failure semantics independent of the host's
/// processes and permissions. The final check uses only an owned loopback socket.
enum SocketInventoryChecks {
    static func run() async throws {
        try checkFieldRecords()
        try checkValidEmptyResults()
        try checkFailureClassification()
        try checkPartialResults()
        try checkMalformedRecords()
        try await checkCollectionBoundary()
        try await checkOwnedListener()
    }

    private static func checkFieldRecords() throws {
        let text = process(pid: 42, command: "diagnostic helper", uid: "501", login: "operator") +
            file(fd: "6u", family: "IPv4", transport: "TCP", name: "127.0.0.1:8080", state: "LISTEN") +
            file(fd: "7u", family: "IPv6", transport: "TCP", name: "[::1]:5000->[::1]:443", state: "ESTABLISHED") +
            file(fd: "8u", family: "IPv4", transport: "UDP", name: "*:5353") +
            process(pid: 43, command: "诊断 helper", uid: "502") +
            file(fd: "4u", family: "IPv6", transport: "UDP", name: "[::1]:1234")
        let result = SocketInventory.interpret(command(text))
        try check(result.state == .loaded && result.issues.isEmpty && result.entries.count == 4,
                  "NUL-delimited process and file sets produce a loaded socket inventory")
        try check(result.sourceEntryCount == 4 && result.unrecognizedRecordCount == 0,
                  "A valid inventory reports its source row count without parse failures")
        let listener = result.entries[0]
        try check(listener.pid == 42 && listener.command == "diagnostic helper" && listener.user == "operator",
                  "Machine fields preserve process names with spaces and the explicit login name")
        try check(listener.fileDescriptor == "6u" && listener.family == "IPv4" &&
                  listener.transport == "TCP" && listener.localAddress == "127.0.0.1:8080" &&
                  listener.remoteAddress.isEmpty && listener.state == "LISTEN",
                  "A TCP listener preserves its descriptor, protocol, endpoint and state")
        let connection = result.entries[1]
        try check(connection.localAddress == "[::1]:5000" && connection.remoteAddress == "[::1]:443" &&
                  connection.state == "ESTABLISHED",
                  "An IPv6 connection separates its local and remote endpoint without splitting address colons")
        try check(result.entries[2].state.isEmpty && result.entries[2].transport == "UDP",
                  "UDP records remain valid without TCP state fields")
        try check(result.entries[3].command == "诊断 helper" && result.entries[3].user == "502",
                  "A numeric UID supplies user identity when lsof omits the login field")

        let listeners = SocketInventory.interpret(command(text), scope: .listeners)
        let connections = SocketInventory.interpret(command(text), scope: .connections)
        let tcpOnly = SocketInventory.interpret(command(text), includeUDP: false)
        try check(listeners.entries.count == 1 && listeners.entries[0].state == "LISTEN",
                  "The listener scope selects listening TCP sockets")
        try check(connections.entries.count == 3 && connections.entries.allSatisfy { $0.state != "LISTEN" },
                  "The connections scope retains UDP and non-listening TCP sockets")
        try check(tcpOnly.entries.count == 2 && tcpOnly.entries.allSatisfy { $0.transport == "TCP" },
                  "The compatibility UDP filter excludes only UDP records")
        try check(result.entries.map(\.id) == SocketInventory.interpret(command(text)).entries.map(\.id),
                  "Repeated snapshots retain stable socket row identities")

        let unclassifiedStates: [String?] = [nil, "FUTURE_STATE"]
        for state in unclassifiedStates {
            let unclassified = command(process(pid: 44) +
                file(fd: "4u", family: "IPv4", transport: "TCP", name: "127.0.0.1:4400", state: state))
            let all = SocketInventory.interpret(unclassified)
            try check(all.state == .loaded && all.issues.isEmpty && all.entries.first?.state == (state ?? ""),
                      "The all-sockets view preserves a TCP row whose state cannot be classified")
            for scope in [SocketInventoryScope.connections, .listeners] {
                let scoped = SocketInventory.interpret(unclassified, scope: scope)
                try check(scoped.state == .partial && scoped.entries.isEmpty && scoped.sourceEntryCount == 1 &&
                          scoped.issues.contains(.unclassifiedTCPState),
                          "A missing or future TCP state cannot establish membership in a connection/listener scope")
            }
        }

        let futureFields = process(pid: 99) +
            fields(["f9u", "tIPv4", "PTCP", "n127.0.0.1:9000", "TQR=0", "TST=LISTEN", "TQS=0", "zfuture"])
        let futureResult = SocketInventory.interpret(command(futureFields))
        try check(futureResult.state == .loaded && futureResult.issues.isEmpty &&
                  futureResult.entries.first?.state == "LISTEN",
                  "Unknown future fields and other TCP information do not erase a recognized state")
    }

    private static func checkValidEmptyResults() throws {
        for status in [Int32(0), Int32(1)] {
            let result = SocketInventory.interpret(CommandResult(status: status, stdout: "", stderr: ""))
            try check(result.state == .empty && result.entries.isEmpty && result.issues.isEmpty,
                      "A clean lsof exit \(status) with no output is an empty visible inventory")
            try check(result.command.status == status,
                      "Inventory interpretation preserves the original command exit status")
        }
        let onlyUDP = process(pid: 42) + file(fd: "4u", family: "IPv4", transport: "UDP", name: "*:5353")
        let noListeners = SocketInventory.interpret(command(onlyUDP), scope: .listeners)
        let noTCP = SocketInventory.interpret(command(onlyUDP), includeUDP: false)
        try check(noListeners.state == .empty && noListeners.sourceEntryCount == 1,
                  "An empty listener filter is distinguished from a source with no rows")
        try check(noTCP.state == .empty && noTCP.entries.isEmpty && noTCP.issues.isEmpty,
                  "Filtering every valid row does not turn a successful inventory into a failure")
    }

    private static func checkFailureClassification() throws {
        let launchCases: [(CommandFailureCode, SocketInventoryIssue)] = [
            (.missingExecutable, .missingExecutable), (.permissionDenied, .permissionDenied),
            (.busy, .busy), (.launch, .launchFailed)
        ]
        for (code, expected) in launchCases {
            let result = SocketInventory.interpret(CommandResult(status: -1, stdout: "", stderr: "launch evidence",
                                                                 failureCode: code))
            try check(result.state == .unavailable && result.issues.contains(expected),
                      "Inventory retains the typed launch failure \(code.rawValue)")
            try check(result.command.failureCode == code,
                      "Inventory keeps command launch evidence beside its stable issue code")
        }

        let nonzero = SocketInventory.interpret(CommandResult(status: 23, stdout: "", stderr: "command failed"))
        try check(nonzero.state == .unavailable && nonzero.issues.contains(.executionFailed),
                  "An ordinary nonzero exit is an execution failure rather than an empty inventory")
        let permissionText = SocketInventory.interpret(CommandResult(status: 1, stdout: "", stderr: "Operation not permitted"))
        try check(permissionText.issues.contains(.executionFailed) && permissionText.issues.contains(.commandWarning) &&
                  !permissionText.issues.contains(.permissionDenied) && !permissionText.issues.contains(.missingExecutable),
                  "English stderr alone does not establish a permission denial or a missing dependency")

        let warning = SocketInventory.interpret(CommandResult(status: 0, stdout: "", stderr: "some processes were skipped"))
        try check(warning.state == .unavailable && warning.issues.contains(.commandWarning),
                  "A zero exit with only a warning is not presented as a valid empty inventory")
        let whitespace = SocketInventory.interpret(CommandResult(status: 1, stdout: "", stderr: "\n"))
        try check(whitespace.state == .unavailable && whitespace.issues.contains(.executionFailed),
                  "The no-match exception requires both streams to be truly empty")

        let timedOut = SocketInventory.interpret(CommandResult(status: -1, stdout: "", stderr: "", timedOut: true))
        let cancelled = SocketInventory.interpret(CommandResult(status: -1, stdout: "", stderr: "", cancelled: true))
        try check(timedOut.state == .unavailable && timedOut.issues.contains(.timedOut),
                  "An empty timed-out command is not a valid empty inventory")
        try check(cancelled.state == .unavailable && cancelled.issues.contains(.cancelled),
                  "An empty cancelled command retains cancellation")
        let incompleteCleanup = SocketInventory.interpret(CommandResult(status: 1, stdout: "", stderr: "", cleanupCompleted: false))
        try check(incompleteCleanup.state == .unavailable && incompleteCleanup.issues.contains(.cleanupIncomplete),
                  "The no-match exception cannot hide incomplete process cleanup")
        let truncatedEmpty = SocketInventory.interpret(CommandResult(status: 1, stdout: "", stderr: "", stdoutTruncated: true))
        try check(truncatedEmpty.state == .unavailable && truncatedEmpty.issues.contains(.outputTruncated),
                  "An empty retained prefix with discarded output cannot prove no visible matches")
        let observedEmpty = SocketInventory.interpret(CommandResult(status: 1, stdout: "", stderr: "", stdoutBytesObserved: 12))
        try check(observedEmpty.state == .unavailable && observedEmpty.issues.contains(.executionFailed),
                  "Observed command output prevents the silent no-match exception even when nothing was retained")
    }

    private static func checkPartialResults() throws {
        let row = process(pid: 42) + file(fd: "6u", family: "IPv4", transport: "TCP", name: "127.0.0.1:8080", state: "LISTEN")
        let cases: [(CommandResult, SocketInventoryIssue)] = [
            (CommandResult(status: 1, stdout: row, stderr: ""), .executionFailed),
            (CommandResult(status: 0, stdout: row, stderr: "warning"), .commandWarning),
            (CommandResult(status: -1, stdout: row, stderr: "", timedOut: true), .timedOut),
            (CommandResult(status: -1, stdout: row, stderr: "", cancelled: true), .cancelled),
            (CommandResult(status: 0, stdout: row, stderr: "", stdoutTruncated: true), .outputTruncated),
            (CommandResult(status: 0, stdout: row, stderr: "", stderrTruncated: true), .outputTruncated),
            (CommandResult(status: 0, stdout: row, stderr: "", cleanupCompleted: false), .cleanupIncomplete)
        ]
        for (command, expected) in cases {
            let result = SocketInventory.interpret(command)
            try check(result.state == .partial && result.entries.count == 1 && result.issues.contains(expected),
                      "A \(expected.rawValue) result retains complete socket rows and marks them partial")
        }
        let filteredPartial = SocketInventory.interpret(CommandResult(status: 0, stdout: row, stderr: "warning"), scope: .connections)
        try check(filteredPartial.state == .partial && filteredPartial.entries.isEmpty && filteredPartial.sourceEntryCount == 1,
                  "Filtering partial source rows cannot produce an apparently complete empty result")

        let jobID = UUID()
        let evidence = CommandResult(status: 137, stdout: row, stderr: "warning", stdoutBytesObserved: 90_000,
                                     stderrBytesObserved: 12_000, stdoutTruncated: true, stderrTruncated: true,
                                     forcedTermination: true, cleanupCompleted: false, jobID: jobID, jobState: .failed)
        let result = SocketInventory.interpret(evidence)
        try check(result.command.jobID == jobID && result.command.status == 137 &&
                  result.command.stdoutBytesObserved == 90_000 && result.command.stderrBytesObserved == 12_000 &&
                  result.command.stdoutTruncated && result.command.stderrTruncated && result.command.forcedTermination &&
                  !result.command.cleanupCompleted && result.command.stderr == "warning",
                  "Partial inventories retain original output, job, byte-limit and cleanup evidence")
    }

    private static func checkMalformedRecords() throws {
        let validProcess = process(pid: 42)
        let validFile = file(fd: "6u", family: "IPv4", transport: "TCP", name: "127.0.0.1:8080", state: "LISTEN")
        let malformed: [String] = [
            "not lsof output",
            "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n",
            validFile,
            fields(["pbad", "cbroken", "u501"]) + validFile,
            fields(["p43", "u501"]) + validFile,
            fields(["p43", "cbroken"]) + validFile,
            validProcess + fields(["f9u", "tIPv4", "PTCP"]),
            validProcess + fields(["f9u", "tIPv4", "tIPv6", "PTCP", "n127.0.0.1:9"]),
            validProcess + fields(["f9u", "tIPv4", "PTCP", "n127.0.0.1:9", "n127.0.0.1:10"]),
            validProcess + fields(["f9u", "tIPv4", "PTCP", "n127.0.0.1:9", "TST=LISTEN", "TST=ESTABLISHED"]),
            validProcess + "f9u\0tIPv4\0PTCP\0n127.0.0.1:9",
            validProcess + "f9u\0tIPv4\0PTCP\0n127.0.0.1:9\0"
        ]
        for text in malformed {
            let result = SocketInventory.interpret(command(text))
            try check(result.state == .unavailable && result.entries.isEmpty &&
                      result.issues.contains(.unrecognizedOutput) && result.unrecognizedRecordCount > 0,
                      "Malformed or unfinished machine records are not reported as a successful empty inventory")
        }

        let invalidNewProcess = fields(["pnot-a-pid", "cbroken", "u502"]) +
            file(fd: "99u", family: "IPv4", transport: "UDP", name: "*:9999")
        let mixed = SocketInventory.interpret(command(validProcess + validFile + invalidNewProcess))
        try check(mixed.state == .partial && mixed.entries.count == 1 && mixed.entries[0].pid == 42 &&
                  mixed.entries.allSatisfy { $0.fileDescriptor != "99u" } && mixed.issues.contains(.unrecognizedOutput),
                  "A malformed process boundary cannot attach later descriptors to the preceding valid PID")
        let joinedProcess = fields(["f8u", "tIPv4", "PTCP", "n127.0.0.1:8", "p43", "cnew process", "u502"])
        let nextFile = file(fd: "7u", family: "IPv4", transport: "TCP", name: "127.0.0.1:7000", state: "LISTEN")
        let lostBoundary = SocketInventory.interpret(command(validProcess + validFile + joinedProcess + nextFile))
        try check(lostBoundary.state == .partial && lostBoundary.entries.count == 1 &&
                  lostBoundary.entries.first?.fileDescriptor == "6u" && lostBoundary.issues.contains(.unrecognizedOutput),
                  "A process field inside a malformed file set clears ownership before following descriptors")

        let badFile = fields(["f8u", "tIPv4", "tIPv6", "PTCP", "n127.0.0.1:8"])
        let recoveredFile = SocketInventory.interpret(command(validProcess + validFile + badFile + nextFile))
        try check(recoveredFile.state == .partial && recoveredFile.entries.count == 2 &&
                  recoveredFile.entries.allSatisfy { $0.pid == 42 } &&
                  recoveredFile.entries.contains { $0.fileDescriptor == "7u" },
                  "A malformed descriptor without a process boundary does not discard later valid files for the same PID")
        let truncatedTail = SocketInventory.interpret(CommandResult(status: 0,
            stdout: validProcess + validFile + "f7u\0tIPv6\0PTCP\0n[::1]:443", stderr: "", stdoutTruncated: true))
        try check(truncatedTail.state == .partial && truncatedTail.entries.count == 1 &&
                  truncatedTail.issues.contains(.outputTruncated) && truncatedTail.issues.contains(.unrecognizedOutput),
                  "Truncation preserves earlier complete sets while discarding the unfinished final descriptor")
    }

    private static func checkCollectionBoundary() async throws {
        let cancellation = DiagnosticCancellation()
        cancellation.cancel()
        let cancelled = await SocketInventory.collect(cancellation: cancellation)
        try check(cancelled.state == .unavailable && cancelled.issues.contains(.cancelled) &&
                  cancelled.entries.isEmpty && cancelled.command.cancelled,
                  "The asynchronous inventory boundary honors cancellation before launching lsof")
        let expired = await SocketInventory.collect(timeout: 0)
        try check(expired.state == .unavailable && expired.issues.contains(.timedOut) &&
                  expired.entries.isEmpty && expired.command.timedOut,
                  "An expired inventory budget is retained as a timeout rather than an empty list")
    }

    private static func checkOwnedListener() async throws {
        let listener = try LoopbackTCPListener()
        let result = await SocketInventory.collect(scope: .listeners)
        try check(!result.command.timedOut && !result.command.cancelled && result.command.failureCode == nil,
                  "The system lsof adapter launches and finishes its owned loopback inventory query")
        try check(result.entries.contains {
            $0.pid == Int(getpid()) && $0.transport == "TCP" && $0.state == "LISTEN" &&
            $0.localAddress.hasSuffix(":\(listener.port)")
        }, "The real machine-output adapter finds an owned IPv4 loopback listener")
        listener.closeListener()
    }

    private static func command(_ stdout: String) -> CommandResult {
        CommandResult(status: 0, stdout: stdout, stderr: "")
    }

    private static func fields(_ values: [String]) -> String {
        values.joined(separator: "\0") + "\0\n"
    }

    private static func process(pid: Int, command: String = "fixture", uid: String = "501", login: String? = nil) -> String {
        var values = ["p\(pid)", "c\(command)", "u\(uid)"]
        if let login { values.append("L\(login)") }
        return fields(values)
    }

    private static func file(fd: String, family: String, transport: String, name: String, state: String? = nil) -> String {
        var values = ["f\(fd)", "t\(family)", "P\(transport)", "n\(name)"]
        if let state { values.append("TST=\(state)") }
        return fields(values)
    }
}
