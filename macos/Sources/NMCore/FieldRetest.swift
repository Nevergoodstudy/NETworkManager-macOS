import Foundation
import Darwin

/// Each method reports its own requested stage; transport prerequisites are not separate successful checks.
public enum FieldRetestMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemDNS
    case tcp
    case specifiedDNS
    case directTCP
    case tls
    case http

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemDNS: return "System DNS lookup"
        case .tcp: return "TCP service connection"
        case .specifiedDNS: return "Specified DNS control"
        case .directTCP: return "Direct-IP TCP control"
        case .tls: return "TLS handshake and trust"
        case .http: return "HTTP HEAD response"
        }
    }

    public var layer: FieldRetestLayer {
        switch self {
        case .systemDNS, .specifiedDNS: return .dns
        case .tcp, .directTCP: return .tcp
        case .tls: return .tls
        case .http: return .http
        }
    }

    public var isControlTest: Bool {
        switch self {
        case .specifiedDNS, .directTCP: return true
        case .systemDNS, .tcp, .tls, .http: return false
        }
    }
}

public enum FieldRetestStatus: String, Codable, CaseIterable, Sendable {
    case pending, running, succeeded, failed, interrupted, cancelled, timedOut, permissionDenied, unreachable, blocked

    public var title: String {
        switch self {
        case .pending: return "Not started"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .permissionDenied: return "Permission denied"
        case .unreachable: return "Unreachable"
        case .blocked: return "Blocked before execution"
        }
    }
}

public enum FieldRetestComparisonState: String, Codable, CaseIterable, Sendable {
    case notEvaluated
    case comparable
    case notComparable

    public var title: String {
        switch self {
        case .notEvaluated: return "Comparison not evaluated"
        case .comparable: return "Comparable with baseline"
        case .notComparable: return "Not directly comparable"
        }
    }
}

public enum FieldRetestLayer: String, Codable, CaseIterable, Sendable {
    case dns, tcp, tls, http
}

public struct FieldRetestAuthorization: Codable, Equatable, Sendable {
    public var reference = ""
    public var confirmedBy = ""
    public var confirmedAt = Date()
    public var windowStart = Date()
    public var windowEnd = Date().addingTimeInterval(3_600)
    public var confirmed = false

    public init(reference: String = "", confirmedBy: String = "", confirmedAt: Date = Date(),
                windowStart: Date = Date(), windowEnd: Date = Date().addingTimeInterval(3_600),
                confirmed: Bool = false) {
        self.reference = reference
        self.confirmedBy = confirmedBy
        self.confirmedAt = confirmedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.confirmed = confirmed
    }
}

public struct FieldRetestPreparation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let incidentID: UUID
    public let incidentTitle: String
    public let revisionID: UUID?
    public let target: String

    public init(incident: FieldIncident) {
        id = UUID()
        incidentID = incident.id
        incidentTitle = incident.title
        revisionID = incident.baselineRevisionID
        target = incident.asset?.address ?? ""
    }
}

