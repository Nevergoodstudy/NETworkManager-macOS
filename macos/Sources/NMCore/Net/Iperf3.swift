import Foundation
import Network

public enum Iperf3 {
    public enum Direction: String, Encodable, Sendable {
        case forward, reverse
    }

    public enum Failure: Error {
        case invalidRequest
        case process(CommandResult)
        case outputTruncated
        case invalidReport
    }

    public struct Transfer: Codable, Sendable {
        public let bytes: UInt64
        public let seconds: Double
        public let bitsPerSecond: Double
    }

    public struct Measurement: Encodable, Sendable {
        public let completedAt: Date
        public let direction: Direction
        public let requestedHost: String
        public let requestedSeconds: Int
        public let targetBitsPerSecond: Int
        public let localAddress: String
        public let localAddressInterfaces: [String]
        public let remoteAddress: String
        public let remotePort: Int
        public let clientVersion: String
        public let sender: Transfer
        public let receiver: Transfer

        public func reportJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(ExportReport(measurement: self))
        }
    }

    private struct ExportReport: Encodable {
        let schemaVersion = 1
        let measurement: Measurement
    }

    public static func measure(host: String, port: Int, direction: Direction, seconds: Int,
                               bitsPerSecond: Int, cancellation: DiagnosticCancellation? = nil,
                               executable: URL? = nil) async throws -> Measurement {
        guard validServerHost(host), (1...65_535).contains(port),
              (1...10).contains(seconds), (1...10_000_000).contains(bitsPerSecond) else {
            throw Failure.invalidRequest
        }

        var arguments = ["--client", host, "--port", String(port), "--json", "--parallel", "1",
                         "--time", String(seconds), "-b", String(bitsPerSecond), "--interval", "0"]
        if direction == .reverse { arguments.append("--reverse") }
        let job = ProcessJobSpec(operation: .command, targetScope: host,
                                 deadline: Date().addingTimeInterval(Double(seconds + 5)),
                                 maximumOutputBytesPerStream: 64 * 1_024, cancellation: cancellation)
        let scoped = executable?.startAccessingSecurityScopedResource() == true
        defer { if scoped { executable?.stopAccessingSecurityScopedResource() } }
        let result = await Shell.runTool(executable?.path ?? "iperf3", arguments, job: job)
        guard result.succeeded else { throw Failure.process(result) }
        guard !result.stdoutTruncated else { throw Failure.outputTruncated }
        return try decodeReport(result.stdout, host: host, port: port, direction: direction,
                                seconds: seconds, bitsPerSecond: bitsPerSecond)
    }

    private static func validServerHost(_ host: String) -> Bool {
        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return ServiceProbeEndpoint.validHost(host) }
        // iperf3 treats a zone on other host types as a device-binding option.
        return IPv6Address(String(parts[0]))?.isLinkLocal == true &&
            parts[1].wholeMatch(of: #/[A-Za-z0-9_.-]{1,15}/#) != nil
    }

    static func decodeReport(_ stdout: String, host: String, port: Int, direction: Direction,
                             seconds: Int, bitsPerSecond: Int,
                             interfaces: [NetworkInterfaceInfo] = NetworkInterfaces.list(includeLoopback: true)) throws -> Measurement {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(Report.self, from: Data(stdout.utf8)),
              report.error == nil,
              report.start.testStart.protocol == "TCP",
              report.start.testStart.numStreams == 1,
              report.start.testStart.reverse == (direction == .reverse ? 1 : 0),
              report.start.connected.count == 1, let connection = report.start.connected.first,
              connection.remotePort == port, !connection.localHost.isEmpty, !connection.remoteHost.isEmpty,
              !report.start.version.isEmpty,
              report.end.sumSent.seconds > 0, report.end.sumSent.bitsPerSecond >= 0,
              report.end.sumReceived.seconds > 0, report.end.sumReceived.bitsPerSecond >= 0 else {
            throw Failure.invalidReport
        }
        let localAddressInterfaces = matchingInterfaces(for: connection.localHost, in: interfaces)
        return Measurement(completedAt: Date(), direction: direction, requestedHost: host, requestedSeconds: seconds,
                           targetBitsPerSecond: bitsPerSecond, localAddress: connection.localHost,
                           localAddressInterfaces: localAddressInterfaces,
                           remoteAddress: connection.remoteHost, remotePort: connection.remotePort,
                           clientVersion: report.start.version, sender: report.end.sumSent, receiver: report.end.sumReceived)
    }

    private static func matchingInterfaces(for localAddress: String, in interfaces: [NetworkInterfaceInfo]) -> [String] {
        func addressBytes(_ address: String) -> Data? {
            let literal = String(address.prefix { $0 != "%" })
            if let v4 = IPv4Address(literal) { return v4.rawValue }
            guard let v6 = IPv6Address(literal) else { return nil }
            if v6.isIPv4Mapped { return v6.asIPv4?.rawValue }
            return v6.rawValue
        }
        guard let localBytes = addressBytes(localAddress) else { return [] }
        return Set(interfaces.filter { addressBytes($0.address) == localBytes }.map(\.name)).sorted()
    }

    private struct Report: Decodable {
        let error: String?
        let start: Start
        let end: End

        struct Start: Decodable {
            let version: String
            let connected: [Connection]
            let testStart: TestStart

            struct Connection: Decodable {
                let localHost: String
                let remoteHost: String
                let remotePort: Int
            }

            struct TestStart: Decodable {
                let `protocol`: String
                let numStreams: Int
                let reverse: Int
            }
        }

        struct End: Decodable {
            let sumSent: Transfer
            let sumReceived: Transfer
        }
    }
}
