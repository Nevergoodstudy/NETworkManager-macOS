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
        if cancellation?.isCancelled == true { throw DNSError.cancelled }
        let start = Date()

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

        var response = try udpExchange(packet: packet, server: target, port: serverPort, timeout: timeout, cancellation: cancellation)

        // TCP fallback when truncated.
        if response.count > 2, response[2] & 0x02 != 0 {
            response = try tcpExchange(packet: packet, server: target, port: serverPort, timeout: timeout, cancellation: cancellation)
        }

        let elapsed = Date().timeIntervalSince(start)
        let parsed = try parse(response, expectedID: identifier)
        return DNSQueryResult(records: parsed.records, mode: .server, server: target, elapsed: elapsed,
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

    private static func udpExchange(packet: Data, server: String, port: UInt16, timeout: TimeInterval, cancellation: DiagnosticCancellation?) throws -> Data {
        let address = try resolveServer(server, port: port, timeout: timeout, cancellation: cancellation)
        if cancellation?.isCancelled == true { throw DNSError.cancelled }

        let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let sent = packet.withUnsafeBytes { raw in
            address.withSockAddr { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
        }
        guard sent == packet.count else { throw DNSError.socket(String(cString: strerror(errno))) }

        guard waitForSocketReadiness(fd: fd, events: Int16(POLLIN), timeout: timeout, cancellation: cancellation) != nil else {
            if cancellation?.isCancelled == true { throw DNSError.cancelled }
            throw DNSError.timeout
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        if received < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw DNSError.timeout }
            throw DNSError.socket(String(cString: strerror(errno)))
        }
        return Data(buffer.prefix(received))
    }

    private static func tcpExchange(packet: Data, server: String, port: UInt16, timeout: TimeInterval, cancellation: DiagnosticCancellation?) throws -> Data {
        let address = try resolveServer(server, port: port, timeout: timeout, cancellation: cancellation)
        if cancellation?.isCancelled == true { throw DNSError.cancelled }

        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connectResult = address.withSockAddr { Darwin.connect(fd, $0, $1) }
        if connectResult != 0 {
            guard errno == EINPROGRESS,
                  waitForSocketReadiness(fd: fd, events: Int16(POLLOUT), timeout: timeout, cancellation: cancellation) != nil else {
                if cancellation?.isCancelled == true { throw DNSError.cancelled }
                throw DNSError.timeout
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                throw DNSError.socket(String(cString: strerror(socketError == 0 ? errno : socketError)))
            }
        }

        var framed = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        framed.append(packet)
        var written = 0
        while written < framed.count {
            guard waitForSocketReadiness(fd: fd, events: Int16(POLLOUT), timeout: timeout, cancellation: cancellation) != nil else {
                if cancellation?.isCancelled == true { throw DNSError.cancelled }
                throw DNSError.timeout
            }
            let amount = framed.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: written), $0.count - written) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
            written += amount
        }

        let lengthData = try readExactly(fd: fd, count: 2, timeout: timeout, cancellation: cancellation)
        let lengthBytes = Array(lengthData)
        let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
        return try readExactly(fd: fd, count: length, timeout: timeout, cancellation: cancellation)
    }

    private static func readExactly(fd: Int32, count: Int, timeout: TimeInterval, cancellation: DiagnosticCancellation?) throws -> Data {
        var response = [UInt8](repeating: 0, count: count)
        var readTotal = 0
        while readTotal < count {
            guard waitForSocketReadiness(fd: fd, events: Int16(POLLIN), timeout: timeout, cancellation: cancellation) != nil else {
                if cancellation?.isCancelled == true { throw DNSError.cancelled }
                throw DNSError.timeout
            }
            let chunk = response.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: readTotal), count - readTotal) }
            if chunk < 0 && errno == EINTR { continue }
            guard chunk > 0 else { throw DNSError.timeout }
            readTotal += chunk
        }
        return Data(response)
    }

    // MARK: Encoding

    private static func encodeName(_ name: String) -> Data? {
        var data = Data()
        for label in name.split(separator: ".", omittingEmptySubsequences: true) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        guard !data.isEmpty, data.count <= 253 else { return nil }
        data.append(0)
        return data
    }

    // MARK: Parsing

    private struct ParsedResponse {
        let records: [DNSRecord]
        let responseCode: String
        let authoritative: Bool
    }

    private static func parse(_ data: Data, expectedID: UInt16) throws -> ParsedResponse {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw DNSError.malformed(t("response too short")) }

        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard id == expectedID else { throw DNSError.malformed(t("unexpected transaction id")) }

        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let rcode = Int(flags & 0x0F)
        let authoritative = (flags & 0x0400) != 0
        let questionCount = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let answerCount = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        let authorityCount = Int(UInt16(bytes[8]) << 8 | UInt16(bytes[9]))
        let additionalCount = Int(UInt16(bytes[10]) << 8 | UInt16(bytes[11]))

        let responseCodes = ["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"]
        let codeName = rcode < responseCodes.count ? responseCodes[rcode] : "RCODE\(rcode)"

        var offset = 12
        for _ in 0..<questionCount {
            _ = try skipName(bytes, &offset)
            offset += 4
        }

        var records: [DNSRecord] = []
        let total = answerCount + authorityCount + additionalCount
        for _ in 0..<total {
            guard offset < bytes.count else { break }
            let owner = (try? readName(bytes, &offset)) ?? "?"
            guard offset + 10 <= bytes.count else { break }
            let typeValue = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let ttl = UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16
                | UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
            let rdLength = Int(UInt16(bytes[offset + 8]) << 8 | UInt16(bytes[offset + 9]))
            offset += 10
            guard offset + rdLength <= bytes.count else { break }
            let rdata = Array(bytes[offset..<(offset + rdLength)])

            if let type = DNSRecordType(rawValue: typeValue) {
                let value = describe(type: type, rdata: rdata, fullMessage: bytes) ?? "?"
                records.append(DNSRecord(name: owner, type: type, ttl: ttl, value: value))
            } else if typeValue == 41 {
                // OPT pseudo record – skip
            }
            offset += rdLength
        }

        return ParsedResponse(records: records, responseCode: codeName, authoritative: authoritative)
    }

    private static func describe(type: DNSRecordType, rdata: [UInt8], fullMessage: [UInt8]) -> String? {
        switch type {
        case .a:
            guard rdata.count == 4 else { return nil }
            return rdata.map(String.init).joined(separator: ".")
        case .aaaa:
            guard rdata.count == 16 else { return nil }
            var groups: [String] = []
            for index in stride(from: 0, to: 16, by: 2) {
                groups.append(String(format: "%x", Int(rdata[index]) << 8 | Int(rdata[index + 1])))
            }
            return groups.joined(separator: ":")
        case .cname, .ns, .ptr:
            var offset = 0
            return (try? readName(rdata, &offset, fullMessage: fullMessage)) ?? nil
        case .mx:
            guard rdata.count > 2 else { return nil }
            let preference = Int(rdata[0]) << 8 | Int(rdata[1])
            var offset = 2
            let exchange = (try? readName(rdata, &offset, fullMessage: fullMessage)) ?? "?"
            return "\(preference) \(exchange)"
        case .txt:
            var offset = 0
            var parts: [String] = []
            while offset < rdata.count {
                let length = Int(rdata[offset])
                offset += 1
                guard offset + length <= rdata.count else { break }
                parts.append(String(decoding: rdata[offset..<(offset + length)], as: UTF8.self))
                offset += length
            }
            return parts.joined()
        case .srv:
            guard rdata.count > 6 else { return nil }
            let priority = Int(rdata[0]) << 8 | Int(rdata[1])
            let weight = Int(rdata[2]) << 8 | Int(rdata[3])
            let port = Int(rdata[4]) << 8 | Int(rdata[5])
            var offset = 6
            let target = (try? readName(rdata, &offset, fullMessage: fullMessage)) ?? "?"
            return "\(priority) \(weight) \(port) \(target)"
        case .soa:
            var offset = 0
            let mname = (try? readName(rdata, &offset, fullMessage: fullMessage)) ?? "?"
            let rname = (try? readName(rdata, &offset, fullMessage: fullMessage)) ?? "?"
            return "\(mname) \(rname)"
        case .caa:
            guard rdata.count > 2 else { return nil }
            let flags = rdata[0]
            let tagLength = Int(rdata[1])
            guard 2 + tagLength <= rdata.count else { return nil }
            let tag = String(decoding: rdata[2..<(2 + tagLength)], as: UTF8.self)
            let value = String(decoding: rdata[(2 + tagLength)...], as: UTF8.self)
            return "\(flags) \(tag) \"\(value)\""
        }
    }

    private static func skipName(_ bytes: [UInt8], _ offset: inout Int) throws {
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { offset += 1; return }
            if length & 0xC0 == 0xC0 { offset += 2; return }
            offset += length + 1
        }
        throw DNSError.malformed(t("truncated name"))
    }

    private static func readName(_ bytes: [UInt8], _ offset: inout Int, fullMessage: [UInt8]? = nil) throws -> String {
        let message = fullMessage ?? bytes
        var labels: [String] = []
        var cursor = offset
        var jumped = false
        var guardCounter = 0

        while cursor < message.count {
            guardCounter += 1
            if guardCounter > 128 { break }
            let length = Int(message[cursor])
            if length == 0 {
                cursor += 1
                if !jumped { offset = cursor }
                break
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < message.count else { break }
                let pointer = (Int(message[cursor] & 0x3F) << 8) | Int(message[cursor + 1])
                if !jumped { offset = cursor + 2 }
                jumped = true
                cursor = pointer
                continue
            }
            guard cursor + 1 + length <= message.count else { break }
            labels.append(String(decoding: message[(cursor + 1)..<(cursor + 1 + length)], as: UTF8.self))
            cursor += 1 + length
            if !jumped { offset = cursor }
        }
        return labels.joined(separator: ".")
    }
}
