import Foundation

// MARK: - Result types

public enum ICMPOutcome: Sendable, Equatable {
    case success
    case timeout
    case ttlExpired(hop: String)
    case unreachable(reason: String, from: String)
    case error(String)

    public var isSuccess: Bool { self == .success }

    public var displayName: String {
        switch self {
        case .success: return t("Success")
        case .timeout: return t("Timeout")
        case .ttlExpired(let hop): return tf("TTL expired (%@)", hop)
        case .unreachable(let reason, let from): return tf("Unreachable (%@) from %@", reason, from)
        case .error(let message): return message
        }
    }
}

public struct ICMPReply: Sendable {
    public let sequence: Int
    public let outcome: ICMPOutcome
    public let rtt: TimeInterval?
    public let ttl: Int?
    public let source: String?
    public let timestamp: Date

    public init(sequence: Int, outcome: ICMPOutcome, rtt: TimeInterval?, ttl: Int?, source: String?, timestamp: Date = Date()) {
        self.sequence = sequence
        self.outcome = outcome
        self.rtt = rtt
        self.ttl = ttl
        self.source = source
        self.timestamp = timestamp
    }
}

/// Resolved target used by the ICMP based tools.
public struct ResolvedTarget: Sendable {
    public let hostname: String
    public let address: String
    public let family: Int32
    public let sockaddrBytes: [UInt8]

    public static func resolve(_ host: String, cancellation: DiagnosticCancellation? = nil) throws -> ResolvedTarget {
        guard let resolved = try SocketAddressResolver.resolve(host, cancellation: cancellation).first else {
            throw POSIXError(.EHOSTUNREACH)
        }
        return ResolvedTarget(hostname: host, address: resolved.numericAddress,
                              family: resolved.family, sockaddrBytes: resolved.bytes)
    }
}

// MARK: - Pinger

/// Native ICMP echo client.
///
/// Uses an unprivileged `SOCK_DGRAM` ICMP socket, which macOS allows without
/// root, and therefore works for normal users out of the box.
public final class ICMPPinger {
    private var socketFD: Int32
    private let target: ResolvedTarget
    private let timeout: TimeInterval
    private var nextSequence: UInt16 = 1
    private let payloadSize: Int
    private var currentTTL: Int
    private let cancellation: DiagnosticCancellation?

    /// - Parameters:
    ///   - host: hostname or IP address
    ///   - timeout: receive timeout per echo request
    ///   - ttl: IP TTL / hop limit (traceroute uses increasing values)
    ///   - payloadSize: ICMP payload bytes besides the 8 byte header
    public init(host: String, timeout: TimeInterval = 2.0, ttl: Int = 64, payloadSize: Int = 32, cancellation: DiagnosticCancellation? = nil) throws {
        self.target = try ResolvedTarget.resolve(host, cancellation: cancellation)
        self.timeout = timeout
        self.payloadSize = max(8, payloadSize)
        self.currentTTL = max(1, ttl)
        self.cancellation = cancellation

        let proto = target.family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(target.family, SOCK_DGRAM, proto)
        guard socketFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        let receiveTimeout = cancellation == nil ? timeout : min(timeout, 0.1)
        var tv = timeval(tv_sec: Int(receiveTimeout), tv_usec: Int32((receiveTimeout - Double(Int(receiveTimeout))) * 1_000_000))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var one: Int32 = 1
        if target.family == AF_INET {
            setsockopt(socketFD, IPPROTO_IP, IP_RECVTTL, &one, socklen_t(MemoryLayout<Int32>.size))
        } else {
            // Darwin's SDK hides these constants from the Swift importer when
            // the RFC 3542 compatibility macro is not enabled.
            let ipv6ReceiveHopLimit: Int32 = 37
            setsockopt(socketFD, IPPROTO_IPV6, ipv6ReceiveHopLimit, &one, socklen_t(MemoryLayout<Int32>.size))
        }

        setTTL(ttl)
    }

    public var resolvedAddress: String { target.address }

