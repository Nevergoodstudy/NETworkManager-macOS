import CryptoKit
import Foundation
import NMCore

public struct ZabbixConfiguration: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var tokenReference: String?
    public var timeout: TimeInterval

    public init(baseURL: URL, tokenReference: String? = nil, timeout: TimeInterval = 12) {
        self.baseURL = baseURL
        self.tokenReference = tokenReference
        self.timeout = max(1, timeout)
    }

    public var redactedDescription: String {
        var value = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let tokenReference, !tokenReference.isEmpty { value += " · token: \(tokenReference)" }
        return value
    }
}

public enum ZabbixConnectionPolicy {
    public static func permits(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else { return false }
        return true
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
        if let address = IPv4(normalized) { return address.octets.first == 127 }
        return normalized == "::1" || normalized == "0:0:0:0:0:0:0:1"
    }
}

public enum ZabbixError: LocalizedError, Sendable {
    case invalidBaseURL
    case unsupportedScheme
    case missingToken
    case invalidResponse
    case timeout
    case httpStatus(Int, String)
    case api(Int, String)
    case decoding(String)
    case responseTooLarge(Int)
    case invalidProblemTime

    var isAccessDenied: Bool {
        switch self {
        case .httpStatus(401, _), .httpStatus(403, _): return true
        case let .api(_, message):
            return ["not authorized", "no permissions to call", "no permissions to referred object",
                    "permission denied"].contains { message.localizedCaseInsensitiveContains($0) }
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Zabbix URL is invalid."
        case .unsupportedScheme: return "Zabbix credentials require HTTPS. Plain HTTP is allowed only for loopback testing."
        case .missingToken: return "A read-only Zabbix API token is required."
        case .invalidResponse: return "Zabbix returned an invalid response."
        case .timeout: return "The Zabbix request timed out. Check the URL and network path, then retry."
        case let .httpStatus(status, message): return "Zabbix returned HTTP \(status): \(message)"
        case let .api(code, message): return "Zabbix API error \(code): \(message)"
        case let .decoding(message): return "Zabbix response could not be decoded: \(message)"
        case let .responseTooLarge(limit): return "Zabbix response exceeded the \(limit / 1_048_576) MB safety limit."
        case .invalidProblemTime: return "The Zabbix problem has an invalid timestamp."
        }
    }
}

public struct ZabbixHost: Codable, Hashable, Sendable, Identifiable {
    public var hostID: String
    public var technicalName: String
    public var displayName: String
    public var target: String?

    public var id: String { hostID }
}

public struct ZabbixProblem: Codable, Hashable, Sendable, Identifiable {
    public var eventID: String
    public var triggerID: String
    public var clock: Int
    public var name: String
    public var severity: Int
    public var acknowledged: Bool
    public var operationalData: String
    public var hosts: [ZabbixHost]

    public var id: String { eventID }
    public var occurredAt: Date { Date(timeIntervalSince1970: TimeInterval(clock)) }
    public var severityName: String {
        switch severity {
        case 0: return "Not classified"
        case 1: return "Information"
        case 2: return "Warning"
        case 3: return "Average"
        case 4: return "High"
        case 5: return "Disaster"
        default: return "Unknown"
        }
    }
}

public struct ZabbixMetric: Decodable, Sendable, Identifiable {
    fileprivate let itemid: FlexibleString
    fileprivate let value_type: FlexibleString
    public let name: String
    public let key: String
    public let units: String
    public let delay: String

    private enum CodingKeys: String, CodingKey {
        case itemid, value_type, name, units, delay
        case key = "key_"
    }

    public var id: String { itemid.value }
}

public struct ZabbixMetricHistory: Sendable {
    public enum Window: Int, CaseIterable, Sendable {
        case five = 5, fifteen = 15, thirty = 30
    }

    public struct Sample: Decodable, Sendable {
        public let seconds: Int
        public let nanoseconds: Int
        public let rawValue: String

        private enum CodingKeys: String, CodingKey { case clock, ns, value }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard let seconds = Int(try fields.decode(FlexibleString.self, forKey: .clock).value), seconds >= 0,
                  let nanoseconds = Int(try fields.decode(FlexibleString.self, forKey: .ns).value),
                  (0..<1_000_000_000).contains(nanoseconds) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid history timestamp."))
            }
            self.seconds = seconds
            self.nanoseconds = nanoseconds
            rawValue = try fields.decode(FlexibleString.self, forKey: .value).value
        }
    }

    public let range: ClosedRange<Int>
    public let queriedAt: Date
    public let samples: [Sample]
    public let beforeOrAtLimitReached: Bool
    public let afterLimitReached: Bool
    public let afterWindowOpen: Bool
}

