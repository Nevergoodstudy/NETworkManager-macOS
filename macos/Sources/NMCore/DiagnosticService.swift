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

    public init(status: DiagnosticRunStatus, summary: String, detail: String = "", latency: TimeInterval? = nil,
                source: String = "NETworkManager", dnsRecords: [DNSRecord] = [], displayOutput: String? = nil) {
        self.status = status
        self.summary = summary
        self.detail = detail
        self.latency = latency
        self.source = source
        self.dnsRecords = dnsRecords
        self.displayOutput = displayOutput
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

    public static func runDNS(host: String, recordType: DNSRecordType = .a, server: String? = nil, serverPort: UInt16 = 53, timeout: TimeInterval = 3) async -> DiagnosticExecutionResult {
        await execute { cancellation in
            do {
                let result = try DNSClient.query(name: host, type: recordType, server: server, serverPort: serverPort, timeout: timeout, cancellation: cancellation)
                let values = result.records.map(\.value).joined(separator: ", ")
                return DiagnosticExecutionResult(status: .succeeded, summary: tf("%d record(s)", result.records.count),
                                                 detail: tf("Server: %@\nResponse: %@\nValues: %@", result.server, result.responseCode, values.isEmpty ? t("No records") : values),
                                                 latency: result.elapsed, source: "DNS", dnsRecords: result.records,
                                                 displayOutput: tf("Server: %@\nResponse: %@\nElapsed: %@", result.server, result.responseCode, Fmt.duration(result.elapsed)))
            } catch {
                return DiagnosticExecutionResult(status: classify(error), summary: error.localizedDescription, source: "DNS")
            }
        }
    }

    public static func runTCP(host: String, port: Int, timeout: TimeInterval = 2) async -> DiagnosticExecutionResult {
        await execute { cancellation in
            let result = TCPProbe.probe(host: host, port: port, timeout: timeout, cancellation: cancellation)
            switch result.status {
            case .open:
                return DiagnosticExecutionResult(status: .succeeded, summary: tf("Port %d open", port), latency: result.latency, source: "TCP")
            case .closed, .filtered, .openFiltered:
                return DiagnosticExecutionResult(status: .failed, summary: tf("Port %d %@", port, result.status.rawValue), source: "TCP")
            case .error:
                let message = result.message ?? t("TCP probe failed")
                return DiagnosticExecutionResult(status: classify(message: message), summary: message, source: "TCP")
            }
        }
    }

    public static func runTraceroute(host: String, maxHops: Int = 16, timeout: TimeInterval = 45) async -> DiagnosticExecutionResult {
        await execute { cancellation in
        let result = await Shell.runTool("traceroute", ["-m", String(max(1, min(maxHops, 64))), host], timeout: timeout, cancellation: cancellation)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.cancelled {
            return DiagnosticExecutionResult(status: .cancelled, summary: t("Traceroute cancelled"), detail: String(output.prefix(8_000)), source: "traceroute")
        }
        if result.succeeded {
            return DiagnosticExecutionResult(status: .succeeded, summary: t("Traceroute completed"), detail: String(output.prefix(8_000)), source: "traceroute")
        }
        return DiagnosticExecutionResult(status: result.timedOut ? .timedOut : .failed, summary: result.timedOut ? t("Traceroute timed out") : t("Traceroute failed"), detail: String(output.prefix(8_000)), source: "traceroute")
        }
    }

    public static func runSNTP(host: String, timeout: TimeInterval = 3, port: UInt16 = 123) async -> DiagnosticExecutionResult {
        await execute { cancellation in
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
        await execute { cancellation in
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

    private static func execute(_ operation: @escaping @Sendable (DiagnosticCancellation) async -> DiagnosticExecutionResult) async -> DiagnosticExecutionResult {
        let cancellation = DiagnosticCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { await operation(cancellation) }.value
        } onCancel: {
            cancellation.cancel()
        }
        if cancellation.isCancelled || Task.isCancelled {
            return DiagnosticExecutionResult(status: .cancelled, summary: t("Diagnostic cancelled"), source: result.source)
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
