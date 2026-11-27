import Foundation
import Network
import NMCore
import NMIntegrations

struct NetBoxFixtureRequest: Sendable {
    let method: String
    let target: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct NetBoxFixtureResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int = 200, body: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
    }
}

final class NetBoxFixtureServer: @unchecked Sendable {
    typealias Route = @Sendable (NetBoxFixtureRequest, UInt16) -> NetBoxFixtureResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "netbox-fixture-\(UUID().uuidString)")
    private let route: Route
    private let lock = NSLock()
    private var capturedRequests: [NetBoxFixtureRequest] = []
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/ops")! }

    var requests: [NetBoxFixtureRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    init(route: @escaping Route) throws {
        self.route = route
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: parameters)
        let startup = NetBoxListenerStartup()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.complete(error: nil)
            case .failed(let error):
                startup.complete(error: error)
            case .cancelled:
                startup.complete(error: NSError(domain: "NetBoxFixtureServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled before starting."]))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard startup.semaphore.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw NSError(domain: "NetBoxFixtureServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out starting the loopback fixture listener."])
        }
        if let error = startup.error {
            listener.cancel()
            throw error
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "NetBoxFixtureServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Loopback fixture listener has no port."])
        }
        self.port = port
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var current = accumulated
            if let data { current.append(data) }
            let separator = Data([13, 10, 13, 10])
            guard let boundary = current.range(of: separator) else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, accumulated: current) }
                return
            }
            let headerData = Data(current[..<boundary.lowerBound])
            let contentLength = Self.contentLength(headerData)
            let bodyStart = boundary.upperBound
            guard current.count - bodyStart >= contentLength else {
                self.receive(connection, accumulated: current)
                return
            }
            let request = Self.parseRequest(headerData, body: Data(current[bodyStart..<(bodyStart + contentLength)]))
            self.lock.lock()
            self.capturedRequests.append(request)
            self.lock.unlock()
            let response = self.route(request, self.port)
            self.respond(response, on: connection)
        }
    }

    private func respond(_ response: NetBoxFixtureResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 302: reason = "Found"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Fixture Response"
        }
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": String(response.body.count),
            "Connection": "close"
        ]
        for (key, value) in response.headers { headers[key] = value }
        let headerText = (["HTTP/1.1 \(response.status) \(reason)"] + headers.map { "\($0.key): \($0.value)" } + ["", ""]).joined(separator: "\r\n")
        var payload = Data(headerText.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func contentLength(_ data: Data) -> Int {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"),
                  line[..<separator].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            return Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private static func parseRequest(_ data: Data, body: Data) -> NetBoxFixtureRequest {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").split(separator: " ")
        let method = requestParts.first.map(String.init) ?? ""
        let target = requestParts.dropFirst().first.map(String.init) ?? "/"
        let parsedPath = URLComponents(string: "http://fixture\(target)")?.path ?? target
        let path = parsedPath.count > 1 && parsedPath.hasSuffix("/") ? String(parsedPath.dropLast()) : parsedPath
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return NetBoxFixtureRequest(method: method, target: target, path: path, headers: headers, body: body)
    }
}

private final class NetBoxListenerStartup: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didComplete = false
    private(set) var error: Error?

    func complete(error: Error?) {
        lock.lock()
        guard !didComplete else { lock.unlock(); return }
        didComplete = true
        self.error = error
        lock.unlock()
        semaphore.signal()
    }
}

private final class NetBoxAsyncResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock(); stored = result; lock.unlock()
    }

    func get() throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard let stored else { throw NSError(domain: "NetBoxFixtureServer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Async fixture result is missing."]) }
        return try stored.get()
    }
}

func awaitNetBoxFixture<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let result = NetBoxAsyncResult<Value>()
    Task.detached(priority: .userInitiated) {
        do { result.set(.success(try await operation())) }
        catch { result.set(.failure(error)) }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 15) == .success else {
        throw NSError(domain: "NetBoxFixtureServer", code: 6, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for NetBox fixture request."])
    }
    return try result.get()
}

