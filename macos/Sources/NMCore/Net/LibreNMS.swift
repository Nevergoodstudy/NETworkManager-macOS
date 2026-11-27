import Foundation

package struct LibreNMSLink: Codable, Hashable, Identifiable, Sendable {
    package let id: Int
    package let localPortID: Int
    package let localPort: String?
    package let remoteDeviceID: Int?
    package let remotePortID: Int?
    package let remoteHost: String?
    package let remotePort: String?
    package let discoveryProtocol: String?
    package let active: Bool

    package var remoteLabel: String {
        let host = remoteHost ?? remoteDeviceID.map { "#\($0)" } ?? t("Unknown")
        let port = remotePort ?? remotePortID.map { "#\($0)" } ?? t("Unknown")
        return "\(host) / \(port)"
    }

    package func conflicts(with inventory: AssetNetworkInventory?) -> Bool {
        guard active, let localPort, let remoteHost, let remotePort, let inventory else { return false }
        let matches = inventory.interfaces.filter { $0.name == localPort }
        guard matches.count == 1, case let .assigned(_, peers?) = matches[0].configuredCable,
              peers.count == 1, let peer = peers.first, peer.kind == .interface else { return false }
        return peer.deviceName.caseInsensitiveCompare(remoteHost) != .orderedSame || peer.portName != remotePort
    }
}

package struct LibreNMSLinkSnapshot: Codable, Hashable, Sendable {
    package let source: URL
    package let deviceID: Int
    package let fetchedAt: Date
    package let links: [LibreNMSLink]

    package func isStale(at date: Date) -> Bool { date.timeIntervalSince(fetchedAt) >= 86_400 }
}

package enum LibreNMS {
    private struct Envelope<Record: Decodable>: Decodable {
        let status: String
        let count: Int
        let links: [Record]?
        let ports: [Record]?
    }

    private struct APIError: Decodable {
        let status: String
        let message: String
    }

    private struct Link: Decodable {
        let id: Int
        let local_port_id: Int
        let local_device_id: Int
        let remote_port_id: Int?
        let remote_device_id: Int?
        let remote_hostname: String?
        let remote_port: String?
        let active: Int
        let linkProtocol: String?
        enum CodingKeys: String, CodingKey {
            case id, local_port_id, local_device_id, remote_port_id, remote_device_id, remote_hostname, remote_port, active
            case linkProtocol = "protocol"
        }
    }

    private struct Port: Decodable {
        let portID: Int
        let ifName: String

        enum CodingKeys: String, CodingKey {
            case portID = "port_id"
            case ifName
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            ifName = try fields.decode(String.self, forKey: .ifName)
            if let number = try? fields.decode(Int.self, forKey: .portID) {
                portID = number
                return
            }
            guard let number = Int(try fields.decode(String.self, forKey: .portID)) else { throw ReadError.response }
            portID = number
        }
    }

    private enum ReadError: LocalizedError {
        case input, response, noVisibleLinks, http(Int)
        var errorDescription: String? {
            switch self {
            case .input: t("Enter a LibreNMS HTTPS URL, device ID and API token.")
            case .response: t("LibreNMS returned an invalid or incomplete response.")
            case .noVisibleLinks: t("LibreNMS returned no visible links for this device.")
            case .http(let status): tf("LibreNMS returned HTTP %d.", status)
            }
        }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    package static func readLinks(baseURL: String, deviceID: Int, token: String) async throws -> LibreNMSLinkSnapshot {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = base.host, !host.isEmpty, base.user == nil, base.password == nil, base.query == nil,
              base.fragment == nil, deviceID > 0, !token.isEmpty, token.utf8.count <= 1024,
              token.utf8.allSatisfy({ (33...126).contains($0) }),
              base.scheme?.lowercased() == "https" || (base.scheme?.lowercased() == "http" && host == "127.0.0.1") else {
            throw ReadError.input
        }
        base.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        base.path = base.path.isEmpty ? "" : "/" + base.path
        guard let source = base.url else { throw ReadError.input }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func read<Record: Decodable>(_ type: Record.Type, _ endpoint: String, query: [URLQueryItem] = []) async throws -> Envelope<Record> {
            var url = base
            url.path += "/api/v0/devices/\(deviceID)/\(endpoint)"
            if !query.isEmpty { url.queryItems = query }
            guard let endpointURL = url.url else { throw ReadError.input }
            var request = URLRequest(url: endpointURL, timeoutInterval: 10)
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadError.response }
            let canReportMissingLinks = http.statusCode == 404 && endpoint == "links"
            guard http.statusCode == 200 || canReportMissingLinks else { throw ReadError.http(http.statusCode) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_097_152 else { throw ReadError.response }
                data.append(byte)
            }
            if canReportMissingLinks {
                if let error = try? JSONDecoder().decode(APIError.self, from: data),
                   error.status == "error", error.message == "Links do not exist" {
                    throw ReadError.noVisibleLinks
                }
                throw ReadError.http(http.statusCode)
            }
            let result = try JSONDecoder().decode(Envelope<Record>.self, from: data)
            guard result.status == "ok", (0...2048).contains(result.count) else { throw ReadError.response }
            return result
        }

        let linkReply = try await read(Link.self, "links")
        guard let links = linkReply.links, links.count == linkReply.count,
              Set(links.map(\.id)).count == links.count,
              links.allSatisfy({ $0.id > 0 && $0.local_port_id > 0 && $0.local_device_id == deviceID &&
                  (0...1).contains($0.active) }) else { throw ReadError.response }
        if links.isEmpty {
            return LibreNMSLinkSnapshot(source: source, deviceID: deviceID, fetchedAt: Date(), links: [])
        }
        let portReply = try await read(Port.self, "ports", query: [URLQueryItem(name: "columns", value: "port_id,ifName")])
        guard let ports = portReply.ports, ports.count == portReply.count else { throw ReadError.response }
        var names: [Int: String] = [:]
        for port in ports {
            guard port.portID > 0, !port.ifName.isEmpty, port.ifName.count <= 200,
                  names.updateValue(port.ifName, forKey: port.portID) == nil else { throw ReadError.response }
        }
        func displayValue(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.count <= 200, !value.contains(token) else { return nil }
            return value
        }
        return LibreNMSLinkSnapshot(source: source, deviceID: deviceID, fetchedAt: Date(), links: links.map { link in
            LibreNMSLink(id: link.id, localPortID: link.local_port_id, localPort: displayValue(names[link.local_port_id]),
                         remoteDeviceID: link.remote_device_id, remotePortID: link.remote_port_id,
                         remoteHost: displayValue(link.remote_hostname), remotePort: displayValue(link.remote_port),
                         discoveryProtocol: displayValue(link.linkProtocol), active: link.active == 1)
        })
    }
}
