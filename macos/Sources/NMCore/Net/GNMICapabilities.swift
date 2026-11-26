import Foundation

public enum GNMICapabilities {
    public struct Report: Decodable, Sendable {
        public struct Model: Decodable, Hashable, Sendable {
            public let name: String
            public let organization: String?
            public let version: String?
        }

        public let gNMIVersion: String
        public let supportedModels: [Model]?
        public let supportedEncodings: [String]?
    }

    public struct InterfaceState: Sendable {
        public enum Status: String, Decodable, Sendable {
            case up = "UP"
            case down = "DOWN"
            case testing = "TESTING"
            case unknown = "UNKNOWN"
            case dormant = "DORMANT"
            case notPresent = "NOT_PRESENT"
            case lowerLayerDown = "LOWER_LAYER_DOWN"
        }

        public let interface: String
        public let status: Status
        public let sampledAt: Date
    }

    public enum Failure: Error {
        case invalidTarget
        case invalidInterface
        case missingClient
        case invalidClient
        case cancelled
        case timedOut
        case requestFailed
        case invalidReport
        case missingInterfaceState
    }

    public static func read(host: String, port: Int, certificateAuthority: URL? = nil,
                            executable: URL? = nil) async throws -> Report {
        try await read(host: host, port: port, client: executable?.path, certificateAuthority: certificateAuthority)
    }

    static func read(host: String, port: Int, client: String?, certificateAuthority: URL? = nil) async throws -> Report {
        let data = try await request(host: host, port: port, client: client, certificateAuthority: certificateAuthority,
                                     arguments: ["capabilities"])
        guard let report = try? JSONDecoder().decode(Report.self, from: data), !report.gNMIVersion.isEmpty else {
            throw Failure.invalidReport
        }
        return report
    }

    public static func readInterfaceState(host: String, port: Int, interface: String,
                                          certificateAuthority: URL? = nil, executable: URL? = nil) async throws -> InterfaceState {
        try await readInterfaceState(host: host, port: port, interface: interface, client: executable?.path,
                                     certificateAuthority: certificateAuthority)
    }

    static func readInterfaceState(host: String, port: Int, interface: String, client: String?,
                                   certificateAuthority: URL? = nil) async throws -> InterfaceState {
        let nameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:/@-")
        guard (1...128).contains(interface.utf8.count),
              interface.unicodeScalars.allSatisfy(nameCharacters.contains) else { throw Failure.invalidInterface }
        let path = "/interfaces/interface[name=\(interface)]/state/oper-status"
        let data = try await request(host: host, port: port, client: client, certificateAuthority: certificateAuthority,
                                     arguments: ["get", "--type", "STATE", "--encoding", "json_ietf", "--path", path])
        return try decodeInterfaceState(data, interface: interface)
    }

    static func decodeInterfaceState(_ data: Data, interface: String) throws -> InterfaceState {
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(GetResponse.self, from: data) else { throw Failure.invalidReport }
        guard let notifications = response.notification, !notifications.isEmpty else { throw Failure.missingInterfaceState }
        guard notifications.count == 1, let notification = notifications.first else { throw Failure.invalidReport }
        guard let updates = notification.update, !updates.isEmpty else { throw Failure.missingInterfaceState }
        guard updates.count == 1, let update = updates.first, let timestamp = Int64(notification.timestamp), timestamp > 0 else {
            throw Failure.invalidReport
        }
        let prefixOrigin = notification.prefix?.origin ?? ""
        let pathOrigin = update.path?.origin ?? ""
        let elements = (notification.prefix?.elem ?? []) + (update.path?.elem ?? [])
        guard prefixOrigin.isEmpty || pathOrigin.isEmpty,
              ["", "openconfig"].contains(prefixOrigin + pathOrigin),
              elements == [.init(name: "interfaces", key: nil), .init(name: "interface", key: ["name": interface]),
                           .init(name: "state", key: nil), .init(name: "oper-status", key: nil)],
              let status = try? decoder.decode(InterfaceState.Status.self, from: update.val.jsonIetfVal) else {
            throw Failure.invalidReport
        }
        return InterfaceState(interface: interface, status: status,
                              sampledAt: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000_000_000))
    }

    private static func request(host: String, port: Int, client override: String?, certificateAuthority: URL?,
                                arguments: [String]) async throws -> Data {
        guard ServiceProbeEndpoint.validHost(host), (1...65_535).contains(port) else { throw Failure.invalidTarget }
        guard let client = override ?? Shell.which("gnmic") else { throw Failure.missingClient }
        if override != nil, !FileManager.default.isExecutableFile(atPath: client) { throw Failure.invalidClient }
        let scoped = certificateAuthority?.startAccessingSecurityScopedResource() == true
        defer { if scoped { certificateAuthority?.stopAccessingSecurityScopedResource() } }
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nm-gnmi-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("gnmic.json")
        try Data("{}".utf8).write(to: config)
        // The explicit empty config and clean environment exclude gNMIc's default targets and credentials.
        var command = ["-i", "LC_ALL=C", client, "--config", config.path, "--address", target,
                       "--format", "protojson", "--no-prefix", "--insecure=false", "--skip-verify=false",
                       "--timeout", "5s", "--max-msg-size", "1048576"]
        if let certificateAuthority { command += ["--tls-ca", certificateAuthority.path] }
        let result = await Shell.run("/usr/bin/env", command + arguments, timeout: 7, maximumOutputBytesPerStream: 65_536)
        if result.cancelled || Task.isCancelled { throw Failure.cancelled }
        if result.timedOut { throw Failure.timedOut }
        guard result.succeeded else { throw Failure.requestFailed }
        guard !result.stdoutTruncated else { throw Failure.invalidReport }
        return Data(result.stdout.utf8)
    }

    private struct GetResponse: Decodable {
        struct Path: Decodable {
            struct Element: Decodable, Equatable {
                let name: String
                let key: [String: String]?
            }

            let origin: String?
            let elem: [Element]?
        }

        struct Notification: Decodable {
            struct Update: Decodable {
                struct Value: Decodable { let jsonIetfVal: Data }
                let path: Path?
                let val: Value
            }

            let timestamp: String
            let prefix: Path?
            let update: [Update]?
        }

        let notification: [Notification]?
    }
}
