import Foundation

// MARK: - Records

public enum DNSRecordType: UInt16, CaseIterable, Identifiable, Sendable {
    case a = 1
    case ns = 2
    case cname = 5
    case soa = 6
    case ptr = 12
    case mx = 15
    case txt = 16
    case aaaa = 28
    case srv = 33
    case caa = 257

    public var id: UInt16 { rawValue }

    public var displayName: String {
        switch self {
        case .a: return "A"
        case .ns: return "NS"
        case .cname: return "CNAME"
        case .soa: return "SOA"
        case .ptr: return "PTR"
        case .mx: return "MX"
        case .txt: return "TXT"
        case .aaaa: return "AAAA"
        case .srv: return "SRV"
        case .caa: return "CAA"
        }
    }
}

public enum DNSLookupMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case server

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return t("System resolver")
        case .server: return t("Specified server")
        }
    }
}

public struct DNSRecord: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let type: DNSRecordType
    public let ttl: UInt32?
    public let value: String

    public init(name: String, type: DNSRecordType, ttl: UInt32?, value: String) {
        self.name = name
        self.type = type
        self.ttl = ttl
        self.value = value
    }
}

public struct DNSQueryResult: Sendable {
    public let records: [DNSRecord]
    public let mode: DNSLookupMode
    public let server: String
    public let elapsed: TimeInterval
    public let responseCode: String
    public let authoritative: Bool

    public init(records: [DNSRecord], mode: DNSLookupMode = .server, server: String,
                elapsed: TimeInterval, responseCode: String, authoritative: Bool) {
        self.records = records
        self.mode = mode
        self.server = server
        self.elapsed = elapsed
        self.responseCode = responseCode
        self.authoritative = authoritative
    }
}

public enum DNSError: LocalizedError {
    case invalidName
    case serverRequired
    case serverNotAllowedInSystemMode
    case systemResolverRecordType
    case socket(String)
    case timeout
    case cancelled
    case malformed(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return t("Enter a valid DNS name.")
        case .serverRequired: return t("Enter a DNS server for this query mode.")
        case .serverNotAllowedInSystemMode: return t("Remove the DNS server or switch to specified-server mode.")
        case .systemResolverRecordType: return t("System resolver mode supports only A and AAAA records.")
        case .socket(let message): return message
        case .timeout: return t("The DNS server did not answer in time.")
        case .cancelled: return t("Diagnostic cancelled")
        case .malformed(let message): return tf("Malformed DNS response: %@", message)
        case .serverError(let message): return message
        }
    }
}

// MARK: - Client

