import Foundation
import Darwin
@testable import NMCore

enum DiagnosticRuntimeEvidenceChecks {
    static func run() async throws {
        try checkLegacyDecoding()
        try checkEvidenceRoundTrips()
        try checkPersistenceAndExport()
        try checkRedactedExports()
        try checkTracerouteMapping()
        try await checkTCPServiceEvidence()
    }

    private static func checkLegacyDecoding() throws {
        // This is the previous on-disk shape, with no runtime-evidence key.
        let legacy = Data("""
        {
          "id": "715EA862-CF15-4A17-9623-A44098407EA4",
          "kind": "tcp",
          "status": "succeeded",
          "startedAt": "2026-10-01T00:00:00Z",
          "finishedAt": "2026-10-01T00:00:01Z",
          "parameters": { "port": "443" },
          "summary": "Port 443 open",
          "detail": "address=127.0.0.1",
          "latency": 0.001,
          "source": "TCP",
          "target": "127.0.0.1"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(DiagnosticRun.self, from: legacy)
        try check(run.evidence == nil && run.kind == .tcp && run.status == .succeeded,
                  "History written before runtime evidence was added still decodes")
        try check(run.target == "127.0.0.1" && run.parameters["port"] == "443" && run.latency == 0.001,
                  "Legacy history keeps its existing target, parameters and latency")
    }

    private static func checkEvidenceRoundTrips() throws {
        let values = [tcpEvidence(), DiagnosticRuntimeEvidence(process: processEvidence(state: .timedOut))]
        for value in values {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(DiagnosticRuntimeEvidence.self, from: encoded)
            try check(decoded == value,
                      "Runtime evidence round-trips all typed TCP and process metadata")

            let run = DiagnosticRun(kind: value.process == nil ? .tcp : .traceroute, status: .failed,
                                    startedAt: Date(timeIntervalSince1970: 1_720_000_000),
                                    parameters: ["fixture": "runtime evidence"], summary: "Fixture result",
                                    target: "127.0.0.1", evidence: value)
            let restored = try JSONDecoder().decode(DiagnosticRun.self, from: JSONEncoder().encode(run))
            try check(restored == run,
                      "A diagnostic history record round-trips its optional runtime evidence")
        }
    }

    private static func checkPersistenceAndExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NMDiagnosticEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("assets.json")
        let store = AssetStore(storageURL: storageURL)
        let tcp = tcpEvidence()
        let process = DiagnosticRuntimeEvidence(process: processEvidence(state: .cancelled))
        let tcpID = store.beginDiagnostic(kind: .tcp, target: "127.0.0.1", parameters: ["port": "443"])
        store.finishDiagnostic(id: tcpID, status: .failed, summary: "Connection refused",
                               detail: "reason=refused; stage=socketError", source: "TCP", evidence: tcp)
        let processID = store.beginDiagnostic(kind: .traceroute, target: "127.0.0.1")
        store.finishDiagnostic(id: processID, status: .cancelled, summary: "Traceroute cancelled",
                               detail: "1 127.0.0.1", source: "traceroute", evidence: process)
        try check(store.persistenceError == nil && store.diagnosticRuns.first(where: { $0.id == tcpID })?.evidence == tcp,
                  "Finishing a diagnostic stores its runtime evidence in the current asset history")

        let reloaded = AssetStore(storageURL: storageURL)
        try check(reloaded.recoveryError == nil && reloaded.persistenceError == nil,
                  "Asset history containing runtime evidence reloads without recovery")
        try check(reloaded.diagnosticRuns.first(where: { $0.id == tcpID })?.evidence == tcp &&
                  reloaded.diagnosticRuns.first(where: { $0.id == processID })?.evidence == process,
                  "AssetStore persists both TCP failure evidence and process cleanup evidence")
        try check(reloaded.diagnosticRuns.allSatisfy { $0.finishedAt != nil && $0.status != .running },
                  "Persisted evidence remains attached to completed diagnostic runs")

        let exported = try DiagnosticEvidenceExporter.json(runs: reloaded.diagnosticRuns, devices: reloaded.devices)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([DiagnosticEvidenceItem].self, from: exported)
        try check(items.first(where: { $0.id == tcpID })?.evidence == tcp &&
                  items.first(where: { $0.id == processID })?.evidence == process,
                  "Diagnostic JSON export preserves structured TCP and process evidence")
        guard let json = try JSONSerialization.jsonObject(with: exported) as? [[String: Any]],
              let tcpItem = json.first(where: { ($0["kind"] as? String) == "TCP" }),
              let runtime = tcpItem["evidence"] as? [String: Any],
              let failure = runtime["tcpFailure"] as? [String: Any] else {
            throw CheckFailure(description: "Diagnostic JSON export omitted the runtime evidence object")
        }
        try check(failure["code"] as? String == "refused" && failure["stage"] as? String == "socketError",
                  "Diagnostic JSON exposes stable reason and stage codes independently of display text")
    }

    private static func checkTracerouteMapping() throws {
        let cancelledEvidence = processEvidence(state: .cancelled)
        let partial = "1  127.0.0.1  0.100 ms\n2  * * *\n"
        let cancelled = CommandResult(status: -1, stdout: partial, stderr: "", cancelled: true,
                                      stdoutBytesObserved: cancelledEvidence.stdoutBytesObserved,
                                      stdoutTruncated: true, forcedTermination: true, cleanupCompleted: false,
                                      jobID: cancelledEvidence.jobID, jobState: .cancelled,
                                      processEvidence: cancelledEvidence)
        let cancelledResult = DiagnosticService.tracerouteResult(cancelled)
        try check(cancelledResult.status == .cancelled && cancelledResult.source == "traceroute",
                  "Traceroute maps typed cancellation to the cancelled diagnostic status")
        try check(cancelledResult.detail.contains("1  127.0.0.1") &&
                  cancelledResult.displayOutput?.contains("2  * * *") == true,
                  "A cancelled traceroute preserves the partial output for history and display")
        try check(cancelledResult.detail.contains(t("Output truncated")) &&
                  cancelledResult.detail.contains(t("Process cleanup incomplete")) &&
                  cancelledResult.evidence?.process == cancelledEvidence,
                  "Traceroute keeps truncation, forced-termination and cleanup evidence on cancellation")

        let timeoutEvidence = processEvidence(state: .timedOut)
        let timeout = CommandResult(status: -1, stdout: "", stderr: "traceroute: partial stderr evidence\n",
                                    timedOut: true, forcedTermination: true, cleanupCompleted: false,
                                    jobID: timeoutEvidence.jobID, jobState: .timedOut,
                                    processEvidence: timeoutEvidence)
        let timeoutResult = DiagnosticService.tracerouteResult(timeout)
        try check(timeoutResult.status == .timedOut &&
                  timeoutResult.detail.contains("partial stderr evidence") &&
                  timeoutResult.displayOutput?.contains("partial stderr evidence") == true,
                  "Traceroute preserves stderr output when an absolute deadline wins")
        try check(timeoutResult.evidence?.process == timeoutEvidence &&
                  timeoutResult.evidence?.process?.terminationSignal == SIGKILL &&
                  timeoutResult.evidence?.process?.cleanupErrors == ["owned-group-still-running"],
                  "Timed-out traceroute retains the original process cleanup and termination evidence")

        for (code, systemError, expectedStatus, expectedSummary) in [
            (CommandFailureCode.missingExecutable, ENOENT, DiagnosticRunStatus.failed, t("Traceroute is not installed")),
            (CommandFailureCode.permissionDenied, EACCES, DiagnosticRunStatus.permissionDenied, t("Permission denied"))
        ] {
            let launchEvidence = processEvidence(state: .failed, failure: code, launchErrno: systemError,
                                                 cleanupCompleted: true)
            let failed = CommandResult(status: -1, stdout: "", stderr: "launch fixture error",
                                       failureCode: code, jobID: launchEvidence.jobID, jobState: .failed,
                                       processEvidence: launchEvidence)
            let result = DiagnosticService.tracerouteResult(failed)
            try check(result.status == expectedStatus && result.summary == expectedSummary,
                      "Traceroute distinguishes a missing executable from a denied executable")
            try check(result.evidence?.process?.failureCode == code &&
                      result.evidence?.process?.launchErrno == systemError,
                      "Traceroute launch mapping preserves the typed reason and exact POSIX launch error")
        }

        let longOutput = String(repeating: "h", count: 8_100)
        let preview = DiagnosticService.tracerouteResult(CommandResult(status: 0, stdout: longOutput, stderr: ""))
        try check(preview.status == .succeeded && preview.detail.hasPrefix(String(longOutput.prefix(8_000))) &&
                  preview.detail.contains(t("Output truncated")) &&
                  preview.displayOutput?.hasPrefix(longOutput) == true,
                  "Traceroute bounds the history preview while preserving the full retained display output")
    }

    private static func checkRedactedExports() throws {
        let failureCanary = "tcp-failure-canary-9182"
        let attemptCanary = "tcp-attempt-canary-7234"
        let cleanupCanary = "process-cleanup-canary-4591"
        let summaryCanary = "summary-canary-1289"
        let detailCanary = "detail-canary-3826"
        let canaries = [failureCanary, attemptCanary, cleanupCanary, summaryCanary, detailCanary]
        let attempt = TCPProbeAttempt(address: "127.0.0.1", family: AF_INET, stage: .socketError,
                                      code: .refused, message: "remote password=\(attemptCanary)",
                                      connectErrno: EINPROGRESS, soError: ECONNREFUSED, elapsed: 0.01)
        let failure = TCPProbeFailure(code: .refused, stage: .socketError,
                                      message: "remote token=\(failureCanary)", address: "127.0.0.1",
                                      soError: ECONNREFUSED, family: AF_INET, elapsed: 0.01,
                                      attempts: [attempt])
        let process = ProcessExecutionEvidence(jobID: UUID(), operation: .traceroute, state: .cancelled,
            events: [ProcessJobEvent(state: .queued, elapsed: 0),
                     ProcessJobEvent(state: .cancelled, elapsed: 1)],
            exitStatus: nil, terminationSignal: SIGKILL, launchErrno: nil, failureCode: nil,
            stdoutBytesObserved: 100, stderrBytesObserved: 0,
            stdoutBytesRetained: 100, stderrBytesRetained: 0,
            stdoutTruncated: false, stderrTruncated: false, forcedTermination: true,
            cleanupCompleted: false,
            cleanupErrors: ["owned-group-still-running", "cleanup token=\(cleanupCanary)"])
        let tcpRun = DiagnosticRun(kind: .tcp, status: .failed,
            summary: "token=\(summaryCanary)", detail: "password=\(detailCanary)",
            target: "127.0.0.1", evidence: DiagnosticRuntimeEvidence(tcpFailure: failure, tcpAttempts: [attempt]))
        let processRun = DiagnosticRun(kind: .traceroute, status: .cancelled,
            summary: "token=\(summaryCanary)", detail: "password=\(detailCanary)",
            target: "127.0.0.1", evidence: DiagnosticRuntimeEvidence(process: process))
        let runs = [tcpRun, processRun]
        let items = DiagnosticEvidenceExporter.items(runs: runs, devices: [])
        let itemBytes = try JSONEncoder().encode(items)
        let itemText = String(decoding: itemBytes, as: UTF8.self)
        let json = String(decoding: try DiagnosticEvidenceExporter.json(runs: runs, devices: []), as: UTF8.self)
        let markdown = DiagnosticEvidenceExporter.markdown(runs: runs, devices: [])
        for canary in canaries {
            try check(!itemText.contains(canary),
                      "Evidence items redact imported secrets from summary, detail and nested runtime metadata")
            try check(!json.contains(canary),
                      "Diagnostic JSON cannot expose an imported runtime-evidence canary")
            try check(!markdown.contains(canary),
                      "Diagnostic Markdown cannot expose an imported runtime-evidence canary")
        }
        try check(itemText.contains("[REDACTED]") && json.contains("[REDACTED]") && markdown.contains("[REDACTED]"),
                  "Evidence exporters retain an explicit redaction marker for removed secret values")
        try check(items.first(where: { $0.id == tcpRun.id })?.evidence?.tcpFailure?.code == .refused &&
                  items.first(where: { $0.id == tcpRun.id })?.evidence?.tcpAttempts?.first?.soError == ECONNREFUSED,
                  "Redacting metadata preserves stable TCP reason codes and numeric evidence")
        try check(items.first(where: { $0.id == processRun.id })?.evidence?.process?.cleanupCompleted == false &&
                  items.first(where: { $0.id == processRun.id })?.evidence?.process?.terminationSignal == SIGKILL,
                  "Redacting metadata preserves process cleanup and termination facts")
        try check(markdown.contains("refused") && markdown.contains("socketError") &&
                  markdown.contains("cleanupErrors") && markdown.contains("owned-group-still-running"),
                  "Markdown export includes sanitized structured reason and process cleanup evidence")
    }

    private static func checkTCPServiceEvidence() async throws {
        let listener = try DiagnosticEvidenceTCPFixture()
        defer { listener.close() }
        let success = await DiagnosticService.runTCP(host: "127.0.0.1", port: Int(listener.port), timeout: 2)
        guard let attempts = success.evidence?.tcpAttempts, let attempt = attempts.first else {
            throw CheckFailure(description: "Successful TCP diagnostics must expose their connection-attempt evidence")
        }
        try check(success.status == .succeeded && success.source == "TCP" && success.evidence?.tcpFailure == nil,
                  "The shared diagnostic service retains success semantics for a real loopback TCP connection")
        try check(attempts.count == 1 && attempt.address == "127.0.0.1" && attempt.family == AF_INET && attempt.code == nil,
                  "A successful TCP diagnostic records its numeric address, family and successful attempt")
        try check(success.latency != nil && attempt.elapsed >= 0,
                  "A successful TCP diagnostic retains measured connection timing")
        listener.close()

        // Darwin can leave a connection to a bound, non-listening socket in
        // SYN_SENT. Closing a real listener produces the refusal used here,
        // matching the existing loopback TCP checks in main.swift.
        let refusedSocket = try DiagnosticEvidenceTCPFixture()
        defer { refusedSocket.close() }
        refusedSocket.close()
        let refused = await DiagnosticService.runTCP(host: "127.0.0.1", port: Int(refusedSocket.port), timeout: 2)
        let actual = "status=\(refused.status.rawValue); failure=\(String(describing: refused.evidence?.tcpFailure)); attempts=\(String(describing: refused.evidence?.tcpAttempts)); detail=\(refused.detail)"
        guard let failure = refused.evidence?.tcpFailure, let failedAttempts = refused.evidence?.tcpAttempts,
              let failedAttempt = failedAttempts.first else {
            throw CheckFailure(description: "Refused TCP diagnostics must retain their typed failure and attempt evidence (\(actual))")
        }
        try check(refused.status == .failed && failure.code == .refused && failure.address == "127.0.0.1",
                  "A real loopback refusal stays distinct from timeout in the shared diagnostic service (\(actual))")
        try check(failedAttempts.count == 1 && failedAttempt.code == .refused &&
                  (failedAttempt.errno == ECONNREFUSED || failedAttempt.soError == ECONNREFUSED),
                  "A refused TCP diagnostic preserves the refused attempt and its POSIX evidence (\(actual))")
        try check(failure.attempts == failedAttempts && refused.detail.contains("reason=refused") &&
                  refused.detail.contains("stage=\(failure.stage.rawValue)"),
                  "The service's structured failure and readable detail refer to the same refused attempt (\(actual))")
    }

    private static func tcpEvidence() -> DiagnosticRuntimeEvidence {
        let attempt = TCPProbeAttempt(address: "127.0.0.1", family: AF_INET, stage: .socketError,
                                      code: .refused, message: "Connection refused", connectErrno: EINPROGRESS,
                                      soError: ECONNREFUSED, readinessEvents: Int16(POLLOUT | POLLERR),
                                      readinessInterruptions: 1, elapsed: 0.012)
        let failure = TCPProbeFailure(code: .refused, stage: .socketError, message: "Connection refused",
                                      address: "127.0.0.1", soError: ECONNREFUSED, family: AF_INET,
                                      elapsed: 0.012, attempts: [attempt])
        return DiagnosticRuntimeEvidence(tcpFailure: failure, tcpAttempts: [attempt])
    }

    private static func processEvidence(state: ProcessJobState, failure: CommandFailureCode? = nil,
                                        launchErrno: Int32? = nil,
                                        cleanupCompleted: Bool = false) -> ProcessExecutionEvidence {
        ProcessExecutionEvidence(jobID: UUID(), operation: .traceroute, state: state,
            events: [ProcessJobEvent(state: .queued, elapsed: 0),
                     ProcessJobEvent(state: state, elapsed: 1.25)],
            exitStatus: nil, terminationSignal: failure == nil ? SIGKILL : nil,
            launchErrno: launchErrno, failureCode: failure,
            stdoutBytesObserved: 512, stderrBytesObserved: 32,
            stdoutBytesRetained: 128, stderrBytesRetained: 32,
            stdoutTruncated: true, stderrTruncated: false, forcedTermination: failure == nil,
            cleanupCompleted: cleanupCompleted,
            cleanupErrors: cleanupCompleted ? [] : ["owned-group-still-running"])
    }
}

private final class DiagnosticEvidenceTCPFixture {
    let port: UInt16
    private var descriptor: Int32

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw CheckFailure(description: "Could not create loopback diagnostic-evidence socket: \(errno)")
        }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CheckFailure(description: "Could not bind loopback diagnostic-evidence socket: \(code)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0, Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CheckFailure(description: "Could not prepare loopback diagnostic-evidence socket: \(code)")
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}