    public func setTTL(_ ttl: Int) {
        currentTTL = max(1, ttl)
        var value = Int32(currentTTL)
        if target.family == AF_INET {
            setsockopt(socketFD, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    public func setReceiveTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    public func close() {
        guard socketFD >= 0 else { return }
        Darwin.close(socketFD)
        socketFD = -1
    }

    // MARK: Echo

    /// Send one echo request and wait for the matching reply.
    public func ping(sequence: Int? = nil, allowSystemFallback: Bool = true) -> ICMPReply {
        let seq = UInt16(truncatingIfNeeded: sequence ?? Int(nextSequence))
        nextSequence &+= 1

        if cancellation?.isCancelled == true {
            return ICMPReply(sequence: Int(seq), outcome: .error(t("Diagnostic cancelled")), rtt: nil, ttl: nil, source: nil)
        }

        let packet = buildPacket(sequence: seq)
        let start = Date()

        guard socketFD >= 0 else {
            return ICMPReply(sequence: Int(seq), outcome: .error(t("The ICMP socket is closed.")), rtt: nil, ttl: nil, source: nil)
        }

        let sent = packet.withUnsafeBytes { raw -> Int in
            target.sockaddrBytes.withUnsafeBytes { sa in
                sendto(socketFD, raw.baseAddress, raw.count, 0,
                       sa.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                       socklen_t(target.sockaddrBytes.count))
            }
        }
        if sent < 0 {
            return ICMPReply(sequence: Int(seq), outcome: .error(String(cString: strerror(errno))), rtt: nil, ttl: nil, source: nil)
        }

        // Receive loop: ignore replies that belong to other sequences.
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline && cancellation?.isCancelled != true {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var control = [UInt8](repeating: 0, count: 512)
            var sourceStorage = sockaddr_storage()
            var receivedTTL: Int?
            let received: Int = buffer.withUnsafeMutableBytes { bufferBytes in
                control.withUnsafeMutableBytes { controlBytes in
                    var iov = iovec(iov_base: bufferBytes.baseAddress, iov_len: bufferBytes.count)
                    var message = msghdr()
                    message.msg_name = withUnsafeMutablePointer(to: &sourceStorage) { UnsafeMutableRawPointer($0) }
                    message.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    message.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                    message.msg_iovlen = 1
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = socklen_t(controlBytes.count)
                    let result = recvmsg(socketFD, &message, 0)
                    receivedTTL = Self.ttl(from: message)
                    return result
                }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if cancellation != nil && Date() < deadline { continue }
                    break
                }
                return ICMPReply(sequence: Int(seq), outcome: .error(String(cString: strerror(errno))),
                                 rtt: nil, ttl: nil, source: nil)
            }

            let rtt = Date().timeIntervalSince(start)
            let source = Self.numericHost(sourceStorage)

            guard let parsed = Self.parseICMP(Array(buffer.prefix(received)), family: target.family) else {
                continue
            }

            switch parsed.type {
            case 0, 129: // echo reply
                guard parsed.sequence == seq || parsed.sequence == 0 else { continue }
                return ICMPReply(sequence: Int(seq), outcome: .success, rtt: rtt, ttl: receivedTTL, source: source)
            case 11: // time exceeded
                return ICMPReply(sequence: Int(seq), outcome: .ttlExpired(hop: source ?? "?"), rtt: rtt, ttl: receivedTTL, source: source)
            case 3, 1: // unreachable
                let reason = ICMPPinger.unreachableReason(parsed.code)
                return ICMPReply(sequence: Int(seq), outcome: .unreachable(reason: reason, from: source ?? "?"),
                                 rtt: rtt, ttl: receivedTTL, source: source)
            default:
                continue
            }
        }

        // macOS has shipped configurations where an unprivileged datagram
        // ICMP socket is created successfully but its replies are not exposed
        // to recvmsg. Fall back to the system client using an argument array,
        // preserving the same ICMPReply contract for the UI and scanners.
        if allowSystemFallback && cancellation?.isCancelled != true { return systemPing(sequence: seq) }
        return ICMPReply(sequence: Int(seq), outcome: .timeout, rtt: nil, ttl: nil, source: nil)
    }

    // MARK: Packet building / parsing

    private func buildPacket(sequence: UInt16) -> [UInt8] {
        let isV6 = target.family == AF_INET6
        let type: UInt8 = isV6 ? 128 : 8
        let total = 8 + payloadSize
        var packet = [UInt8](repeating: 0, count: total)
        packet[0] = type                       // type
        packet[1] = 0                          // code
        packet[4] = UInt8(sequence >> 8)       // identifier (kernel rewrites)
        packet[5] = UInt8(sequence & 0xFF)
        packet[6] = UInt8(sequence >> 8)       // sequence
        packet[7] = UInt8(sequence & 0xFF)
        for index in 8..<total {
            packet[index] = UInt8(truncatingIfNeeded: index &* 7 &+ Int(sequence))
        }
        if !isV6 {
            let checksum = Self.checksum(packet)
            packet[2] = UInt8(checksum >> 8)
            packet[3] = UInt8(checksum & 0xFF)
        }
        return packet
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            sum &+= UInt32(data[index]) << 8 | UInt32(data[index + 1])
            index += 2
        }
        if index < data.count {
            sum &+= UInt32(data[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    struct ParsedICMP {
        let type: UInt8
        let code: UInt8
        let sequence: UInt16
    }

    static func parseICMP(_ buffer: [UInt8], family: Int32) -> ParsedICMP? {
        // Datagram ICMP normally starts at the ICMP header. Some Darwin
        // releases retain an IP header, so accept both forms.
        var offset = 0
        if family == AF_INET, buffer.count >= 20, (buffer[0] >> 4) == 4 {
            offset = Int(buffer[0] & 0x0F) * 4
        } else if family == AF_INET6, buffer.count >= 40, (buffer[0] >> 4) == 6 {
            offset = 40
        }
        guard buffer.count >= offset + 8 else { return nil }
        let type = buffer[offset]
        let code = buffer[offset + 1]
        let sequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
        return ParsedICMP(type: type, code: code, sequence: sequence)
    }

    private func systemPing(sequence: UInt16) -> ICMPReply {
        guard let path = Shell.which("ping") else {
            return ICMPReply(sequence: Int(sequence), outcome: .timeout, rtt: nil, ttl: nil, source: nil)
        }

        let waitMilliseconds = max(1, Int(ceil(timeout * 1_000)))
        let arguments = ["-n", "-c", "1", "-W", String(waitMilliseconds), "-m", String(currentTTL), target.address]
        let result = Shell.runSync(path, arguments, timeout: max(timeout + 1.0, 2.0))
        let parsed = Self.parseSystemPing(result.output, fallbackAddress: target.address, sequence: sequence)
        if let parsed, parsed.outcome.isSuccess { return parsed }
        return parsed ?? ICMPReply(sequence: Int(sequence), outcome: .timeout, rtt: nil, ttl: nil, source: nil)
    }

    static func parseSystemPing(_ output: String, fallbackAddress: String, sequence: UInt16) -> ICMPReply? {
        let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let replyLine = lines.first(where: { $0.contains("bytes from") && $0.contains("icmp_seq=") }) else {
            return nil
        }

        var source = fallbackAddress
        if let fromRange = replyLine.range(of: "bytes from ") {
            let remainder = replyLine[fromRange.upperBound...]
            source = remainder.split(separator: ":", maxSplits: 1).first.map(String.init) ?? fallbackAddress
        }
        let ttl = value(after: "ttl=", in: replyLine).flatMap(Int.init)
        let rttMilliseconds = value(after: "time=", in: replyLine).flatMap(Double.init)
        let replySequence = value(after: "icmp_seq=", in: replyLine).flatMap(UInt16.init) ?? sequence
        return ICMPReply(sequence: Int(replySequence), outcome: .success,
                         rtt: rttMilliseconds.map { $0 / 1_000.0 }, ttl: ttl, source: source)
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        let value = tail.prefix { !$0.isWhitespace && $0 != "," }
        return value.isEmpty ? nil : String(value)
    }

    static func unreachableReason(_ code: UInt8) -> String {
        switch code {
        case 0: return t("Network unreachable")
        case 1: return t("Host unreachable")
        case 2: return t("Protocol unreachable")
        case 3: return t("Port unreachable")
        case 4: return t("Fragmentation needed")
        case 13: return t("Communication administratively prohibited")
        default: return tf("Code %d", Int(code))
        }
    }

    static func ttl(from message: msghdr) -> Int? {
        guard let control = message.msg_control, message.msg_controllen > 0 else { return nil }
        let base = UnsafeRawPointer(control)
        let headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        let limit = Int(message.msg_controllen)

        while offset + headerSize <= limit {
            let header = base.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self)
            let length = Int(header.pointee.cmsg_len)
            if length < headerSize { break }
            let ipv6HopLimit: Int32 = 47
            if header.pointee.cmsg_level == IPPROTO_IP && header.pointee.cmsg_type == IP_RECVTTL
                || header.pointee.cmsg_level == IPPROTO_IPV6 && header.pointee.cmsg_type == ipv6HopLimit {
                let value = base.advanced(by: offset + headerSize).load(as: Int32.self)
                return Int(value)
            }
            // Darwin aligns cmsg data to 4 bytes.
            offset += (length + 3) & ~3
            if length == 0 { break }
        }
        return nil
    }

    static func numericHost(_ storage: sockaddr_storage) -> String? {
        var copy = storage
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }
}

// MARK: - Convenience helpers

public enum Ping {
    /// Perform a single ping and return the reply.
    public static func once(host: String, timeout: TimeInterval = 2, cancellation: DiagnosticCancellation? = nil) async -> ICMPReply {
        let raw = await Task.detached(priority: .userInitiated) {
            do {
                let pinger = try ICMPPinger(host: host, timeout: timeout, cancellation: cancellation)
                return pinger.ping(allowSystemFallback: false)
            } catch {
                return ICMPReply(sequence: 0, outcome: .error(error.localizedDescription), rtt: nil, ttl: nil, source: nil)
            }
        }.value
        guard cancellation?.isCancelled != true, case .timeout = raw.outcome else { return raw }
        return await systemPing(host: host, timeout: timeout, sequence: raw.sequence, cancellation: cancellation)
    }

    private static func systemPing(host: String, timeout: TimeInterval, sequence: Int, cancellation: DiagnosticCancellation?) async -> ICMPReply {
        guard let path = Shell.which("ping") else { return .init(sequence: sequence, outcome: .timeout, rtt: nil, ttl: nil, source: nil) }
        if cancellation?.isCancelled == true { return .init(sequence: sequence, outcome: .timeout, rtt: nil, ttl: nil, source: nil) }
        let waitMilliseconds = max(1, Int(ceil(timeout * 1_000)))
        let arguments = ["-n", "-c", "1", "-W", String(waitMilliseconds), "-m", "64", host]
        let result = await Shell.run(path, arguments, timeout: max(timeout + 1, 2), cancellation: cancellation)
        return ICMPPinger.parseSystemPing(result.output, fallbackAddress: host, sequence: UInt16(truncatingIfNeeded: sequence))
            ?? .init(sequence: sequence, outcome: .timeout, rtt: nil, ttl: nil, source: nil)
    }

    /// Resolve the hostname for an IP address (reverse DNS), returns nil on failure.
    public static func reverseLookup(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let list = info else { return nil }
        defer { freeaddrinfo(list) }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(list.pointee.ai_addr, list.pointee.ai_addrlen, &hostBuffer,
                                 socklen_t(hostBuffer.count), nil, 0, NI_NAMEREQD)
        guard status == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    /// Forward resolve a hostname to all addresses.
    public static func addresses(of host: String, cancellation: DiagnosticCancellation? = nil) -> [String] {
        (try? SocketAddressResolver.resolve(host, cancellation: cancellation).map(\.numericAddress)) ?? []
    }
}