private struct ZabbixRPCRequest: Encodable {
    var jsonrpc = "2.0"
    var method: String
    var params: [String: AnyEncodable]
    var id = 1
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

private struct ZabbixRPCResponse<ResultValue: Decodable>: Decodable {
    struct APIError: Decodable {
        var code: Int
        var message: String
        var data: String?
    }

    var result: ResultValue?
    var error: APIError?
}

private struct ZabbixProblemRecord: Decodable {
    var eventid: FlexibleString
    var objectid: FlexibleString
    var clock: FlexibleString
    var name: String
    var severity: FlexibleString
    var acknowledged: FlexibleString
    var opdata: String?
}

private struct ZabbixTriggerRecord: Decodable {
    struct Host: Decodable {
        var hostid: FlexibleString
        var host: String
        var name: String
    }
    var triggerid: FlexibleString
    var hosts: [Host]?
}

private struct ZabbixHostRecord: Decodable {
    struct Interface: Decodable {
        var ip: String
        var dns: String
        var useip: FlexibleString
        var main: FlexibleString
    }
    var hostid: FlexibleString
    var host: String
    var name: String
    var interfaces: [Interface]?
}

private struct FlexibleString: Decodable, Hashable, Sendable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string; return }
        if let integer = try? container.decode(Int64.self) { value = String(integer); return }
        if let integer = try? container.decode(UInt64.self) { value = String(integer); return }
        if let number = try? container.decode(Double.self) { value = String(number); return }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or number."))
    }
}

private struct ZabbixRPCEnvelope: Decodable {
    struct APIError: Decodable {
        var code: Int
        var message: String
        var data: String?
    }
    var error: APIError?
}

private struct ZabbixOrigin: Equatable {
    var scheme: String
    var host: String
    var port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
    }
}