public struct FieldRetestRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var check: FieldProjectCheck
    public var acceptanceItemID: UUID?
    public var baselineRevisionID: UUID?
    public var baselineEvidenceID: UUID?
    public var target: String
    public var method: FieldRetestMethod
    public var dnsRecordType: DNSRecordType
    public var dnsServer: String?
    public var dnsServerPort: UInt16
    public var tcpPort: Int?
    public var httpScheme: String?
    public var httpPath: String?
    public var authorization: FieldRetestAuthorization
    public var networkContext: String
    public var baselineNetworkContext: String
    public var baselineAddressFamily: FieldProjectAddressFamily?
    public var baselineTarget: String?
    public var baselineMethod: FieldRetestMethod?

    public init(id: UUID = UUID(), check: FieldProjectCheck = .retest, acceptanceItemID: UUID? = nil,
                baselineRevisionID: UUID? = nil, baselineEvidenceID: UUID? = nil, target: String = "",
                method: FieldRetestMethod = .systemDNS, dnsRecordType: DNSRecordType = .a,
                dnsServer: String? = nil, dnsServerPort: UInt16 = 53, tcpPort: Int? = nil,
                authorization: FieldRetestAuthorization = FieldRetestAuthorization(),
                networkContext: String = "", baselineNetworkContext: String = "",
                baselineAddressFamily: FieldProjectAddressFamily? = nil,
                baselineTarget: String? = nil, baselineMethod: FieldRetestMethod? = nil,
                httpScheme: String? = nil, httpPath: String? = nil) {
        self.id = id
        self.check = check
        self.acceptanceItemID = acceptanceItemID
        self.baselineRevisionID = baselineRevisionID
        self.baselineEvidenceID = baselineEvidenceID
        self.target = target
        self.method = method
        self.dnsRecordType = dnsRecordType
        self.dnsServer = dnsServer
        self.dnsServerPort = dnsServerPort
        self.tcpPort = tcpPort
        self.httpScheme = httpScheme
        self.httpPath = httpPath
        self.authorization = authorization
        self.networkContext = networkContext
        self.baselineNetworkContext = baselineNetworkContext
        self.baselineAddressFamily = baselineAddressFamily
        self.baselineTarget = baselineTarget
        self.baselineMethod = baselineMethod
    }

    public var normalizedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    public mutating func prepare(for incident: FieldRetestPreparation) {
        self = FieldRetestRequest(baselineRevisionID: incident.revisionID, target: incident.target)
    }

    public mutating func selectMethod(_ method: FieldRetestMethod) {
        self.method = method
        if method != .http { httpScheme = nil; httpPath = nil }
        switch method {
        case .systemDNS:
            dnsServer = nil
            tcpPort = nil
        case .specifiedDNS:
            tcpPort = nil
        case .tcp, .directTCP, .tls:
            dnsServer = nil
            tcpPort = tcpPort ?? 443
        case .http:
            dnsServer = nil
            httpScheme = httpScheme ?? "https"
            httpPath = httpPath ?? "/"
            tcpPort = tcpPort ?? 443
        }
    }

    public func validate(now: Date = Date()) throws {
        try validateFields()
        guard authorization.confirmedAt <= now else {
            throw FieldRetestValidationError.authorizationRequired
        }
        guard authorization.windowStart <= now, now <= authorization.windowEnd else {
            throw FieldRetestValidationError.outsideWindow
        }
    }

    fileprivate func validateStored() throws {
        try validateFields()
    }

    private func validateFields() throws {
        let value = normalizedTarget
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasPrefix("-"),
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains("/"), !value.contains("\\"), !value.contains(","),
              !value.contains(where: { "@?#".contains($0) }) else {
            throw FieldRetestValidationError.invalidTarget
        }
        guard authorization.confirmed, !authorization.reference.trimmedFieldText.isEmpty,
              !authorization.confirmedBy.trimmedFieldText.isEmpty,
              authorization.reference.utf8.count <= 200,
              authorization.confirmedBy.utf8.count <= 200,
              authorization.confirmedAt <= authorization.windowEnd else {
            throw FieldRetestValidationError.authorizationRequired
        }
        guard authorization.windowStart <= authorization.windowEnd else {
            throw FieldRetestValidationError.invalidWindow
        }
        guard networkContext.count <= 500, baselineNetworkContext.count <= 500 else {
            throw FieldRetestValidationError.contextTooLong
        }
        guard baselineTarget.map(Self.isValidHost) ?? true else { throw FieldRetestValidationError.invalidTarget }

        switch method {
        case .systemDNS:
            guard dnsServer == nil else { throw FieldRetestValidationError.serverNotAllowed }
            guard dnsRecordType == .a || dnsRecordType == .aaaa else {
                throw FieldRetestValidationError.systemDNSRecordType
            }
        case .specifiedDNS:
            guard method.isControlTest, let dnsServer, Self.isValidHost(dnsServer) else {
                throw FieldRetestValidationError.serverRequired
            }
            guard dnsServerPort > 0 else { throw FieldRetestValidationError.invalidPort }
        case .tcp:
            guard dnsServer == nil, let tcpPort, (1...65_535).contains(tcpPort) else {
                throw FieldRetestValidationError.invalidPort
            }
        case .tls, .http:
            guard dnsServer == nil, let tcpPort, (1...65_535).contains(tcpPort),
                  ServiceProbeEndpoint.validHost(value) else { throw FieldRetestValidationError.invalidService }
            if method == .http {
                guard ServiceProbeEndpoint.url(host: value, port: tcpPort, scheme: httpScheme ?? "https", path: httpPath ?? "/") != nil else {
                    throw FieldRetestValidationError.invalidService
                }
            }
        case .directTCP:
            guard method.isControlTest, dnsServer == nil, let tcpPort, (1...65_535).contains(tcpPort),
                  Self.isIPAddress(value) else {
                throw FieldRetestValidationError.directIPRequired
            }
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 { return true }
        var stripped = value
        if let zone = stripped.firstIndex(of: "%") { stripped = String(stripped[..<zone]) }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, stripped, &v6) == 1
    }

    private static func isValidHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("\\"), !host.contains(","),
              !host.contains(where: { "@?#".contains($0) }) else { return false }
        return true
    }
}