enum NetBoxHTTPChecks {
    static func run() throws {
        let token = "local-fixture-token"
        let server = try NetBoxFixtureServer { request, port in
            switch request.path {
            case "/ops/api/status":
                return NetBoxFixtureResponse(body: "{\"netbox-version\":\"4.2.0\"}")
            case "/ops/api/dcim/devices":
                if request.target.contains("offset=1") {
                    return NetBoxFixtureResponse(body: """
                    {"count":4,"next":null,"previous":"http://127.0.0.1:\(port)/ops/api/dcim/devices/?limit=1","results":[
                      {"id":2,"name":"dist-sw-01","device_type":{"id":2,"name":"Catalyst 9300","model":"C9300","manufacturer":{"id":2,"name":"Cisco","display":"Cisco"}},"role":{"id":3,"name":"Switch"},"site":{"id":1,"name":"HQ","display":"HQ"},"status":{"value":"active","label":"Active"},"primary_ip4":null,"primary_ip6":{"id":5,"display":"2001:db8::5/64"}},
                      {"id":3,"name":"no-address","site":{"id":1,"name":"HQ","display":"HQ"},"status":{"value":"active","label":"Active"}},
                      {"id":4,"primary_ip4":{"id":6,"display":"198.51.100.20/24"},"site":{"id":1,"name":"HQ"},"status":{"value":"active","label":"Active"}}
                    ]}
                    """)
                }
                return NetBoxFixtureResponse(body: """
                {"count":4,"next":"http://127.0.0.1:\(port)/ops/api/dcim/devices/?limit=1&offset=1","previous":null,"results":[
                  {"id":1,"name":"edge-rtr-01","display":"edge-rtr-01","device_type":{"id":1,"name":"ISR 4451","model":"ISR4451-X","manufacturer":{"id":1,"name":"Cisco","display":"Cisco"}},"role":{"id":1,"name":"Router"},"site":{"id":1,"name":"HQ","display":"HQ"},"status":{"value":"active","label":"Active"},"primary_ip4":{"id":4,"display":"192.0.2.7/24"},"primary_ip6":null}
                ]}
                """)
            case "/ops/api/dcim/sites":
                return NetBoxFixtureResponse(body: """
                {"count":1,"next":null,"previous":null,"results":[{"id":1,"name":"HQ","slug":"hq","status":"active","description":"Headquarters"}]}
                """)
            default:
                return NetBoxFixtureResponse(status: 404, body: "{\"detail\":\"not found: \(request.method) \(request.target)\"}")
            }
        }
        defer { server.stop() }

        try require(NetBoxConnectionPolicy.permits(URL(string: "https://netbox.example/ops")!), "HTTPS NetBox URL is allowed")
        try require(NetBoxConnectionPolicy.permits(server.baseURL), "loopback HTTP fixture is allowed")
        try require(!NetBoxConnectionPolicy.permits(URL(string: "http://netbox.example/ops")!), "non-loopback HTTP token transmission is blocked")

        let configuration = NetBoxConfiguration(baseURL: server.baseURL, tokenReference: "fixture-keychain-ref", timeout: 3)
        let client = NetBoxClient(configuration: configuration, token: token)
        _ = try awaitNetBoxFixture { try await client.testConnection() }
        let result = try awaitNetBoxFixture { try await client.sync() }
        try require(result.devices.count == 4 && result.devicePages == 2, "NetBox device pagination follows the next URL")
        try require(result.sites.count == 1 && result.sitePages == 1, "NetBox site pagination is fetched")
        try require(!result.source.contains(token), "NetBox source metadata excludes API token")

        let requests = server.requests
        try require(requests.count == 4, "NetBox connection test and paginated sync perform expected request count")
        try require(requests.allSatisfy { $0.method == "GET" }, "NetBox connector sends read-only GET requests only")
        try require(requests.allSatisfy { $0.headers["authorization"] == "Token \(token)" }, "NetBox v1 token is sent in Authorization header")
        try require(requests.allSatisfy { $0.headers["accept"] == "application/json" }, "NetBox requests negotiate JSON")
        try require(requests.contains { $0.target.contains("offset=1") }, "NetBox follows second-page offset")

        let snapshots = NetBoxAssetMapper.snapshots(from: result)
        try require(snapshots.count == 3, "NetBox mapping skips devices without a primary address")
        try require(snapshots.first(where: { $0.deviceName == "edge-rtr-01" })?.address == "192.0.2.7", "NetBox IPv4 address mask is removed")
        try require(snapshots.first(where: { $0.deviceName == "edge-rtr-01" })?.vendor == "Cisco", "NetBox manufacturer maps to vendor")
        try require(snapshots.first(where: { $0.deviceName == "edge-rtr-01" })?.kind == .router, "NetBox role maps to asset kind")
        try require(snapshots.first(where: { $0.deviceName == "dist-sw-01" })?.address == "2001:db8::5", "NetBox IPv6 primary address is mapped")
        try require(snapshots.first(where: { $0.deviceName == "dist-sw-01" })?.kind == .networkSwitch, "NetBox switch model maps to asset kind")
        try require(snapshots.first(where: { $0.deviceName == "Device #4" })?.address == "198.51.100.20", "unnamed NetBox devices receive a stable fallback label")
        try require(result.devices.first(where: { $0.id == 1 })?.status?.label == "Active", "NetBox choice status label is decoded")
        try require(snapshots.allSatisfy { $0.siteLocation.isEmpty }, "NetBox site display is not misrepresented as a physical location")

        let v2Token = "nbt_fixture-key.fixture-secret"
        let v2Client = NetBoxClient(configuration: configuration, token: v2Token)
        let v2Request = try v2Client.makeRequest(path: "api/status/")
        try require(v2Request.value(forHTTPHeaderField: "Authorization") == "Bearer \(v2Token)", "NetBox v2 token uses Bearer authentication")
        let v2RequestStart = server.requests.count
        let v2Result = try awaitNetBoxFixture { try await v2Client.fetchDevices() }
        let v2Requests = Array(server.requests.dropFirst(v2RequestStart))
        try require(v2Result.pages == 2 && v2Requests.count == 2, "NetBox v2 token follows paginated device results")
        try require(v2Requests.allSatisfy { $0.headers["authorization"] == "Bearer \(v2Token)" }, "NetBox v2 Bearer authorization is preserved on every page")

        let requestCountBeforeMissingToken = server.requests.count
        let missingTokenClient = NetBoxClient(configuration: configuration, token: nil)
        do {
            _ = try awaitNetBoxFixture { try await missingTokenClient.testConnection() }
            throw CheckFailure(description: "NetBox missing token was accepted")
        } catch NetBoxError.missingToken {
        }
        try require(server.requests.count == requestCountBeforeMissingToken, "missing NetBox token makes no HTTP request")

        let sink = try NetBoxFixtureServer { _, _ in NetBoxFixtureResponse(body: "{\"captured\":true}") }
        defer { sink.stop() }
        let redirector = try NetBoxFixtureServer { request, _ in
            guard request.path == "/ops/api/status" else { return NetBoxFixtureResponse(status: 404, body: "{}") }
            return NetBoxFixtureResponse(status: 302, body: "{}", headers: ["Location": "http://127.0.0.1:\(sink.port)/capture"])
        }
        defer { redirector.stop() }
        let redirectClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: redirector.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await redirectClient.testConnection() }
            throw CheckFailure(description: "Cross-origin NetBox redirect was followed")
        } catch NetBoxError.httpStatus(let status, _) {
            try require(status == 302, "cross-origin redirect is returned as an HTTP failure")
        }
        try require(sink.requests.isEmpty, "NetBox token is not forwarded to another origin")

        let hostilePagination = try NetBoxFixtureServer { request, port in
            guard request.path == "/ops/api/dcim/devices" else { return NetBoxFixtureResponse(status: 404, body: "{}") }
            return NetBoxFixtureResponse(body: """
            {"count":1,"next":"https://attacker.example/collect?port=\(port)","previous":null,"results":[]}
            """)
        }
        defer { hostilePagination.stop() }
        let hostileClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: hostilePagination.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await hostileClient.fetchDevices() }
            throw CheckFailure(description: "Cross-origin NetBox pagination was followed")
        } catch NetBoxError.crossOriginPagination {
        }
        try require(hostilePagination.requests.count == 1, "cross-origin pagination stops after the first page")

        let loopServer = try NetBoxFixtureServer { request, port in
            guard request.path == "/ops/api/dcim/devices" else { return NetBoxFixtureResponse(status: 404, body: "{}") }
            return NetBoxFixtureResponse(body: """
            {"count":1,"next":"http://127.0.0.1:\(port)/ops/api/dcim/devices/","previous":null,"results":[]}
            """)
        }
        defer { loopServer.stop() }
        let loopClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: loopServer.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await loopClient.fetchDevices() }
            throw CheckFailure(description: "Repeated NetBox pagination URL was accepted")
        } catch NetBoxError.paginationLoop {
        }
        try require(loopServer.requests.count == 1, "repeated NetBox pagination URL stops before a duplicate request")

        let boundedServer = try NetBoxFixtureServer { request, port in
            guard request.path == "/ops/api/dcim/devices" else { return NetBoxFixtureResponse(status: 404, body: "{}") }
            return NetBoxFixtureResponse(body: """
            {"count":2,"next":"http://127.0.0.1:\(port)/ops/api/dcim/devices/?offset=1","previous":null,"results":[]}
            """)
        }
        defer { boundedServer.stop() }
        let boundedClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: boundedServer.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await boundedClient.fetchDevices(maxPages: 1) }
            throw CheckFailure(description: "NetBox maxPages limit was ignored")
        } catch NetBoxError.paginationLoop {
        }
        try require(boundedServer.requests.count == 1, "NetBox maxPages limit stops before fetching another page")

        let echoedTokenServer = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(status: 403, body: "{\"detail\":\"invalid token local-fixture-token\"}")
        }
        defer { echoedTokenServer.stop() }
        let echoedTokenClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: echoedTokenServer.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await echoedTokenClient.testConnection() }
            throw CheckFailure(description: "NetBox error response was unexpectedly accepted")
        } catch NetBoxError.httpStatus(_, let message) {
            try require(!message.contains(token) && message.contains("[REDACTED]"), "NetBox HTTP error response redacts the API token")
        }

        let oversizedNetBoxServer = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(body: String(repeating: "x", count: NetBoxClient.maxResponseBytes + 1))
        }
        defer { oversizedNetBoxServer.stop() }
        let oversizedNetBoxClient = NetBoxClient(configuration: NetBoxConfiguration(baseURL: oversizedNetBoxServer.baseURL, timeout: 3), token: token)
        do {
            _ = try awaitNetBoxFixture { try await oversizedNetBoxClient.testConnection() }
            throw CheckFailure(description: "NetBox accepted a response above the byte cap")
        } catch NetBoxError.responseTooLarge(let limit) {
            try require(limit == NetBoxClient.maxResponseBytes, "NetBox reports its strict response byte cap")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
    }
}

