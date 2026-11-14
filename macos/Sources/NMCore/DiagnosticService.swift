import Foundation

/// Replaces active protocol secrets before a diagnostic result can be stored
/// or exported. Evidence redaction remains a second, format-based boundary;
/// this exact-value pass covers bare secrets returned by a remote peer.
public enum DiagnosticSecretRedactor {
    public static func redact(_ value: String, secrets: [String?]) -> String {
        var redacted = value
        for secret in secrets.compactMap({ $0 }).filter({ $0.count >= 3 }) {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return redacted
    }
}

/// Result returned by the shared diagnostic execution layer.
public struct DiagnosticExecutionResult: Sendable {
    public let status: DiagnosticRunStatus
    public let summary: String
    public let detail: String
    public let latency: TimeInterval?
    public let source: String
    public let dnsRecords: [DNSRecord]
    public let displayOutput: String?
    public let evidence: DiagnosticRuntimeEvidence?

    public init(status: DiagnosticRunStatus, summary: String, detail: String = "", latency: TimeInterval? = nil,
                source: String = "NETworkManager", dnsRecords: [DNSRecord] = [], displayOutput: String? = nil,
                evidence: DiagnosticRuntimeEvidence? = nil) {
        self.status = status
        self.summary = summary
        self.detail = detail
        self.latency = latency
        self.source = source
        self.dnsRecords = dnsRecords
        self.displayOutput = displayOutput
        self.evidence = evidence
    }
}

/// Adapts the existing protocol clients to the persistent DiagnosticRun model.
/// Each operation is cancellable at the task boundary and returns a typed,
/// user-facing status instead of collapsing all failures into "offline".
public enum DiagnosticService {
    public static func runPing(host: String, timeout: TimeInterval = 2) async -> DiagnosticExecutionResult {
        await execute { cancellation in
            let reply = await Ping.once(host: host, timeout: timeout, cancellation: cancellation)
            let status: DiagnosticRunStatus
            switch reply.outcome {
            case .success: status = .succeeded
            case .timeout: status = .timedOut
            case .unreachable: status = .unreachable
            case .ttlExpired: status = .failed
            case .error(let message): status = classify(message: message)
            }
            return DiagnosticExecutionResult(status: status, summary: reply.outcome.displayName, detail: reply.source ?? "", latency: reply.rtt)
        }
    }

    public static func runDNS(host: String, recordType: DNSRecordType = .a, server: String? = nil,
                              serverPort: UInt16 = 53, timeout: TimeInterval = 3,
                              mode: DNSLookupMode? = nil) async -> DiagnosticExecutionResult {
        await executeBlocking { cancellation in
            do {
                let selectedMode = mode ?? (server == nil ? .system : .server)
                if selectedMode == .system, server != nil { throw DNSError.serverNotAllowedInSystemMode }
                let result: DNSQueryResult
                switch selectedMode {
                case .system:
                    result = try DNSClient.resolveSystem(name: host, type: recordType, timeout: timeout, cancellation: cancellation)
                case .server:
                    result = try DNSClient.query(name: host, type: recordType, server: server,
                                                 serverPort: serverPort, timeout: timeout, cancellation: cancellation)
                }
                let values = result.records.map(\.value).joined(separator: ", ")
                return DiagnosticExecutionResult(status: .succeeded, summary: tf("%d record(s)", result.records.count),
                                                 detail: tf("Mode: %@\nResolver: %@\nResponse: %@\nValues: %@",
                                                            result.mode.title, result.server, result.responseCode,
                                                            values.isEmpty ? t("No records") : values),
                                                 latency: result.elapsed, source: "DNS", dnsRecords: result.records,
                                                 displayOutput: tf("Mode: %@\nResolver: %@\nResponse: %@\nElapsed: %@",
                                                                   result.mode.title, result.server, result.responseCode,
                                                                   Fmt.duration(result.elapsed)))
            } catch {
                return DiagnosticExecutionResult(status: classify(error), summary: error.localizedDescription, source: "DNS")
            }
        }
    }