public struct FieldRetestRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public let request: FieldRetestRequest
    public var diagnosticRunID: UUID?
    public var status: FieldRetestStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var actualTarget: String
    public var addressFamily: FieldProjectAddressFamily
    public var dnsMode: DNSLookupMode?
    public var resolver: String?
    public var observedPath: String
    public var summary: String
    public var detail: String
    public var comparisonState: FieldRetestComparisonState
    public var notComparableReason: String?
    public var executedLayers: [FieldRetestLayer]
    public var serviceEvidence: ServiceProbeEvidence?

    public init(id: UUID = UUID(), request: FieldRetestRequest, diagnosticRunID: UUID? = nil,
                status: FieldRetestStatus = .pending, startedAt: Date = Date(), finishedAt: Date? = nil,
                actualTarget: String = "", addressFamily: FieldProjectAddressFamily = .notRecorded,
                dnsMode: DNSLookupMode? = nil, resolver: String? = nil, observedPath: String = "",
                summary: String = "", detail: String = "",
                comparisonState: FieldRetestComparisonState = .notEvaluated,
                notComparableReason: String? = nil, executedLayers: [FieldRetestLayer] = [],
                serviceEvidence: ServiceProbeEvidence? = nil) {
        self.id = id
        self.request = request
        self.diagnosticRunID = diagnosticRunID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.actualTarget = actualTarget
        self.addressFamily = addressFamily
        self.dnsMode = dnsMode
        self.resolver = resolver
        self.observedPath = observedPath
        self.summary = summary
        self.detail = detail
        self.comparisonState = comparisonState
        self.notComparableReason = notComparableReason
        self.executedLayers = executedLayers
        self.serviceEvidence = serviceEvidence
    }

    public var isControlTest: Bool { request.method.isControlTest }

    public func validate() throws {
        guard request.check == .retest else {
            throw FieldRetestValidationError.invalidRecord
        }
        try request.validateStored()
        guard status != .running || finishedAt == nil else { throw FieldRetestValidationError.invalidRecord }
        guard status != .pending else { throw FieldRetestValidationError.invalidRecord }
        guard finishedAt.map({ $0 >= startedAt }) ?? true,
              request.authorization.confirmedAt <= startedAt,
              request.authorization.windowStart <= startedAt,
              startedAt <= request.authorization.windowEnd else {
            throw FieldRetestValidationError.invalidRecord
        }
        guard summary.utf8.count <= 1_000, detail.utf8.count <= 4_000,
              observedPath.utf8.count <= 1_000, notComparableReason?.utf8.count ?? 0 <= 500 else {
            throw FieldRetestValidationError.recordTooLong
        }
        guard executedLayers == [request.method.layer] else {
            throw FieldRetestValidationError.invalidRecord
        }
        if request.method == .tls || request.method == .http {
            guard let evidence = serviceEvidence,
                  evidence.peerAddress.map(ServiceProbeEndpoint.isNumeric) ?? true,
                  evidence.httpStatus.map({ (100...999).contains($0) }) ?? true else {
                throw FieldRetestValidationError.invalidRecord
            }
            if status == .succeeded {
                guard evidence.failure == nil,
                      request.method == .tls ? evidence.tlsVerified == true : evidence.httpStatus.map({ (200...299).contains($0) }) == true else {
                    throw FieldRetestValidationError.invalidRecord
                }
            }
            return
        }
        guard serviceEvidence == nil else { throw FieldRetestValidationError.invalidRecord }
    }
}

public enum FieldRetestValidationError: LocalizedError, Equatable, Sendable {
    case invalidTarget, authorizationRequired, invalidWindow, outsideWindow, contextTooLong
    case serverNotAllowed, serverRequired, systemDNSRecordType, invalidPort, directIPRequired
    case invalidRecord, recordTooLong, workspaceUnavailable, invalidService

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: return t("Enter one host or IP address only.")
        case .invalidService: return t("Use an ASCII hostname or numeric IP, a valid port and an absolute path without query, fragment or percent escapes.")
        case .authorizationRequired: return t("Confirm an authorization reference and approver before starting the retest.")
        case .invalidWindow: return t("The retest window is invalid.")
        case .outsideWindow: return t("The current time is outside the approved retest window.")
        case .contextTooLong: return t("Network context is limited to 500 characters.")
        case .serverNotAllowed: return t("System DNS mode cannot include a specified DNS server.")
        case .serverRequired: return t("A specified DNS server is required for this control test.")
        case .systemDNSRecordType: return t("System DNS mode supports only A and AAAA records.")
        case .invalidPort: return t("Enter a TCP or DNS port from 1 to 65535.")
        case .directIPRequired: return t("Direct-IP TCP control tests require one numeric IP address.")
        case .invalidRecord: return t("This retest record is invalid.")
        case .recordTooLong: return t("This retest record contains too much diagnostic output.")
        case .workspaceUnavailable: return t("The local diagnostic workspace is not available for saving.")
        }
    }
}