enum ZabbixHTTPChecks {
    static func metricHistory(testPersistence: Bool = false) async throws {
        struct Request: Decodable {
            struct Params: Decodable {
                var hostids: [String]?
                var filter: [String: [Int]]?
                var itemids: [String]?
                var history: Int?
                var time_from: Int?
                var time_till: Int?
                var sortfield: [String]?
                var sortorder: String?
                var limit: Int?
            }
            let method: String
            let params: Params
        }
        let clock = 1_730_000_000
        let token = "zabbix-history-fixture-token"
        let server = try NetBoxFixtureServer { request, _ in
            guard request.path == "/ops/api_jsonrpc.php", request.headers["authorization"] == "Bearer \(token)",
                  let call = try? JSONDecoder().decode(Request.self, from: request.body) else {
                return NetBoxFixtureResponse(status: 400, body: "{}")
            }
            let params = call.params
            if call.method == "item.get", params.hostids == ["5001"], params.filter == ["value_type": [0, 3]] {
                return NetBoxFixtureResponse(body: """
                {"jsonrpc":"2.0","id":1,"result":[
                  {"itemid":"1","name":"Octets","key_":"if.octets","value_type":"3","units":"B","delay":"1m"},
                  {"itemid":"2","name":"Load","key_":"system.load","value_type":0,"units":"","delay":"{$INTERVAL}"},
                  {"itemid":"3","name":"Hidden history","key_":"restricted","value_type":0,"units":"","delay":""},
                  {"itemid":"4","name":"Invalid counter","key_":"invalid.counter","value_type":3,"units":"","delay":""},
                  {"itemid":"5","name":"Invalid history order","key_":"invalid.history","value_type":0,"units":"","delay":""}
                ]}
                """)
            }
            guard call.method == "history.get", params.sortfield == ["clock", "ns"], params.limit == 501 else {
                return NetBoxFixtureResponse(status: 400, body: "{}")
            }
            if params.itemids == ["1"], params.history == 3 {
                if params.time_from == clock - 900, params.time_till == clock, params.sortorder == "DESC" {
                    let rows = (0...500).reversed().map { "{\"clock\":\"\(clock)\",\"ns\":\"\($0)\",\"value\":18446744073709551615}" }
                    return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\(rows.joined(separator: ","))]}")
                }
                if params.time_from == clock + 1, params.time_till == clock + 900, params.sortorder == "ASC" {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock + 900),"ns":0,"value":"123"}]}
                    """)
                }
            }
            if params.itemids == ["2"], params.history == 0 {
                if params.time_from == clock + 1, params.time_till == clock + 1_800, params.sortorder == "ASC" {
                    let rows = (1...501).map { "{\"clock\":\(clock + $0),\"ns\":0,\"value\":\"-0.25\"}" }
                    return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\(rows.joined(separator: ","))]}")
                }
                return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}")
            }
            if params.itemids == ["3"], params.history == 0 {
                if params.sortorder == "DESC", params.time_from == clock - 300 || params.time_from == clock - 900 {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock),"ns":0,"value":"1.25"}]}
                    """)
                }
                if params.sortorder == "ASC", params.time_till == clock + 300 {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock + 301),"ns":0,"value":"1.25"}]}
                    """)
                }
                if params.sortorder == "ASC", params.time_till == clock + 900 {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock + 1),"ns":0,"value":"NaN"}]}
                    """)
                }
                return NetBoxFixtureResponse(body: """
                {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"No permissions to call history.get. \(token)"}}
                """)
            }
            if params.itemids == ["4"], params.history == 3 {
                if params.sortorder == "DESC" {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock),"ns":0,"value":"0"}]}
                    """)
                }
                let invalidValues = [clock + 300: "-1", clock + 900: "0.5", clock + 1_800: "18446744073709551616"]
                if let upperBound = params.time_till, let invalidValue = invalidValues[upperBound] {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[{"clock":\(clock + 1),"ns":0,"value":"\(invalidValue)"}]}
                    """)
                }
            }
            if params.itemids == ["5"], params.history == 0 {
                if params.time_from == clock - 300 && params.sortorder == "DESC" {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[
                      {"clock":\(clock - 1),"ns":0,"value":"1.25"},
                      {"clock":\(clock),"ns":0,"value":"1.25"}
                    ]}
                    """)
                }
                if params.time_till == clock + 900 && params.sortorder == "ASC" {
                    return NetBoxFixtureResponse(body: """
                    {"jsonrpc":"2.0","id":1,"result":[
                      {"clock":\(clock + 1),"ns":1,"value":"1.25"},
                      {"clock":\(clock + 1),"ns":0,"value":"1.25"}
                    ]}
                    """)
                }
                if params.time_till == clock + 1_800 && params.sortorder == "ASC" {
                    let rows = (1...502).map { "{\"clock\":\(clock + $0),\"ns\":0,\"value\":\"1.25\"}" }
                    return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[\(rows.joined(separator: ","))]}")
                }
                return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}")
            }
            return NetBoxFixtureResponse(status: 400, body: "{}")
        }
        defer { server.stop() }

        let reference = "zabbix-history-fixture-reference"
        let client = ZabbixClient(configuration: ZabbixConfiguration(baseURL: server.baseURL,
                                                                     tokenReference: reference, timeout: 3), token: token)
        let host = try JSONDecoder().decode(ZabbixHost.self, from: Data("""
        {"hostID":"5001","technicalName":"gw-01","displayName":"Gateway 01"}
        """.utf8))
        var problem = try JSONDecoder().decode(ZabbixProblem.self, from: Data("""
        {"eventID":"9001","triggerID":"7001","clock":\(clock),"name":"Gateway unreachable","severity":5,
         "acknowledged":false,"operationalData":"","hosts":[]}
        """.utf8))
        let items = try await client.fetchNumericMetrics(for: host)
        try check(items.map(\.id) == ["1", "2", "3", "4", "5"] && items.first?.units == "B" && items.first?.key == "if.octets",
                  "Zabbix limits the item query to numeric metrics on the selected host and retains metadata")
        let complete = Date(timeIntervalSince1970: Double(clock + 901))
        let history = try await client.fetchMetricHistory(for: items[0], problem: problem, window: .fifteen, now: complete)
        try check(history.range == (clock - 900)...(clock + 900) && !history.afterWindowOpen, "Zabbix preserves the inclusive 15-minute boundaries")
        try check(history.beforeOrAtLimitReached && !history.afterLimitReached && history.samples.count == 501,
                  "Zabbix independently caps each side at the 500 samples nearest the alert")
        try check(history.samples.prefix(500).map(\.nanoseconds) == Array(1...500) && history.samples.last?.seconds == clock + 900,
                  "Zabbix preserves chronological order and distinct samples in the alert second")
        try check(history.samples.first?.rawValue == "18446744073709551615", "Zabbix preserves an unsigned 64-bit reading exactly")
        let empty = try await client.fetchMetricHistory(for: items[1], problem: problem, window: .five,
                                                        now: Date(timeIntervalSince1970: Double(clock)))
        try check(empty.samples.isEmpty && empty.afterWindowOpen && !empty.beforeOrAtLimitReached && !empty.afterLimitReached,
                  "Zabbix distinguishes an empty result from a still-open or truncated window")
        let after = try await client.fetchMetricHistory(for: items[1], problem: problem, window: .thirty)
        try check(!after.beforeOrAtLimitReached && after.afterLimitReached && after.samples.count == 500,
                  "Zabbix independently reports truncation after the alert")
        try check(after.samples.first?.rawValue == "-0.25" && after.samples.last?.seconds == clock + 500,
                  "Zabbix preserves a floating point value and retains the nearest post-alert samples")

        if testPersistence {
            var observedHost = host
            observedHost.displayName += " \(token) \(reference) password=fixture-freetext-secret"
            let metric = client.metricObservation(for: items[0], history: history, problem: problem, host: observedHost)
            let emptyMetric = client.metricObservation(for: items[1], history: empty, problem: problem, host: observedHost)
            server.stop()
            try metricPersistence(metric, emptyMetric: emptyMetric,
                                  secrets: [token, reference, "fixture-freetext-secret"])
            return
        }

        do {
            _ = try await client.fetchMetricHistory(for: items[2], problem: problem, window: .thirty)
            throw CheckFailure(description: "Zabbix returned a result for a rejected history request")
        } catch ZabbixError.api(let code, let message) {
            try check(code == -32602 && message.contains("No permissions") && !message.contains(token), "Zabbix preserves the permission error and redacts the token")
        }

        for window in [ZabbixMetricHistory.Window.five, .fifteen] {
            do {
                _ = try await client.fetchMetricHistory(for: items[2], problem: problem, window: window)
                throw CheckFailure(description: "Zabbix returned partial history after receiving an out-of-window or non-finite sample")
            } catch ZabbixError.invalidResponse {}
        }

        for window in ZabbixMetricHistory.Window.allCases {
            do {
                _ = try await client.fetchMetricHistory(for: items[3], problem: problem, window: window)
                throw CheckFailure(description: "Zabbix accepted a negative, fractional or overflowing unsigned counter")
            } catch ZabbixError.invalidResponse {}
        }

        for window in ZabbixMetricHistory.Window.allCases {
            do {
                _ = try await client.fetchMetricHistory(for: items[4], problem: problem, window: window)
                throw CheckFailure(description: "Zabbix accepted unordered history or more rows than requested for the \(window.rawValue)-minute window")
            } catch ZabbixError.invalidResponse {}
        }

        let requestCount = server.requests.count
        problem.clock = 0
        do {
            _ = try await client.fetchMetricHistory(for: items[0], problem: problem, window: .fifteen)
            throw CheckFailure(description: "Zabbix accepted a missing problem timestamp")
        } catch ZabbixError.invalidProblemTime {
            try check(server.requests.count == requestCount, "Zabbix rejects an invalid problem timestamp before requesting history")
        }
    }

    private static func metricPersistence(_ metric: FieldMetricObservation, emptyMetric: FieldMetricObservation,
                                          secrets: [String]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMMetric-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("metric.nmfieldproject")
        let database = directory.appendingPathComponent("cases.sqlite")
        let caseRecord = FieldIncident(title: "Gateway unreachable", owner: "Engineer", ticketReference: "OPS-9001",
                                       entries: [.init(kind: .reported, author: "Engineer", detail: "Alert received")])
        let otherCase = FieldIncident(title: "Unrelated incident", owner: "Engineer")
        var project = FieldProject()
        try project.saveIncident(caseRecord)
        try project.saveIncident(otherCase)
        let oldBytes = try project.encoded()
        try oldBytes.write(to: file)
        let oldProject = try FieldProject.decode(Data(contentsOf: file))
        try check(oldProject.incidents.first?.entries == caseRecord.entries, "The old project timeline still opens")
        let library = FieldCaseLibrary(url: database)
        let revision = try library.importProject(oldProject, from: file, expectedRevision: nil)

        let entry = FieldIncidentEntry(kind: .metricObserved, occurredAt: Date(timeIntervalSince1970: Double(metric.alertSecond)),
                                       author: "Engineer", detail: metric.itemName, metricObservation: metric)
        do {
            try project.appendIncidentEntry(entry, to: UUID())
            throw CheckFailure(description: "An unknown Case accepted an observation")
        } catch FieldIncidentError.missingIncident {
            let unchanged = try project.encoded()
            try check(unchanged == oldBytes, "A failed attachment keeps the original document")
        }
        try project.appendIncidentEntry(entry, to: caseRecord.id)
        try project.appendIncidentEntry(.init(kind: .metricObserved, occurredAt: entry.occurredAt, author: "Engineer",
                                               detail: emptyMetric.itemName, metricObservation: emptyMetric), to: caseRecord.id)
        let data = try project.encoded()
        let saved = String(decoding: data, as: UTF8.self)
        try check(saved.contains("\"schemaVersion\" : 7") && !saved.contains("/ops") && secrets.allSatisfy { !saved.contains($0) },
                  "The new project version stores the origin and digest and excludes endpoint paths and credentials")
        try data.write(to: file, options: .atomic)
        let reopened = try FieldProject.decode(Data(contentsOf: file))
        try check(reopened.incidents.first?.entries[1].metricObservation == metric &&
                  reopened.incidents.first?.entries[2].metricObservation == emptyMetric &&
                  reopened.incidents.last == otherCase, "Offline reopening preserves the exact selected observations")
        _ = try library.importProject(reopened, from: file, expectedRevision: revision)
        try FileManager.default.removeItem(at: file)
        let reopenedLibrary = FieldCaseLibrary(url: database)
        let matches = try reopenedLibrary.search(FieldIncidentQuery(ticketReference: "OPS-9001"))
        guard let result = matches.results.first else { throw CheckFailure(description: "Missing imported metric Case") }
        let entries = try reopenedLibrary.observations(for: result.id)
        try check(entries == result.incident.timeline && entries.compactMap(\.metricObservation).count == 2,
                  "Both offline library views preserve the complete timeline after reimport")

        let markdown = FieldIncidentExporter.markdown(for: result.incident, retestRuns: [])
        let json = try FieldIncidentExporter.json(for: result.incident, retestRuns: [])
        let jsonText = String(decoding: json, as: UTF8.self)
        struct Export: Decodable {
            struct Observation: Decodable { let metricObservation: FieldMetricObservation? }
            let schemaVersion: Int
            let observations: [Observation]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(Export.self, from: json)
        let snapshots = exported.observations.compactMap(\.metricObservation)
        try check(exported.schemaVersion == 2 && snapshots.contains { $0.samples == metric.samples && $0.beforeOrAtLimitReached } &&
                  snapshots.contains { $0.samples.isEmpty && $0.afterWindowOpen }, "JSON retains full precision and window status")
        try check(markdown.contains("1730000000.000000001") && markdown.contains("18446744073709551615") &&
                  markdown.contains(metric.instanceID), "Markdown contains exact sample time and value plus the instance identifier")
        try check((secrets + [file.path, "/ops"]).allSatisfy { !jsonText.contains($0) && !markdown.contains($0) },
                  "Neither sharing format exposes credentials, endpoint paths or the project path")
    }

    @MainActor
    static func run() async throws {
        let token = "fixture-zabbix-secret"
        let server = try NetBoxFixtureServer { request, _ in
            guard request.path == "/ops/api_jsonrpc.php", request.method == "POST" else {
                return NetBoxFixtureResponse(status: 404, body: "{}")
            }
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let method = json["method"] as? String else {
                return NetBoxFixtureResponse(status: 400, body: "{}")
            }
            switch method {
            case "problem.get":
                return NetBoxFixtureResponse(body: """
                {"jsonrpc":"2.0","result":[{"eventid":"9001","objectid":"7001","clock":"1730000000","name":"Gateway unreachable","severity":"5","acknowledged":"0","opdata":"No response"}],"id":1}
                """)
            case "trigger.get":
                return NetBoxFixtureResponse(body: """
                {"jsonrpc":"2.0","result":[{"triggerid":"7001","hosts":[{"hostid":"5001","host":"gw-01","name":"Gateway 01"}]}],"id":1}
                """)
            case "host.get":
                return NetBoxFixtureResponse(body: """
                {"jsonrpc":"2.0","result":[{"hostid":"5001","host":"gw-01","name":"Gateway 01","interfaces":[{"ip":"192.0.2.1","dns":"secondary.example","useip":"1","main":"0"},{"ip":"127.0.0.1","dns":"gateway.example","useip":"1","main":"1"}]}],"id":1}
                """)
            default:
                return NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":1}")
            }
        }
        defer { server.stop() }

        try check(ZabbixConnectionPolicy.permits(URL(string: "https://zabbix.example/zabbix")!), "Zabbix HTTPS is allowed")
        try check(ZabbixConnectionPolicy.permits(server.baseURL), "Zabbix loopback HTTP fixture is allowed")
        try check(!ZabbixConnectionPolicy.permits(URL(string: "http://zabbix.example")!), "Zabbix blocks non-loopback HTTP token transmission")
        try check(!ZabbixConnectionPolicy.permits(URL(string: "https://user:secret@zabbix.example")!), "Zabbix rejects credentials embedded in the URL")

        let configuration = ZabbixConfiguration(baseURL: server.baseURL, tokenReference: "fixture-keychain-ref", timeout: 3)
        let client = ZabbixClient(configuration: configuration, token: token)
        let request = try client.makeProblemRequest()
        try check(request.httpMethod == "POST", "Zabbix uses JSON-RPC POST")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)", "Zabbix token uses the Authorization Bearer header")
        try check(request.url?.path == "/ops/api_jsonrpc.php", "Zabbix API endpoint preserves a frontend subpath")
        let problems = try await client.fetchActiveProblems()
        try check(problems.count == 1, "Zabbix decodes active problem records")
        try check(problems[0].eventID == "9001" && problems[0].severity == 5 && !problems[0].acknowledged, "Zabbix problem identity and state map correctly")
        try check(problems[0].hosts.first?.displayName == "Gateway 01" && problems[0].hosts.first?.target == "127.0.0.1", "Zabbix trigger maps to the selected host interface target")
        try check(problems[0].operationalData == "No response", "Zabbix operational data is retained")

        let evidenceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NMZabbixEvidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }
        let evidenceStore = AssetStore(storageURL: evidenceDirectory.appendingPathComponent("assets.json"))
        guard let matchedDevice = evidenceStore.devices.first(where: { $0.address == "127.0.0.1" }) else {
            throw CheckFailure(description: "Local workspace should include its loopback operator asset")
        }
        let evidenceID = await ZabbixDiagnosticRunner.ping(problem: problems[0], host: problems[0].hosts[0], in: evidenceStore)
        guard let evidenceID, let evidence = evidenceStore.diagnosticRuns.first(where: { $0.id == evidenceID }) else {
            throw CheckFailure(description: "Zabbix alert ping should save a diagnostic record")
        }
        try check(evidence.status == .succeeded && evidence.deviceID == matchedDevice.id, "Zabbix alert ping saves successful evidence linked to a uniquely matching local asset")
        try check(evidence.parameters["eventID"] == "9001" && evidence.parameters["source"] == "Zabbix", "Zabbix ping evidence retains source event context")
        try check(evidence.source == "Zabbix · PING" && evidence.target == "127.0.0.1", "Zabbix alert evidence records source and probed interface")
        try check(DiagnosticHistorySearch.matches(evidence, query: "9001") && DiagnosticHistorySearch.matches(evidence, query: "9002") == false,
                  "diagnostic history can locate Zabbix evidence by exact event context")
        let timeoutRunID = await ZabbixDiagnosticRunner.ping(problem: problems[0], host: problems[0].hosts[0], in: evidenceStore) { _ in
            DiagnosticExecutionResult(status: .timedOut, summary: "Timed out", source: "fixture")
        }
        try check(timeoutRunID.flatMap { id in evidenceStore.diagnosticRuns.first { $0.id == id }?.status } == .timedOut,
                  "Zabbix alert ping preserves timeout status for immediate UI feedback and history")
        let duplicateDevice = AssetDevice(siteID: matchedDevice.siteID, name: "Ambiguous duplicate", address: "127.0.0.1")
        evidenceStore.upsert(duplicateDevice)
        let ambiguousEvidenceID = await ZabbixDiagnosticRunner.ping(problem: problems[0], host: problems[0].hosts[0], in: evidenceStore)
        try check(ambiguousEvidenceID.flatMap { id in evidenceStore.diagnosticRuns.first { $0.id == id }?.deviceID } == nil,
                  "Zabbix evidence stays independent when a target matches multiple local assets")

        let requests = server.requests
        try check(requests.count == 3 && requests.allSatisfy { $0.method == "POST" }, "Zabbix performs only the three expected JSON-RPC reads")
        try check(requests.allSatisfy { $0.headers["authorization"] == "Bearer \(token)" }, "Zabbix attaches the configured bearer token")
        try check(requests.allSatisfy { $0.headers["content-type"]?.contains("application/json-rpc") == true }, "Zabbix declares JSON-RPC content type")
        let methods = requests.compactMap { request -> String? in
            (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["method"] as? String
        }
        try check(methods == ["problem.get", "trigger.get", "host.get"], "Zabbix connector makes only active problem and host metadata reads")
        let firstParams = (try? JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])?["params"] as? [String: Any]
        try check(firstParams?["source"] as? Int == 0 && firstParams?["object"] as? Int == 0,
                  "Zabbix problem query is restricted to trigger-generated problems")

        let beforeMissingToken = server.requests.count
        let missingTokenClient = ZabbixClient(configuration: configuration, token: nil)
        do {
            _ = try await missingTokenClient.fetchActiveProblems()
            throw CheckFailure(description: "Zabbix accepted a missing token")
        } catch ZabbixError.missingToken {
        }
        try check(server.requests.count == beforeMissingToken, "missing Zabbix token sends no request")

        let errorToken = "error-response-secret"
        let errorServer = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(body: """
            {"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params","data":"Rejected token \(errorToken)"},"id":1}
            """)
        }
        defer { errorServer.stop() }
        let errorClient = ZabbixClient(configuration: ZabbixConfiguration(baseURL: errorServer.baseURL), token: errorToken)
        do {
            _ = try await errorClient.fetchActiveProblems()
            throw CheckFailure(description: "Zabbix JSON-RPC error was accepted")
        } catch ZabbixError.api(let code, let message) {
            try check(code == -32602 && !message.contains(errorToken) && message.contains("[REDACTED]"), "Zabbix JSON-RPC errors redact tokens")
        }

        let oversizedZabbixServer = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(body: String(repeating: "z", count: ZabbixClient.maxResponseBytes + 1))
        }
        defer { oversizedZabbixServer.stop() }
        let oversizedZabbixClient = ZabbixClient(configuration: ZabbixConfiguration(baseURL: oversizedZabbixServer.baseURL), token: token)
        do {
            _ = try await oversizedZabbixClient.fetchActiveProblems()
            throw CheckFailure(description: "Zabbix accepted a response above the byte cap")
        } catch ZabbixError.responseTooLarge(let limit) {
            try check(limit == ZabbixClient.maxResponseBytes, "Zabbix reports its strict response byte cap")
        }

        let emptyServer = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(body: "{\"jsonrpc\":\"2.0\",\"result\":[],\"id\":1}")
        }
        defer { emptyServer.stop() }
        let emptyClient = ZabbixClient(configuration: ZabbixConfiguration(baseURL: emptyServer.baseURL), token: token)
        let emptyProblems = try await emptyClient.fetchActiveProblems()
        try check(emptyProblems.isEmpty && emptyServer.requests.count == 1, "empty active problem queue stops after problem.get")

        let sink = try NetBoxFixtureServer { _, _ in NetBoxFixtureResponse(body: "{\"captured\":true}") }
        defer { sink.stop() }
        let redirector = try NetBoxFixtureServer { _, _ in
            NetBoxFixtureResponse(status: 302, body: "{}", headers: ["Location": "http://127.0.0.1:\(sink.port)/capture"])
        }
        defer { redirector.stop() }
        let redirectClient = ZabbixClient(configuration: ZabbixConfiguration(baseURL: redirector.baseURL, timeout: 3), token: token)
        do {
            _ = try await redirectClient.fetchActiveProblems()
            throw CheckFailure(description: "Zabbix cross-origin redirect was followed")
        } catch ZabbixError.httpStatus(let status, _) {
            try check(status == 302, "Zabbix cross-origin redirect is returned as an HTTP failure")
        }
        try check(sink.requests.isEmpty, "Zabbix bearer token is not forwarded to a different origin")
    }
}
