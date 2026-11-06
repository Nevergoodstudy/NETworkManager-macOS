import Foundation
import NMCore

// MARK: - NetBox read-only connector

/// Non-secret connection settings for a NetBox instance.
///
/// The API token is intentionally not part of this value. Store it in the
/// macOS Keychain and pass it to `NetBoxClient` only for the duration of a
/// request. This makes exported workspace data safe to inspect and share.
public struct NetBoxConfiguration: Codable, Hashable, Sendable {
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

public enum NetBoxError: LocalizedError, Sendable {
    case invalidBaseURL
    case unsupportedScheme
    case missingToken
    case invalidResponse
    case httpStatus(Int, String)
    case decoding(String)
    case paginationLoop
    case crossOriginPagination
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "NetBox URL is invalid."
        case .unsupportedScheme: return "NetBox credentials require HTTPS. Plain HTTP is allowed only for loopback testing."
        case .missingToken: return "A read-only NetBox API token is required."
        case .invalidResponse: return "NetBox returned an invalid response."
        case let .httpStatus(status, message): return "NetBox returned HTTP \(status): \(message)"
        case let .decoding(message): return "NetBox response could not be decoded: \(message)"
        case .paginationLoop: return "NetBox pagination did not advance."
        case .crossOriginPagination: return "NetBox returned a pagination URL on another host."
        case let .responseTooLarge(limit): return "NetBox response exceeded the \(limit / 1_048_576) MB safety limit."
        }
    }
}

public struct NetBoxReference: Codable, Hashable, Sendable {
    public var id: Int?
    public var name: String?
    public var display: String?

    public init(id: Int? = nil, name: String? = nil, display: String? = nil) {
        self.id = id
        self.name = name
        self.display = display
    }

    public var label: String { display ?? name ?? (id.map(String.init) ?? "Unknown") }
}

public struct NetBoxChoice: Codable, Hashable, Sendable {
    public var value: String
    public var label: String

    enum CodingKeys: String, CodingKey {
        case value, label
    }

    public init(value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            value = try container.decode(String.self, forKey: .value)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? value
        } else {
            let container = try decoder.singleValueContainer()
            value = try container.decode(String.self)
            label = value
        }
    }
}

public struct NetBoxDeviceType: Codable, Hashable, Sendable {
    public var id: Int?
    public var name: String?
    public var display: String?
    public var model: String?
    public var manufacturer: NetBoxReference?
    public var url: URL?

    public init(id: Int? = nil, name: String? = nil, display: String? = nil, model: String? = nil, manufacturer: NetBoxReference? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.display = display
        self.model = model
        self.manufacturer = manufacturer
        self.url = url
    }

    public var label: String { display ?? name ?? model ?? (id.map(String.init) ?? "Unknown") }
}

public struct NetBoxDeviceRecord: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var display: String?
    public var deviceType: NetBoxDeviceType?
    public var deviceRole: NetBoxReference?
    public var site: NetBoxReference?
    public var status: NetBoxChoice?
    public var primaryIP4: NetBoxReference?
    public var primaryIP6: NetBoxReference?
    public var url: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, display, deviceType = "device_type", deviceRole = "role", site, status
        case primaryIP4 = "primary_ip4", primaryIP6 = "primary_ip6", url
    }

    public init(id: Int, name: String, display: String? = nil, deviceType: NetBoxDeviceType? = nil, deviceRole: NetBoxReference? = nil, site: NetBoxReference? = nil, status: NetBoxChoice? = nil, primaryIP4: NetBoxReference? = nil, primaryIP6: NetBoxReference? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.display = display
        self.deviceType = deviceType
        self.deviceRole = deviceRole
        self.site = site
        self.status = status
        self.primaryIP4 = primaryIP4
        self.primaryIP6 = primaryIP6
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        display = try container.decodeIfPresent(String.self, forKey: .display)
        deviceType = try container.decodeIfPresent(NetBoxDeviceType.self, forKey: .deviceType)
        deviceRole = try container.decodeIfPresent(NetBoxReference.self, forKey: .deviceRole)
        site = try container.decodeIfPresent(NetBoxReference.self, forKey: .site)
        status = try container.decodeIfPresent(NetBoxChoice.self, forKey: .status)
        primaryIP4 = try container.decodeIfPresent(NetBoxReference.self, forKey: .primaryIP4)
        primaryIP6 = try container.decodeIfPresent(NetBoxReference.self, forKey: .primaryIP6)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
    }
}

public struct NetBoxSiteRecord: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var slug: String?
    public var status: NetBoxChoice?
    public var description: String?
    public var url: URL?

    public init(id: Int, name: String, slug: String? = nil, status: NetBoxChoice? = nil, description: String? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.status = status
        self.description = description
        self.url = url
    }
}

public struct NetBoxPage<Record: Codable & Sendable>: Codable, Sendable {
    public var count: Int
    public var next: URL?
    public var previous: URL?
    public var results: [Record]