    public static func runTCP(host: String, port: Int, timeout: TimeInterval = 2) async -> DiagnosticExecutionResult {
        await executeBlocking(preserveTerminal: true) { cancellation in
            let result = TCPProbe.probe(host: host, port: port, timeout: timeout, cancellation: cancellation)
            switch result.status {
            case .open:
                return DiagnosticExecutionResult(status: .succeeded, summary: tf("Port %d open", port),
                                                 detail: "address=\(result.address ?? "n/a")", latency: result.latency, source: "TCP",
                                                 evidence: DiagnosticRuntimeEvidence(tcpAttempts: result.attempts))
            case .error:
                break
            case .closed, .noResponse, .filtered, .openFiltered:
                break
            }
            guard let failure = result.failure else {
                let message = result.message ?? t("TCP probe failed")
                return DiagnosticExecutionResult(status: .failed, summary: message, detail: message, source: "TCP")
            }
            let status: DiagnosticRunStatus
            switch failure.code {
            case .refused: status = .failed
            case .timedOut: status = .timedOut
            case .unreachable: status = .unreachable
            case .permissionDenied: status = .permissionDenied
            case .cancelled: status = .cancelled
            case .resolution, .execution: status = .failed
            }
            let summary = failure.code == .refused ? tf("Port %d closed", port) : failure.message
            let evidence = "reason=\(failure.code.rawValue); stage=\(failure.stage.rawValue); errno=\(failure.errno.map(String.init) ?? "n/a"); soError=\(failure.soError.map(String.init) ?? "n/a"); address=\(failure.address ?? "n/a")"
            return DiagnosticExecutionResult(status: status, summary: summary, detail: evidence,
                                             source: "TCP", evidence: DiagnosticRuntimeEvidence(tcpFailure: failure, tcpAttempts: result.attempts))
        }
    }

    public static func runTraceroute(host: String, maxHops: Int = 16, timeout: TimeInterval = 45) async -> DiagnosticExecutionResult {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Arguments remain separate argv entries. Reject option-shaped targets
        // before invoking a tool whose options can alter diagnostic behavior.
        guard !target.isEmpty, !target.hasPrefix("-"), target.utf8.count <= 253,
              target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !target.contains("/"), !target.contains("\\") else {
            return DiagnosticExecutionResult(status: .failed, summary: t("Invalid input"), source: "traceroute")
        }
        return await execute(preserveTerminal: true) { cancellation in
            let job = ProcessJobSpec(operation: .traceroute, targetScope: target,
                                     deadline: Date().addingTimeInterval(max(0, timeout)),
                                     maximumOutputBytesPerStream: 128_000, cancellation: cancellation)
            let result = await Shell.runTool("traceroute", ["-m", String(max(1, min(maxHops, 64))), target], job: job)
            return tracerouteResult(result)
        }
    }

    static func tracerouteResult(_ result: CommandResult) -> DiagnosticExecutionResult {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(output.prefix(8_000))
        let previewClipped = output.count > 8_000
        let outputNote = result.stdoutTruncated || result.stderrTruncated || previewClipped
            ? "\n" + t("Output truncated") : ""
        let cleanupNote = result.cleanupCompleted ? "" : "\n" + t("Process cleanup incomplete")
        let status: DiagnosticRunStatus
        let summary: String
        if result.cancelled { status = .cancelled; summary = t("Traceroute cancelled") }
        else if result.timedOut { status = .timedOut; summary = t("Traceroute timed out") }
        else if result.failureCode == .permissionDenied { status = .permissionDenied; summary = t("Permission denied") }
        else if result.failureCode == .missingExecutable { status = .failed; summary = t("Traceroute is not installed") }
        else if result.succeeded { status = .succeeded; summary = t("Traceroute completed") }
        else { status = .failed; summary = t("Traceroute failed") }
        return DiagnosticExecutionResult(status: status, summary: summary,
            detail: preview + outputNote + cleanupNote, source: "traceroute",
            displayOutput: output + outputNote + cleanupNote,
            evidence: DiagnosticRuntimeEvidence(process: result.processEvidence))
    }