private final class ZabbixRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let current = task.currentRequest?.url, let next = request.url,
              ZabbixOrigin(url: current) == ZabbixOrigin(url: next) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class ZabbixClient: @unchecked Sendable {
    public static let maxResponseBytes = 8 * 1_048_576
    public let configuration: ZabbixConfiguration
    private let token: String?
    private let session: URLSession
    private let redirectDelegate: ZabbixRedirectDelegate
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(configuration: ZabbixConfiguration, token: String?) {
        self.configuration = configuration
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let delegate = ZabbixRedirectDelegate()
        redirectDelegate = delegate
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    private func makeRequest(method: String, params: [String: AnyEncodable]) throws -> URLRequest {
        guard ZabbixConnectionPolicy.permits(configuration.baseURL) else {
            if configuration.baseURL.scheme?.lowercased() == "https" || configuration.baseURL.scheme?.lowercased() == "http" {
                throw ZabbixError.unsupportedScheme
            }
            throw ZabbixError.invalidBaseURL
        }
        guard let token, !token.isEmpty else { throw ZabbixError.missingToken }
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw ZabbixError.invalidBaseURL
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([path, "api_jsonrpc.php"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = nil
        guard let endpoint = components.url else { throw ZabbixError.invalidBaseURL }
        var request = URLRequest(url: endpoint, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json-rpc", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(ZabbixRPCRequest(method: method, params: params))
        return request
    }

    public func makeProblemRequest() throws -> URLRequest {
        try makeRequest(method: "problem.get", params: [:])
    }

    public func fetchActiveProblems(limit: Int = 100) async throws -> [ZabbixProblem] {
        _ = try requireToken()
        let boundedLimit = max(1, min(limit, 500))
        let problemParams: [String: AnyEncodable] = [
            "output": AnyEncodable(["eventid", "objectid", "clock", "name", "severity", "acknowledged", "opdata"]),
            "source": AnyEncodable(0), "object": AnyEncodable(0),
            "sortfield": AnyEncodable(["eventid"]), "sortorder": AnyEncodable("DESC"),
            "limit": AnyEncodable(boundedLimit)
        ]
        let records: [ZabbixProblemRecord] = try await call("problem.get", params: problemParams)
        guard !records.isEmpty else { return [] }

        let triggerIDs = Array(Set(records.map { $0.objectid.value })).sorted()
        let triggerParams: [String: AnyEncodable] = [
            "output": AnyEncodable(["triggerid"]), "triggerids": AnyEncodable(triggerIDs),
            "selectHosts": AnyEncodable(["hostid", "host", "name"])
        ]
        let triggers: [ZabbixTriggerRecord] = try await call("trigger.get", params: triggerParams)
        var triggerHosts: [String: [ZabbixTriggerRecord.Host]] = [:]
        for trigger in triggers { triggerHosts[trigger.triggerid.value] = trigger.hosts ?? [] }
        var hostRecords: [String: ZabbixHostRecord] = [:]
        for host in try await fetchHosts(Array(Set(triggers.flatMap { $0.hosts ?? [] }.map { $0.hostid.value }))) {
            hostRecords[host.hostid.value] = host
        }

        return records.map { problem in
            let linkedHosts: [ZabbixTriggerRecord.Host] = triggerHosts[problem.objectid.value] ?? []
            let hosts: [ZabbixHost] = linkedHosts.compactMap { host -> ZabbixHost? in
                guard let detail = hostRecords[host.hostid.value] else { return nil }
                let interfaces = detail.interfaces ?? []
                let selected = interfaces.first(where: { $0.main.value == "1" }) ?? interfaces.first
                let target: String?
                if let selected {
                    target = selected.useip.value == "1" ? nonEmpty(selected.ip) : nonEmpty(selected.dns)
                } else {
                    target = nil
                }
                return ZabbixHost(hostID: detail.hostid.value, technicalName: detail.host,
                                  displayName: detail.name.isEmpty ? detail.host : detail.name, target: target)
            }
            return ZabbixProblem(eventID: problem.eventid.value, triggerID: problem.objectid.value, clock: Int(problem.clock.value) ?? 0,
                                 name: problem.name, severity: Int(problem.severity.value) ?? -1, acknowledged: problem.acknowledged.value != "0",
                                 operationalData: problem.opdata ?? "", hosts: hosts)
        }
    }

    public func fetchNumericMetrics(for host: ZabbixHost) async throws -> [ZabbixMetric] {
        try await call("item.get", params: [
            "hostids": AnyEncodable([host.hostID]), "filter": AnyEncodable(["value_type": [0, 3]]),
            "output": AnyEncodable(["itemid", "name", "key_", "value_type", "units", "delay"]),
            "sortfield": AnyEncodable(["name", "itemid"])
        ])
    }

    public func fetchMetricHistory(for metric: ZabbixMetric, problem: ZabbixProblem,
                                   window: ZabbixMetricHistory.Window, now: Date = .now) async throws -> ZabbixMetricHistory {
        let radius = window.rawValue * 60
        guard problem.clock > 0, problem.clock <= Int.max - radius else { throw ZabbixError.invalidProblemTime }
        let range = max(0, problem.clock - radius)...(problem.clock + radius)
        let limit = 500
        let before = try await fetchHistory(for: metric, range: range.lowerBound...problem.clock, order: "DESC", limit: limit + 1)
        try Task.checkCancellation()
        let after = try await fetchHistory(for: metric, range: (problem.clock + 1)...range.upperBound, order: "ASC", limit: limit + 1)
        return ZabbixMetricHistory(range: range, queriedAt: now, samples: before.prefix(limit).reversed() + after.prefix(limit),
                                  beforeOrAtLimitReached: before.count > limit, afterLimitReached: after.count > limit,
                                  afterWindowOpen: now.timeIntervalSince1970 < Double(range.upperBound) + 1)
    }

    public func metricObservation(for metric: ZabbixMetric, history: ZabbixMetricHistory,
                                  problem: ZabbixProblem, host: ZabbixHost) -> FieldMetricObservation {
        let instance = ExternalAssetIdentity(instance: configuration.baseURL.absoluteString,
                                             objectType: "host", remoteID: host.hostID).instance
        var origin = URLComponents(string: instance)
        origin?.path = ""
        let instanceID = SHA256.hash(data: Data(instance.utf8)).map { String(format: "%02x", $0) }.joined()
        func sanitized(_ value: String) -> String {
            DiagnosticSecretRedactor.redact(value, secrets: [token, configuration.tokenReference])
        }
        return FieldMetricObservation(
            source: sanitized(origin?.string ?? "Zabbix"), instanceID: instanceID, eventID: problem.eventID,
            hostID: host.hostID, hostName: sanitized(host.displayName), itemID: metric.id, itemName: sanitized(metric.name),
            unit: sanitized(metric.units), configuredInterval: sanitized(metric.delay), queriedAt: history.queriedAt,
            alertSecond: problem.clock, window: history.range,
            samples: history.samples.map { .init(seconds: $0.seconds, nanoseconds: $0.nanoseconds, rawValue: $0.rawValue) },
            beforeOrAtLimitReached: history.beforeOrAtLimitReached, afterLimitReached: history.afterLimitReached,
            afterWindowOpen: history.afterWindowOpen
        )
    }

    private func fetchHistory(for metric: ZabbixMetric, range: ClosedRange<Int>, order: String,
                              limit: Int) async throws -> [ZabbixMetricHistory.Sample] {
        guard let historyType = Int(metric.value_type.value), historyType == 0 || historyType == 3 else {
            throw ZabbixError.invalidResponse
        }
        let samples: [ZabbixMetricHistory.Sample] = try await call("history.get", params: [
            "history": AnyEncodable(historyType), "itemids": AnyEncodable([metric.id]),
            "output": AnyEncodable(["clock", "ns", "value"]),
            "time_from": AnyEncodable(range.lowerBound), "time_till": AnyEncodable(range.upperBound),
            "sortfield": AnyEncodable(["clock", "ns"]), "sortorder": AnyEncodable(order), "limit": AnyEncodable(limit)
        ])
        guard samples.count <= limit, samples.allSatisfy({ sample in
            guard range.contains(sample.seconds), sample.rawValue.utf8.count <= 64 else { return false }
            return historyType == 3 ? UInt64(sample.rawValue) != nil : Double(sample.rawValue)?.isFinite == true
        }) else {
            throw ZabbixError.invalidResponse
        }
        let ascending = order == "ASC"
        guard zip(samples, samples.dropFirst()).allSatisfy({ previous, current in
            let left = (previous.seconds, previous.nanoseconds)
            let right = (current.seconds, current.nanoseconds)
            return ascending ? left <= right : left >= right
        }) else {
            throw ZabbixError.invalidResponse
        }
        return samples
    }

    private func fetchHosts(_ hostIDs: [String]) async throws -> [ZabbixHostRecord] {
        guard !hostIDs.isEmpty else { return [] }
        return try await call("host.get", params: [
            "output": AnyEncodable(["hostid", "host", "name"]), "hostids": AnyEncodable(hostIDs),
            "selectInterfaces": AnyEncodable(["ip", "dns", "useip", "main"])
        ])
    }

    private func call<Value: Decodable>(_ method: String, params: [String: AnyEncodable]) async throws -> Value {
        let request = try makeRequest(method: method, params: params)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ZabbixError.invalidResponse }
            if http.expectedContentLength > Int64(Self.maxResponseBytes) {
                throw ZabbixError.responseTooLarge(Self.maxResponseBytes)
            }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maxResponseBytes))
            }
            for try await byte in bytes {
                if data.count >= Self.maxResponseBytes {
                    throw ZabbixError.responseTooLarge(Self.maxResponseBytes)
                }
                data.append(byte)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ZabbixError.httpStatus(http.statusCode, redacted(String(data: data, encoding: .utf8) ?? "Request failed"))
            }
            let envelope: ZabbixRPCResponse<Value>
            do { envelope = try decoder.decode(ZabbixRPCResponse<Value>.self, from: data) }
            catch { throw ZabbixError.decoding(error.localizedDescription) }
            if let error = envelope.error {
                let message = [error.message, error.data].compactMap { $0 }.joined(separator: ": ")
                throw ZabbixError.api(error.code, redacted(message))
            }
            guard let result = envelope.result else { throw ZabbixError.invalidResponse }
            return result
        } catch let error as ZabbixError {
            throw error
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ZabbixError.timeout
            }
            throw error
        }
    }

    private func requireToken() throws {
        guard let token, !token.isEmpty else { throw ZabbixError.missingToken }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func redacted(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ")
        let safe = token.map { compact.replacingOccurrences(of: $0, with: "[REDACTED]") } ?? compact
        return String(safe.prefix(300))
    }
}

public enum ZabbixDiagnosticRunner {
    @MainActor
    @discardableResult
    public static func ping(
        problem: ZabbixProblem,
        host: ZabbixHost,
        in assets: AssetStore? = nil,
        executePing: @escaping @Sendable (String) async -> DiagnosticExecutionResult = { target in
            await DiagnosticService.runPing(host: target)
        }
    ) async -> UUID? {
        guard let target = host.target, !target.isEmpty else { return nil }
        let assets = assets ?? AssetStore.shared
        let matchingDevices = assets.devices.filter { $0.address.caseInsensitiveCompare(target) == .orderedSame }
        let device = matchingDevices.count == 1 ? matchingDevices.first : nil
        let parameters = ["timeout": "2", "source": "Zabbix", "eventID": problem.eventID, "triggerID": problem.triggerID]
        let runID = assets.beginDiagnostic(deviceID: device?.id, kind: .ping, target: target, parameters: parameters)
        let result = await executePing(target)
        assets.finishDiagnostic(id: runID, status: result.status, summary: result.summary,
                                detail: result.detail, latency: result.latency, source: "Zabbix · PING")
        return runID
    }
}
