import Darwin
import Foundation
import MCP
import NMCore

/// The small, explicitly exposed diagnostic surface shared by the stdio server.
/// No asset store, profile store, credentials, or GUI lifecycle is initialized.
public struct MCPToolService: Sendable {
    public let networkEnabled: Bool
    private let diagnostics = DiagnosticSlots()

    public init(networkEnabled: Bool) {
        self.networkEnabled = networkEnabled
    }

    public var tools: [Tool] {
        let timeout: Value = [
            "type": "number", "minimum": 0.1, "maximum": 5, "default": 2,
            "description": "One total network budget in seconds, including resolution and any protocol fallback. Bounded process cleanup may finish after this budget."
        ]
        let host: Value = ["type": "string", "minLength": 1, "maxLength": 253,
                           "description": "A hostname or unbracketed IPv4/IPv6 address; no URL or command options."]
        let port: Value = ["type": "integer", "minimum": 1, "maximum": 65_535]
        var result = [
            tool("network_interfaces", "List this Mac's IP network interfaces. Local interface addresses are returned to the calling client.",
                 properties: ["includeLoopback": ["type": "boolean", "default": false]]),
            tool("subnet_info", "Calculate an IPv4 subnet without sending network traffic. /31 and /32 follow point-to-point and single-host semantics.",
                 properties: ["cidr": ["type": "string", "minLength": 1, "maxLength": 18]], required: ["cidr"]),
            tool("port_lookup", "Look up a port number in the bundled service reference data. This does not test whether a service is running.",
                 properties: ["port": port], required: ["port"]),
            tool("mac_vendor_lookup", "Look up a MAC address or three-byte OUI in the bundled vendor reference data. Accepts plain hex or colon/hyphen separated octets.",
                 properties: ["mac": ["type": "string", "minLength": 6, "maxLength": 17]], required: ["mac"])
        ]
        if networkEnabled {
            result += [
                tool("ping", "Send one ICMP echo probe to an authorized host. Resolution, native ICMP and system-ping fallback share one total network budget. Subprocess cleanup is separately bounded.",
                     properties: ["host": host, "timeout": timeout], required: ["host"], network: true),
                tool("dns_lookup", "Resolve A/AAAA records with macOS resolver policy, including scoped resolvers, or set mode=server and provide a DNS server for a direct record query. No public resolver is selected implicitly. Responses may contain untrusted remote text. Resolution and UDP/TCP fallback share one total network budget.",
                     properties: ["host": host,
                                  "mode": ["type": "string", "enum": .array([.string("system"), .string("server")]), "description": "system uses macOS name-resolution policy for A/AAAA; server sends a direct DNS query to the supplied server."],
                                  "recordType": ["type": "string", "enum": .array(DNSRecordType.allCases.map { .string($0.displayName) }), "default": "A"],
                                  "server": ["type": "string", "minLength": 1, "maxLength": 253, "description": "Required in server mode and must be omitted in system mode."],
                                  "serverPort": port, "timeout": timeout], required: ["host"], network: true),
                tool("tcp_probe", "Attempt a single TCP connection to an authorized host and port. Does not send application commands. The timeout is one total budget for address resolution and all connection attempts.",
                     properties: ["host": host, "port": port, "timeout": ["type": "number", "minimum": 0.1, "maximum": 5, "default": 2, "description": "Total timeout in seconds, including resolution and all addresses."]], required: ["host", "port"], network: true)
            ]
        }
        return result
    }