@MainActor
public enum FieldRetestExecutor {
    public static func run(_ request: FieldRetestRequest, store: AssetStore? = nil,
                           now: Date = Date()) async throws -> FieldRetestRecord {
        try request.validate(now: now)
        let store = store ?? AssetStore.shared
        guard store.canEditWorkspace else { throw FieldRetestValidationError.workspaceUnavailable }

        let kind: DiagnosticKind
        switch request.method.layer {
        case .dns: kind = .dns
        case .tcp: kind = .tcp
        case .tls: kind = .tls
        case .http: kind = .http
        }
        let parameters = parameters(for: request)
        let runID = store.beginDiagnostic(deviceID: nil, kind: kind, target: request.normalizedTarget, parameters: parameters)
        let startedAt = Date()
        let result: DiagnosticExecutionResult
        switch request.method {
        case .systemDNS:
            result = await DiagnosticService.runDNS(host: request.normalizedTarget, recordType: request.dnsRecordType,
                                                    timeout: 3, mode: .system)
        case .specifiedDNS:
            result = await DiagnosticService.runDNS(host: request.normalizedTarget, recordType: request.dnsRecordType,
                                                    server: request.dnsServer, serverPort: request.dnsServerPort,
                                                    timeout: 3, mode: .server)
        case .tcp, .directTCP:
            result = await DiagnosticService.runTCP(host: request.normalizedTarget, port: request.tcpPort ?? 0, timeout: 2)
        case .tls:
            result = await DiagnosticService.runTLS(host: request.normalizedTarget, port: request.tcpPort ?? 443, timeout: 5)
        case .http:
            result = await DiagnosticService.runHTTP(host: request.normalizedTarget, port: request.tcpPort ?? 443,
                                                      scheme: request.httpScheme ?? "https", path: request.httpPath ?? "/", timeout: 5)
        }
        store.finishDiagnostic(id: runID, status: result.status, summary: result.summary, detail: result.detail,
                               latency: result.latency, source: result.source, evidence: result.evidence)

        let record = completedRecord(request: request, result: result, runID: runID,
                                     startedAt: startedAt, finishedAt: Date())
        try record.validate()
        return record
    }

    /// The UI and export share this completed observation. It never changes the selected baseline.
    nonisolated static func completedRecord(request: FieldRetestRequest, result: DiagnosticExecutionResult, runID: UUID,
                                            startedAt: Date, finishedAt: Date) -> FieldRetestRecord {
        var record = FieldRetestRecord(request: request, diagnosticRunID: runID, status: map(result.status),
                                       startedAt: startedAt, finishedAt: finishedAt, actualTarget: actualTarget(for: request, result: result),
                                       addressFamily: addressFamily(for: request, result: result),
                                       dnsMode: request.method == .systemDNS ? .system : (request.method == .specifiedDNS ? .server : nil),
                                       resolver: request.method == .systemDNS ? t("macOS system resolver") : (request.method == .specifiedDNS ? request.dnsServer : nil),
                                       observedPath: t("Route and interface were not measured."),
                                       summary: bounded(result.summary, bytes: 1_000), detail: bounded(result.detail, bytes: 4_000),
                                       executedLayers: [request.method.layer], serviceEvidence: result.evidence?.service)
        let comparison = compare(request: request, actualFamily: record.addressFamily)
        record.comparisonState = comparison.state
        record.notComparableReason = comparison.reason
        return record
    }

    nonisolated private static func bounded(_ value: String, bytes limit: Int) -> String {
        let redacted = DiagnosticEvidenceExporter.redact(value)
        var output = ""
        var count = 0
        for character in redacted {
            let size = String(character).utf8.count
            guard count + size <= limit else { break }
            output.append(character)
            count += size
        }
        return output
    }