    public static func runSNTP(host: String, timeout: TimeInterval = 3, port: UInt16 = 123) async -> DiagnosticExecutionResult {
        await executeBlocking { cancellation in
            do {
                let result = try SNTPClient.query(server: host, timeout: timeout, port: port, cancellation: cancellation)
                return DiagnosticExecutionResult(
                    status: .succeeded,
                    summary: tf("SNTP response from %@", result.server),
                    detail: tf("Address: %@\nServer time: %@\nOffset: %@\nDelay: %@\nStratum: %d", result.address, Fmt.dateTime(result.serverTime), Fmt.duration(result.offset), Fmt.duration(result.delay), result.stratum),
                    latency: result.roundTrip,
                    source: "SNTP",
                    displayOutput: tf("Server: %@\nAddress: %@\nServer time: %@\nOffset: %@\nDelay: %@\nStratum: %d", result.server, result.address, Fmt.dateTime(result.serverTime), Fmt.duration(result.offset), Fmt.duration(result.delay), result.stratum)
                )
            } catch {
                if let dnsError = error as? DNSError, case .timeout = dnsError {
                    return DiagnosticExecutionResult(status: .timedOut, summary: t("The SNTP server did not answer in time."), source: "SNTP")
                }
                return DiagnosticExecutionResult(status: classify(error), summary: error.localizedDescription, source: "SNTP")
            }
        }
    }

    public static func runWhois(host: String, server: String? = nil, timeout: TimeInterval = 10,
                                port: UInt16 = 43) async -> DiagnosticExecutionResult {
        await execute { cancellation in
            let result = await WhoisClient.query(host, server: server, timeout: timeout, port: port,
                                                 cancellation: cancellation)
            if cancellation.isCancelled {
                return DiagnosticExecutionResult(status: .cancelled, summary: t("Diagnostic cancelled"), source: "WHOIS")
            }
            if let error = result.error {
                return DiagnosticExecutionResult(status: classify(message: error), summary: error, source: "WHOIS")
            }
            return DiagnosticExecutionResult(
                status: .succeeded,
                summary: tf("WHOIS response received from %@", result.server),
                detail: tf("%d field(s) parsed", result.fields.count),
                latency: result.elapsed,
                source: "WHOIS",
                displayOutput: result.raw
            )
        }
    }