    public func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard tools.contains(where: { $0.name == params.name }) else {
            throw MCPError.invalidParams("Unknown or disabled tool: \(params.name)")
        }
        do {
            if Task.isCancelled { return try response(["status": "cancelled"], tool: params.name, isError: true) }
            let value = try await execute(params)
            return try response(value, tool: params.name, isError: value["status"]?.stringValue != "succeeded")
        } catch let error as ToolArgumentError {
            return try response(["status": "failed", "error": ["code": .string(error.code), "message": .string(error.message)]],
                                tool: params.name, isError: true)
        }
    }

    private func execute(_ params: CallTool.Parameters) async throws -> [String: Value] {
        switch params.name {
        case "network_interfaces":
            let args = try Arguments(params.arguments, allowed: ["includeLoopback"])
            let includeLoopback = try args.boolean("includeLoopback", default: false)
            return ["status": "succeeded", "target": "local", "source": "NMCore.NetworkInterfaces", "interfaces": .array(
                NetworkInterfaces.list(includeLoopback: includeLoopback).map { item in
                    ["name": .string(item.name), "address": .string(item.address), "family": .string(item.family),
                     "netmask": .string(item.netmask), "isUp": .bool(item.isUp), "isLoopback": .bool(item.isLoopback)]
                })]
        case "subnet_info":
            let args = try Arguments(params.arguments, allowed: ["cidr"])
            let cidr = try args.string("cidr", maximum: 18)
            guard cidr.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 || $0 == 47 }),
                  let subnet = IPv4Subnet(cidr) else {
                throw ToolArgumentError("cidr must be an IPv4 address with an optional prefix from 0 through 32.")
            }
            return ["status": "succeeded", "target": .string(cidr), "source": "NMCore.IPv4Subnet", "cidr": .string(subnet.cidr),
                    "prefix": .int(subnet.prefix), "network": .string(subnet.network.description),
                    "mask": .string(subnet.maskDescription), "wildcard": .string(IPv4(raw: subnet.wildcard).description),
                    "broadcast": .string(subnet.broadcast.description), "firstHost": subnet.firstHost.map { .string($0.description) } ?? .null,
                    "lastHost": subnet.lastHost.map { .string($0.description) } ?? .null,
                    "usableHostCount": .int(subnet.usableHostCount), "totalAddressCount": .int(subnet.totalAddressCount)]
        case "port_lookup":
            let args = try Arguments(params.arguments, allowed: ["port"])
            let port = try args.integer("port", range: 1...65_535)
            return ["status": "succeeded", "target": .string(String(port)), "source": "NMCore.DataStore", "port": .int(port),
                    "records": .array(DataStore.shared.portInfo(number: port).map {
                        ["protocol": .string($0.proto), "name": .string($0.name), "description": .string($0.description)]
                    })]
        case "mac_vendor_lookup":
            let args = try Arguments(params.arguments, allowed: ["mac"])
            let mac = try normalizedMAC(args.string("mac", maximum: 17))
            let vendor = DataStore.shared.vendor(forMACAddress: mac)
            return ["status": "succeeded", "target": .string(mac), "source": "NMCore.DataStore", "mac": .string(mac),
                    "found": .bool(vendor != nil), "vendor": vendor.map(Value.string) ?? .null]
        case "ping":
            let args = try Arguments(params.arguments, allowed: ["host", "timeout"])
            let host = try validatedHost(args.string("host"))
            let timeout = try args.timeout()
            let result = try await diagnostic { await DiagnosticService.runPing(host: host, timeout: timeout) }
            return diagnosticValue(result, target: host)
        case "dns_lookup":
            let args = try Arguments(params.arguments, allowed: ["host", "mode", "recordType", "server", "serverPort", "timeout"])
            let host = try validatedHost(args.string("host"), dnsName: true)
            let server = try args.optionalString("server").map { try validatedHost($0) }
            let modeName = try args.optionalString("mode", maximum: 6) ?? (server == nil ? "system" : "server")
            guard let mode = DNSLookupMode(rawValue: modeName) else {
                throw ToolArgumentError("mode must be system or server.")
            }
            guard (mode == .server) == (server != nil) else {
                throw ToolArgumentError("system mode does not take server; server mode requires a DNS server.")
            }
            let typeName = try args.optionalString("recordType", maximum: 5) ?? "A"
            guard let type = DNSRecordType.allCases.first(where: { $0.displayName == typeName }) else {
                throw ToolArgumentError("recordType must be one of A, AAAA, NS, CNAME, SOA, PTR, MX, TXT, SRV, CAA.")
            }
            guard mode == .server || type == .a || type == .aaaa else {
                throw ToolArgumentError("system mode supports only A and AAAA records.")
            }
            let serverPort = try args.integer("serverPort", range: 1...65_535, default: 53)
            let timeout = try args.timeout()
            let result = try await diagnostic {
                await DiagnosticService.runDNS(host: host, recordType: type, server: server,
                                               serverPort: UInt16(serverPort), timeout: timeout, mode: mode)
            }
            var value = diagnosticValue(result, target: host)
            value["mode"] = .string(mode.rawValue)
            value["server"] = server.map(Value.string) ?? .null
            value["recordType"] = .string(typeName)
            value["dnsRecords"] = .array(result.dnsRecords.map {
                ["name": .string($0.name), "type": .string($0.type.displayName),
                 "ttl": $0.ttl.map { .int(Int($0)) } ?? .null, "value": .string($0.value)]
            })
            return value
        case "tcp_probe":
            let args = try Arguments(params.arguments, allowed: ["host", "port", "timeout"])
            let host = try validatedHost(args.string("host"))
            let port = try args.integer("port", range: 1...65_535)
            let timeout = try args.timeout()
            let result = try await diagnostic { await DiagnosticService.runTCP(host: host, port: port, timeout: timeout) }
            var value = diagnosticValue(result, target: host)
            value["port"] = .int(port)
            return value
        default:
            throw MCPError.invalidParams("Unknown or disabled tool: \(params.name)")
        }
    }

    private func diagnostic(_ operation: @Sendable () async -> DiagnosticExecutionResult) async throws -> DiagnosticExecutionResult {
        // Refuse excess work immediately: a client cannot grow an unbounded wait queue.
        guard await diagnostics.acquire() else { throw ToolArgumentError("Four diagnostics are already running. Retry after one finishes.", code: "busy") }
        let result = await operation()
        await diagnostics.release()
        return result
    }

    private func diagnosticValue(_ result: DiagnosticExecutionResult, target: String) -> [String: Value] {
        var value: [String: Value] = ["status": .string(result.status.rawValue), "target": .string(target), "source": .string(result.source),
         "summary": .string(result.summary), "detail": .string(result.detail),
         "latencySeconds": result.latency.map(Value.double) ?? .null]
        if let evidence = result.evidence, let encoded = try? JSONEncoder().encode(evidence),
           let metadata = try? JSONDecoder().decode(Value.self, from: encoded) {
            value["evidence"] = metadata
        }
        return value
    }

    private func response(_ payload: [String: Value], tool: String, isError: Bool = false) throws -> CallTool.Result {
        var payload = payload
        payload["tool"] = .string(tool)
        payload["observedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        let value = Value.object(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: isError)
    }

    private func tool(_ name: String, _ description: String, properties: [String: Value], required: [String] = [], network: Bool = false) -> Tool {
        Tool(name: name, description: description,
             inputSchema: ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false],
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: network))
    }
}