    nonisolated private static func parameters(for request: FieldRetestRequest) -> [String: String] {
        var values = ["fieldRetest": "true", "method": request.method.rawValue]
        switch request.method {
        case .systemDNS, .specifiedDNS: values["recordType"] = request.dnsRecordType.displayName
        case .tcp, .directTCP, .tls, .http: values["port"] = String(request.tcpPort ?? 0)
        }
        if request.method == .tls || request.method == .http { values["timeout"] = "5.0" }
        if request.method == .http {
            values["scheme"] = request.httpScheme ?? "https"
            values["path"] = request.httpPath ?? "/"
            values["httpMethod"] = "HEAD"
        }
        if let server = request.dnsServer { values["dnsServer"] = server }
        return values
    }

    nonisolated private static func map(_ status: DiagnosticRunStatus) -> FieldRetestStatus {
        switch status {
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .permissionDenied: return .permissionDenied
        case .unreachable: return .unreachable
        }
    }

    nonisolated private static func actualTarget(for request: FieldRetestRequest, result: DiagnosticExecutionResult) -> String {
        if let service = result.evidence?.service {
            guard service.peerIsProxy != true, let peer = service.peerAddress else { return t("Not recorded") }
            return peer
        }
        if let attempt = result.evidence?.tcpAttempts?.first(where: { $0.code == nil }) {
            return attempt.address
        }
        if let address = result.evidence?.tcpFailure?.address { return address }
        return request.normalizedTarget
    }

    nonisolated private static func addressFamily(for request: FieldRetestRequest, result: DiagnosticExecutionResult) -> FieldProjectAddressFamily {
        if let service = result.evidence?.service {
            guard service.peerIsProxy != true, let peer = service.peerAddress else { return .notRecorded }
            return isIPv4(peer) ? .ipv4 : (isIPv6(peer) ? .ipv6 : .notRecorded)
        }
        let families = Set((result.evidence?.tcpAttempts ?? []).map(\.family).filter { $0 == AF_INET || $0 == AF_INET6 })
        if families.contains(AF_INET), families.contains(AF_INET6) { return .dualStack }
        if families.contains(AF_INET) { return .ipv4 }
        if families.contains(AF_INET6) { return .ipv6 }
        if result.dnsRecords.contains(where: { isIPv4($0.value) }) && result.dnsRecords.contains(where: { isIPv6($0.value) }) { return .dualStack }
        if result.dnsRecords.contains(where: { isIPv4($0.value) }) { return .ipv4 }
        if result.dnsRecords.contains(where: { isIPv6($0.value) }) { return .ipv6 }
        if isIPv4(request.normalizedTarget) { return .ipv4 }
        if isIPv6(request.normalizedTarget) { return .ipv6 }
        return .notRecorded
    }

    nonisolated private static func compare(request: FieldRetestRequest, actualFamily: FieldProjectAddressFamily) -> (state: FieldRetestComparisonState, reason: String?) {
        guard request.baselineRevisionID != nil, request.acceptanceItemID != nil,
              request.baselineEvidenceID != nil, let baselineTarget = request.baselineTarget,
              let baselineMethod = request.baselineMethod else {
            return (.notComparable, t("A matching baseline target and method were not recorded."))
        }
        guard baselineTarget.trimmedFieldText.lowercased() == request.normalizedTarget.lowercased(),
              baselineMethod == request.method else {
            return (.notComparable, t("The target or method differs from the selected baseline."))
        }
        guard !request.baselineNetworkContext.trimmedFieldText.isEmpty,
              !request.networkContext.trimmedFieldText.isEmpty else {
            return (.notComparable, t("Baseline or current network conditions were not recorded."))
        }
        guard request.baselineNetworkContext.normalizedFieldContext == request.networkContext.normalizedFieldContext else {
            return (.notComparable, t("The current network context differs from the baseline."))
        }
        guard let baseline = request.baselineAddressFamily, baseline != .notRecorded, actualFamily != .notRecorded else {
            return (.notComparable, t("The baseline or observed address family was not recorded."))
        }
        if baseline != actualFamily {
            return (.notComparable, t("The observed address family differs from the baseline."))
        }
        // Matching entered conditions cannot establish the actual egress path.
        return (.notComparable, t("Entered conditions match, but the network route and interface have not been verified."))
    }

    nonisolated private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, value.trimmingCharacters(in: .whitespacesAndNewlines), &address) == 1
    }

    nonisolated private static func isIPv6(_ value: String) -> Bool {
        var literal = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zone = literal.firstIndex(of: "%") { literal = String(literal[..<zone]) }
        var address = in6_addr()
        return inet_pton(AF_INET6, literal, &address) == 1
    }
}

private extension String {
    var trimmedFieldText: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedFieldContext: String { trimmedFieldText.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
}