    public static func runSNMP(host: String, community: String = "public", port: Int = 161, timeout: TimeInterval = 2,
                               oid: String = "1.3.6.1.2.1.1.1.0", version: String = "v2c", authProtocol: String = "SHA-256",
                               securityLevel: String? = nil, credential: CredentialSecret? = nil) async -> DiagnosticExecutionResult {
        await executeBlocking { cancellation in
            do {
                var value: String
                let elapsed: TimeInterval
                var activeSecrets: [String?] = []
                if version == "v3" {
                    guard let username = credential?.username, let password = credential?.password else {
                        return DiagnosticExecutionResult(status: .failed, summary: t("SNMPv3 requires a credential with a username and authentication password."), source: "SNMP v3")
                    }
                    let configuredLevel = securityLevel == "authPriv" ? SNMPv3SecurityLevel.authPriv : .authNoPriv
                    let configuredProtocol: SNMPv3AuthProtocol = authProtocol == "SHA-1" ? .sha1 : .sha256
                    let configuration = SNMPv3Configuration(host: host, port: port, username: username, authProtocol: configuredProtocol,
                                                             securityLevel: configuredLevel, timeout: timeout, retries: 0)
                    let client = try SNMPv3Client(configuration: configuration, authenticationPassword: password,
                                                   privacyPassword: credential?.privacyPassword,
                                                   transport: SNMPv3UDPTransport(cancellation: cancellation))
                    let response = try client.get(oid)
                    value = response.varBinds.first?.value.displayValue ?? t("No value")
                    activeSecrets = [password, credential?.privacyPassword]
                    elapsed = response.elapsed
                } else {
                    let snmpVersion: SNMPVersion = version == "v1" ? .v1 : .v2c
                    let secretCommunity = credential?.password ?? community
                    let response = try SNMPClient(host: host, community: secretCommunity, version: snmpVersion, port: port, timeout: timeout)
                        .get(oid, cancellation: cancellation)
                    value = response.varBinds.first?.value.displayValue ?? t("No value")
                    activeSecrets = [secretCommunity]
                    elapsed = response.elapsed
                }
                value = DiagnosticSecretRedactor.redact(value, secrets: activeSecrets)
                return DiagnosticExecutionResult(status: .succeeded, summary: t("SNMP responded"), detail: value, latency: elapsed, source: "SNMP \(version)")
            } catch {
                return DiagnosticExecutionResult(status: classify(error), summary: error.localizedDescription, source: "SNMP \(version)")
            }
        }
    }

    private static func executeBlocking(preserveTerminal: Bool = false, _ operation: @escaping @Sendable (DiagnosticCancellation) -> DiagnosticExecutionResult) async -> DiagnosticExecutionResult {
        await execute(preserveTerminal: preserveTerminal) { cancellation in
            await runBlockingDiagnostic { operation(cancellation) }
        }
    }

    private static func execute(preserveTerminal: Bool = false, _ operation: @escaping @Sendable (DiagnosticCancellation) async -> DiagnosticExecutionResult) async -> DiagnosticExecutionResult {
        let cancellation = DiagnosticCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { await operation(cancellation) }.value
        } onCancel: {
            cancellation.cancel()
        }
        if !preserveTerminal && (cancellation.isCancelled || Task.isCancelled) {
            return DiagnosticExecutionResult(status: .cancelled, summary: t("Diagnostic cancelled"), detail: result.detail,
                latency: result.latency, source: result.source, dnsRecords: result.dnsRecords,
                displayOutput: result.displayOutput, evidence: result.evidence)
        }
        return result
    }

    private static func classify(_ error: Error) -> DiagnosticRunStatus {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        if let dnsError = error as? DNSError, case .timeout = dnsError { return .timedOut }
        if let dnsError = error as? DNSError, case .cancelled = dnsError { return .cancelled }
        if let snmpError = error as? SNMPError, case .timeout = snmpError { return .timedOut }
        if let snmpError = error as? SNMPError, case .cancelled = snmpError { return .cancelled }
        if let dnsError = error as? DNSError, case .cancelled = dnsError { return .cancelled }
        if let snmpError = error as? SNMPv3Error, case .timeout = snmpError { return .timedOut }
        if let posixError = error as? POSIXError { return classify(posixError.code) }
        return classify(message: error.localizedDescription)
    }

    private static func classify(message: String) -> DiagnosticRunStatus {
        let value = message.lowercased()
        if value.contains("timed out") || value.contains("timeout") || value.contains("in time") { return .timedOut }
        if value.contains("operation not permitted") || value.contains("permission denied") || value.contains("not authorized") { return .permissionDenied }
        if value.contains("host is down") || value.contains("host unreachable") || value.contains("network is unreachable") { return .unreachable }
        return .failed
    }

    private static func classify(_ code: POSIXErrorCode) -> DiagnosticRunStatus {
        switch code {
        case .ETIMEDOUT: return .timedOut
        case .EACCES, .EPERM: return .permissionDenied
        case .EHOSTUNREACH, .ENETUNREACH: return .unreachable
        default: return .failed
        }
    }
}