    public init(count: Int, next: URL? = nil, previous: URL? = nil, results: [Record]) {
        self.count = count
        self.next = next
        self.previous = previous
        self.results = results
    }
}

public struct NetBoxSyncResult: Sendable {
    public var devices: [NetBoxDeviceRecord]
    public var sites: [NetBoxSiteRecord]
    public var fetchedAt: Date
    public var devicePages: Int
    public var sitePages: Int
    public var source: String

    public init(devices: [NetBoxDeviceRecord], sites: [NetBoxSiteRecord], fetchedAt: Date, devicePages: Int, sitePages: Int, source: String) {
        self.devices = devices
        self.sites = sites
        self.fetchedAt = fetchedAt
        self.devicePages = devicePages
        self.sitePages = sitePages
        self.source = source
    }
}

private struct NetBoxOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else { return nil }

        let effectivePort = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(effectivePort) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = effectivePort
    }
}

public enum NetBoxConnectionPolicy {
    public static func permits(_ url: URL) -> Bool {
        guard let origin = NetBoxOrigin(url: url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil else { return false }
        return origin.scheme == "https" || isLoopbackHost(origin.host)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return true }
        if let address = IPv4(normalized) { return address.octets.first == 127 }
        return normalized == "::1" || normalized == "0:0:0:0:0:0:0:1"
    }
}