/// Minimal but complete DNS client (UDP with TCP fallback for truncated answers).
public enum DNSClient {
    /// Returns configured name-server addresses for inspection. This flat list
    /// does not preserve macOS resolver scopes and must not drive system lookups.
    public static func systemServers(cancellation: DiagnosticCancellation? = nil) -> [String] {
        if cancellation?.isCancelled == true { return [] }
        let resolvConf = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)
        let result = Shell.runSync("/usr/sbin/scutil", ["--dns"], timeout: 5, cancellation: cancellation)
        if cancellation?.isCancelled == true { return [] }
        return parseSystemServers(resolvConf: resolvConf, scutilOutput: result.succeeded ? result.stdout : "")
    }

    static func parseSystemServers(resolvConf: String?, scutilOutput: String) -> [String] {
        var servers: [String] = []
        func append(_ value: String) {
            let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !servers.contains(address) else { return }
            servers.append(address)
        }

        for line in (resolvConf ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "nameserver" else { continue }
            append(String(fields[1]))
        }
        for line in scutilOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver["), let separator = trimmed.firstIndex(of: ":") else { continue }
            append(String(trimmed[trimmed.index(after: separator)...]))
        }
        return servers
    }

    private static func resolveServer(_ server: String, port: UInt16, timeout: TimeInterval,
                                      cancellation: DiagnosticCancellation?) throws -> ResolvedSocketAddress {
        do {
            guard let address = try SocketAddressResolver.resolve(server, port: Int(port), timeout: timeout,
                                                                  cancellation: cancellation).first else {
                throw DNSError.socket(tf("Cannot resolve name server %@", server))
            }
            return address
        } catch SocketAddressResolutionError.cancelled {
            throw DNSError.cancelled
        } catch SocketAddressResolutionError.timedOut {
            throw DNSError.timeout
        } catch let error as DNSError {
            throw error
        } catch {
            throw DNSError.socket(tf("Cannot resolve name server %@", server))
        }
    }

    public static func reverseName(for address: String) -> String {
        if let v4 = IPv4(address) {
            return v4.octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
        }
        // IPv6: expand to nibbles.
        var expanded = address
        if let range = expanded.range(of: "::") {
            let head = String(expanded[expanded.startIndex..<range.lowerBound]).split(separator: ":").map(String.init)
            let tail = String(expanded[range.upperBound...]).split(separator: ":").map(String.init)
            let missing = 8 - head.count - tail.count
            let middle = Array(repeating: "0", count: max(0, missing))
            expanded = (head + middle + tail).joined(separator: ":")
        }
        let groups = expanded.split(separator: ":").map(String.init)
        var nibbles: [String] = []
        for group in groups {
            let padded = String(repeating: "0", count: max(0, 4 - group.count)) + group
            nibbles.append(contentsOf: padded.map(String.init).reversed())
        }
        return nibbles.joined(separator: ".") + ".ip6.arpa"
    }

    /// Query a name server for a specific record type.
    public static func query(name: String,
                             type: DNSRecordType,
                             server: String? = nil,
                             serverPort: UInt16 = 53,
                             timeout: TimeInterval = 3,
                             cancellation: DiagnosticCancellation? = nil) throws -> DNSQueryResult {
        if cancellation?.isCancelled == true { throw DNSError.cancelled }
        guard let target = server?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            throw DNSError.serverRequired
        }
        let started = ProcessInfo.processInfo.systemUptime
        guard timeout.isFinite, timeout > 0 else { throw DNSError.timeout }
        let budget = QueryBudget(deadline: started + timeout, cancellation: cancellation)

        var packet = Data()
        let identifier = UInt16.random(in: 1...65535)
        packet.append(contentsOf: [UInt8(identifier >> 8), UInt8(identifier & 0xFF)])
        packet.append(contentsOf: [0x01, 0x00]) // standard query, recursion desired
        packet.append(contentsOf: [0x00, 0x01]) // questions
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        guard let encodedName = encodeName(name) else { throw DNSError.invalidName }
        packet.append(encodedName)
        packet.append(contentsOf: [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF)])
        packet.append(contentsOf: [0x00, 0x01]) // IN

        // Resolution, UDP and every TCP fallback read share this deadline.
        let address = try resolveServer(target, port: serverPort, timeout: budget.remaining(), cancellation: cancellation)
        var response = try udpExchange(packet: packet, address: address, budget: budget)
        let truncated = try DNSResponseParser.validateEnvelope(response, expectedID: identifier,
                                                               name: name, type: type)

        // TCP fallback when truncated.
        if truncated {
            response = try tcpExchange(packet: packet, address: address, budget: budget)
        }

        _ = try budget.remaining()
        let parsed = try DNSResponseParser.parse(response, expectedID: identifier, name: name, type: type)
        return DNSQueryResult(records: parsed.records, mode: .server, server: target,
                              elapsed: ProcessInfo.processInfo.systemUptime - started,
                              responseCode: parsed.responseCode, authoritative: parsed.authoritative)
    }

    /// Resolve an address record through macOS DNS-SD, preserving system resolver policy.
    public static func resolveSystem(name: String,
                                     type: DNSRecordType,
                                     timeout: TimeInterval = 3,
                                     cancellation: DiagnosticCancellation? = nil) throws -> DNSQueryResult {
        guard type == .a || type == .aaaa else { throw DNSError.systemResolverRecordType }
        if cancellation?.isCancelled == true { throw DNSError.cancelled }
        let started = ProcessInfo.processInfo.systemUptime
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(name, timeout: timeout, cancellation: cancellation)
        } catch SocketAddressResolutionError.cancelled {
            throw DNSError.cancelled
        } catch SocketAddressResolutionError.timedOut {
            throw DNSError.timeout
        }
        if cancellation?.isCancelled == true { throw DNSError.cancelled }

        let family = type == .a ? AF_INET : AF_INET6
        let records = addresses.filter { $0.family == family }.map {
            DNSRecord(name: name, type: type, ttl: nil, value: $0.numericAddress)
        }
        return DNSQueryResult(records: records, mode: .system, server: t("macOS system resolver"),
                              elapsed: ProcessInfo.processInfo.systemUptime - started,
                              responseCode: t("System resolution"), authoritative: false)
    }

    /// Convenience: resolve a hostname to A + AAAA records through the system resolver.
    public static func resolveHost(_ host: String) -> [String] {
        do {
            return try SocketAddressResolver.resolve(host, timeout: 5).map(\.numericAddress)
        } catch {
            return []
        }
    }

    // MARK: Transport

    private struct QueryBudget {
        let deadline: TimeInterval
        let cancellation: DiagnosticCancellation?

        func remaining() throws -> TimeInterval {
            if cancellation?.isCancelled == true { throw DNSError.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DNSError.timeout }
            return remaining
        }

        func wait(fd: Int32, events: Int16) throws {
            guard let ready = waitForSocketReadiness(fd: fd, events: events, timeout: try remaining(),
                                                     cancellation: cancellation) else {
                if cancellation?.isCancelled == true { throw DNSError.cancelled }
                throw DNSError.timeout
            }
            _ = try remaining()
            if ready & Int16(POLLNVAL) != 0 { throw DNSError.socket(String(cString: strerror(EBADF))) }
        }
    }

    private static func configureSocket(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DNSError.socket(String(cString: strerror(errno)))
        }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DNSError.socket(String(cString: strerror(errno)))
        }
    }

    private static func connectSocket(_ fd: Int32, address: ResolvedSocketAddress, budget: QueryBudget) throws {
        _ = try budget.remaining()
        let result = address.withSockAddr { Darwin.connect(fd, $0, $1) }
        if result == 0 { return }
        guard errno == EINPROGRESS || errno == EINTR else {
            throw DNSError.socket(String(cString: strerror(errno)))
        }
        try budget.wait(fd: fd, events: Int16(POLLOUT))
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            throw DNSError.socket(String(cString: strerror(errno)))
        }
        guard socketError == 0 else { throw DNSError.socket(String(cString: strerror(socketError))) }
    }

    private static func udpExchange(packet: Data, address: ResolvedSocketAddress, budget: QueryBudget) throws -> Data {
        let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        try configureSocket(fd)
        // A connected datagram socket accepts replies only from this endpoint.
        try connectSocket(fd, address: address, budget: budget)

        while true {
            try budget.wait(fd: fd, events: Int16(POLLOUT))
            let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if sent < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard sent == packet.count else { throw DNSError.socket(String(cString: strerror(errno))) }
            break
        }
        // Do not silently truncate a valid large datagram in our receive buffer.
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            try budget.wait(fd: fd, events: Int16(POLLIN))
            let received = recv(fd, &buffer, buffer.count, 0)
            if received < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard received >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
            return Data(buffer.prefix(received))
        }
    }

    private static func tcpExchange(packet: Data, address: ResolvedSocketAddress, budget: QueryBudget) throws -> Data {
        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        try configureSocket(fd)
        try connectSocket(fd, address: address, budget: budget)

        var framed = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        framed.append(packet)
        var written = 0
        while written < framed.count {
            try budget.wait(fd: fd, events: Int16(POLLOUT))
            let amount = framed.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: written), $0.count - written) }
            if amount < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard amount > 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
            written += amount
        }

        let lengthData = try readExactly(fd: fd, count: 2, budget: budget)
        let lengthBytes = Array(lengthData)
        let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
        guard length >= 12 else { throw DNSError.malformed(t("response too short")) }
        return try readExactly(fd: fd, count: length, budget: budget)
    }

    private static func readExactly(fd: Int32, count: Int, budget: QueryBudget) throws -> Data {
        var response = [UInt8](repeating: 0, count: count)
        var readTotal = 0
        while readTotal < count {
            try budget.wait(fd: fd, events: Int16(POLLIN))
            let chunk = response.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: readTotal), count - readTotal) }
            if chunk < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard chunk >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
            guard chunk > 0 else { throw DNSError.malformed(t("truncated TCP response")) }
            readTotal += chunk
        }
        return Data(response)
    }

    // MARK: Encoding

    private static func encodeName(_ name: String) -> Data? {
        if name == "." { return Data([0]) }
        let normalized = name.hasSuffix(".") ? String(name.dropLast()) : name
        var data = Data()
        for label in normalized.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        guard !data.isEmpty, data.count <= 254 else { return nil }
        data.append(0)
        return data
    }

}