private actor DiagnosticSlots {
    private var active = 0

    func acquire() -> Bool {
        guard active < 4 else { return false }
        active += 1
        return true
    }

    func release() { active -= 1 }
}

private struct ToolArgumentError: Error {
    let message: String
    let code: String

    init(_ message: String, code: String = "invalid_arguments") {
        self.message = message
        self.code = code
    }
}

private struct Arguments {
    let values: [String: Value]

    init(_ values: [String: Value]?, allowed: Set<String>) throws {
        self.values = values ?? [:]
        let unknown = Set(self.values.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw ToolArgumentError("Unknown argument(s): \(unknown.sorted().joined(separator: ", ")).") }
    }

    func string(_ key: String, maximum: Int = 253) throws -> String {
        guard let value = values[key]?.stringValue, !value.isEmpty, value.utf8.count <= maximum else {
            throw ToolArgumentError("\(key) must be a nonempty string of at most \(maximum) bytes.")
        }
        return value
    }

    func optionalString(_ key: String, maximum: Int = 253) throws -> String? {
        guard values[key] != nil else { return nil }
        return try string(key, maximum: maximum)
    }

    func boolean(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard let boolean = value.boolValue else { throw ToolArgumentError("\(key) must be a boolean.") }
        return boolean
    }

    func integer(_ key: String, range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
        guard let value = values[key] else {
            if let fallback { return fallback }
            throw ToolArgumentError("\(key) is required.")
        }
        let integer: Int?
        switch value {
        case .int(let number): integer = number
        case .double(let number): integer = number.isFinite ? Int(exactly: number) : nil
        default: integer = nil
        }
        guard let integer, range.contains(integer) else {
            throw ToolArgumentError("\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return integer
    }

    func timeout() throws -> TimeInterval {
        guard let value = values["timeout"] else { return 2 }
        let number: Double
        switch value {
        case .int(let integer): number = Double(integer)
        case .double(let double): number = double
        default: throw ToolArgumentError("timeout must be a number of seconds from 0.1 through 5.")
        }
        guard number.isFinite, (0.1...5).contains(number) else {
            throw ToolArgumentError("timeout must be a finite number of seconds from 0.1 through 5.")
        }
        return number
    }
}

private func validatedHost(_ value: String, dnsName: Bool = false) throws -> String {
    let message = "host/server must be a hostname or unbracketed IP address, without spaces, URLs, or command options."
    guard !value.hasPrefix("-"), !value.isEmpty, value.utf8.count <= 253,
          value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw ToolArgumentError(message) }
    if value.contains(":") {
        let parts = value.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ToolArgumentError(message) }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.count <= 63,
                  parts[1].utf8.allSatisfy({ isASCIIAlphanumeric($0) || [45, 46, 95].contains($0) }) else { throw ToolArgumentError(message) }
        }
        var address = in6_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw ToolArgumentError(message) }
        return value
    }
    let name = value.hasSuffix(".") ? String(value.dropLast()) : value
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty, labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        && label.utf8.allSatisfy({ isASCIIAlphanumeric($0) || $0 == 45 || (dnsName && $0 == 95) })
    }) else { throw ToolArgumentError(message) }
    if name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }), name.contains(".") {
        guard labels.count == 4, IPv4(name) != nil else { throw ToolArgumentError(message) }
    }
    return value
}

private func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

private func normalizedMAC(_ value: String) throws -> String {
    let normalized: String
    if value.contains(":") || value.contains("-") {
        guard !(value.contains(":") && value.contains("-")) else { throw ToolArgumentError("mac must use consistent octet separators.") }
        let parts = value.split(separator: value.contains(":") ? ":" : "-", omittingEmptySubsequences: false)
        guard [3, 6].contains(parts.count), parts.allSatisfy({ $0.utf8.count == 2 }) else {
            throw ToolArgumentError("mac must contain three OUI octets or six MAC octets.")
        }
        normalized = parts.joined()
    } else {
        normalized = value
    }
    guard [6, 12].contains(normalized.utf8.count), normalized.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }) else { throw ToolArgumentError("mac must contain exactly 6 or 12 hexadecimal digits.") }
    return normalized.uppercased()
}