private final class NetBoxRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let currentURL = task.currentRequest?.url,
              let nextURL = request.url,
              let currentOrigin = NetBoxOrigin(url: currentURL),
              NetBoxOrigin(url: nextURL) == currentOrigin else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class NetBoxClient: @unchecked Sendable {
    public static let maxResponseBytes = 8 * 1_048_576
    public let configuration: NetBoxConfiguration
    private let token: String?
    private let session: URLSession
    private let redirectDelegate: NetBoxRedirectDelegate
    private let decoder: JSONDecoder

    public init(configuration: NetBoxConfiguration, token: String?) {
        self.configuration = configuration
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let delegate = NetBoxRedirectDelegate()
        self.redirectDelegate = delegate
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.decoder = JSONDecoder()
    }

    public func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let scheme = configuration.baseURL.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { throw NetBoxError.unsupportedScheme }
        guard NetBoxConnectionPolicy.permits(configuration.baseURL) else { throw NetBoxError.unsupportedScheme }
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              NetBoxOrigin(url: configuration.baseURL) != nil else { throw NetBoxError.invalidBaseURL }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw NetBoxError.invalidBaseURL }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = authorizationValue { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    public func testConnection() async throws -> Date {
        _ = try requireToken()
        let request = try makeRequest(path: "api/status/")
        _ = try await perform(request)
        return Date()
    }

    public func fetchDevices(maxPages: Int = 50) async throws -> ([NetBoxDeviceRecord], pages: Int) {
        try await fetchPages(path: "api/dcim/devices/", maxPages: maxPages)
    }

    public func fetchSites(maxPages: Int = 50) async throws -> ([NetBoxSiteRecord], pages: Int) {
        try await fetchPages(path: "api/dcim/sites/", maxPages: maxPages)
    }

    public func sync(maxPages: Int = 50) async throws -> NetBoxSyncResult {
        let devices = try await fetchDevices(maxPages: maxPages)
        let sites = try await fetchSites(maxPages: maxPages)
        return NetBoxSyncResult(devices: devices.0, sites: sites.0, fetchedAt: Date(), devicePages: devices.pages, sitePages: sites.pages, source: configuration.redactedDescription)
    }

    private func requireToken() throws -> String {
        guard let token, !token.isEmpty else { throw NetBoxError.missingToken }
        return token
    }

    private var authorizationValue: String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if token.hasPrefix("nbt_"), parts.count == 2, parts[0].count > 4, !parts[1].isEmpty {
            return "Bearer \(token)"
        }
        return "Token \(token)"
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        _ = try requireToken()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetBoxError.invalidResponse }
            if http.expectedContentLength > Int64(Self.maxResponseBytes) {
                throw NetBoxError.responseTooLarge(Self.maxResponseBytes)
            }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maxResponseBytes))
            }
            for try await byte in bytes {
                if data.count >= Self.maxResponseBytes {
                    throw NetBoxError.responseTooLarge(Self.maxResponseBytes)
                }
                data.append(byte)
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8).map(redactResponse) ?? "Request failed"
                throw NetBoxError.httpStatus(http.statusCode, message)
            }
            return data
        } catch let error as NetBoxError {
            throw error
        } catch {
            throw error
        }
    }

    private func fetchPages<Record: Codable & Sendable>(path: String, maxPages: Int) async throws -> ([Record], pages: Int) {
        var request = try makeRequest(path: path)
        var values: [Record] = []
        var pages = 0
        var visited: Set<URL> = []
        guard let baseOrigin = NetBoxOrigin(url: configuration.baseURL) else { throw NetBoxError.invalidBaseURL }
        var hasNext = true
        while pages < maxPages {
            guard let url = request.url else { throw NetBoxError.invalidBaseURL }
            guard visited.insert(Self.paginationIdentity(url)).inserted else { throw NetBoxError.paginationLoop }
            let data = try await perform(request)
            let page: NetBoxPage<Record>
            do { page = try decoder.decode(NetBoxPage<Record>.self, from: data) }
            catch { throw NetBoxError.decoding(error.localizedDescription) }
            values.append(contentsOf: page.results)
            pages += 1
            guard let next = page.next else {
                hasNext = false
                break
            }
            guard NetBoxOrigin(url: next) == baseOrigin else { throw NetBoxError.crossOriginPagination }
            request = requestForNext(next)
        }
        if hasNext, pages >= maxPages { throw NetBoxError.paginationLoop }
        return (values, pages)
    }

    private static func paginationIdentity(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? url
    }

    private func requestForNext(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = authorizationValue { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func redactResponse(_ value: String) -> String {
        let maxLength = 300
        var compact = value.replacingOccurrences(of: "\n", with: " ")
        if let token, !token.isEmpty {
            compact = compact.replacingOccurrences(of: token, with: "[REDACTED]")
        }
        return String(compact.prefix(maxLength))
    }
}

public enum NetBoxAssetMapper {
    public static func snapshots(from result: NetBoxSyncResult) -> [ExternalAssetSnapshot] {
        result.devices.compactMap { snapshot(from: $0, source: result.source, fetchedAt: result.fetchedAt) }
    }

    public static func snapshot(from record: NetBoxDeviceRecord, source: String, fetchedAt: Date) -> ExternalAssetSnapshot? {
        guard let rawAddress = record.primaryIP4?.display ?? record.primaryIP6?.display,
              !rawAddress.isEmpty else { return nil }
        let address = rawAddress.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rawAddress
        let type = "\(record.deviceRole?.label ?? "") \(record.deviceType?.label ?? "") \(record.deviceType?.model ?? "")".lowercased()
        let kind: AssetDeviceKind
        if type.contains("firewall") { kind = .firewall }
        else if type.contains("router") { kind = .router }
        else if type.contains("switch") { kind = .networkSwitch }
        else if type.contains("access point") || type.contains("wireless") { kind = .accessPoint }
        else if type.contains("server") { kind = .server }
        else { kind = .other }

        return ExternalAssetSnapshot(
            source: source,
            fetchedAt: fetchedAt,
            siteName: record.site?.label ?? t("Unassigned site"),
            siteLocation: "",
            deviceName: record.name.isEmpty ? "Device #\(record.id)" : record.name,
            address: address,
            kind: kind,
            role: record.deviceRole?.label ?? "",
            vendor: record.deviceType?.manufacturer?.label ?? ""
        )
    }
}

/// Deterministic, network-free checks used by the package smoke runner.
public enum NetBoxOfflineChecks {
    public static func run() throws {
        let config = NetBoxConfiguration(baseURL: URL(string: "https://netbox.example/ops")!, tokenReference: "netbox-readonly")
        guard let origin = NetBoxOrigin(url: config.baseURL),
              NetBoxOrigin(url: URL(string: "https://netbox.example:443/ops/api/dcim/devices/?limit=50")!) == origin,
              NetBoxOrigin(url: URL(string: "https://netbox.example:8443/ops/api/dcim/devices/?limit=50")!) != origin,
              NetBoxOrigin(url: URL(string: "http://netbox.example/ops/api/dcim/devices/?limit=50")!) != origin,
              NetBoxOrigin(url: URL(string: "https://user@netbox.example/ops/api/dcim/devices/")!) == nil else {
            throw NetBoxError.crossOriginPagination
        }

        let client = NetBoxClient(configuration: config, token: "secret-token")
        let request = try client.makeRequest(path: "api/dcim/devices/", query: [URLQueryItem(name: "limit", value: "50")])
        guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == "Token secret-token" else {
            throw NetBoxError.invalidResponse
        }
        let fixture = Data("""
        {"count":1,"next":null,"previous":null,"results":[{"id":7,"name":"edge-01","display":"edge-01","device_type":{"id":1,"name":"Router"},"device_role":{"id":2,"name":"Edge"},"site":{"id":3,"name":"Lab"},"status":"active","primary_ip4":{"id":9,"display":"192.0.2.7/24"}}]}
        """.utf8)
        let page = try JSONDecoder().decode(NetBoxPage<NetBoxDeviceRecord>.self, from: fixture)
        guard page.results.count == 1, page.results[0].name == "edge-01", page.results[0].site?.label == "Lab" else {
            throw NetBoxError.decoding("fixture assertion failed")
        }
    }
}
