import Darwin
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

    public static func resolve(_ host: String, timeout: TimeInterval = 5, cancellation: DiagnosticCancellation? = nil) throws -> ResolvedTarget {
        guard let resolved = try SocketAddressResolver.resolve(host, timeout: timeout, cancellation: cancellation).first else {
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
    private var timeout: TimeInterval
    private var nextSequence: UInt16 = 1
    private let payloadSize: Int
    private var currentTTL: Int
    private let cancellation: DiagnosticCancellation?

    /// - Parameters:
    ///   - host: hostname or IP address
    ///   - timeout: total budget per echo; constructor resolution is separately bounded
    ///   - ttl: IP TTL / hop limit (traceroute uses increasing values)
    ///   - payloadSize: ICMP payload bytes besides the 8 byte header
    public convenience init(host: String, timeout: TimeInterval = 2.0, ttl: Int = 64, payloadSize: Int = 32, cancellation: DiagnosticCancellation? = nil) throws {
        guard Ping.validTimeout(timeout) else { throw POSIXError(.EINVAL) }
        let target = try ResolvedTarget.resolve(host, timeout: timeout, cancellation: cancellation)
        try self.init(target: target, timeout: timeout, ttl: ttl, payloadSize: payloadSize, cancellation: cancellation)
    }

    init(target: ResolvedTarget, timeout: TimeInterval, ttl: Int = 64, payloadSize: Int = 32, cancellation: DiagnosticCancellation? = nil) throws {
        guard Ping.validTimeout(timeout) else { throw POSIXError(.EINVAL) }
        self.target = target
        self.timeout = timeout
        self.payloadSize = max(8, payloadSize)
        self.currentTTL = max(1, min(255, ttl))
        self.cancellation = cancellation
        let proto = target.family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
        socketFD = socket(target.family, SOCK_DGRAM, proto)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }

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
        currentTTL = max(1, min(255, ttl))
        var value = Int32(currentTTL)
        if target.family == AF_INET {
            setsockopt(socketFD, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(socketFD, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    public func setReceiveTimeout(_ seconds: TimeInterval) {
        guard Ping.validTimeout(seconds) else { return }
        timeout = seconds
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

    /// Send one echo request. Native receive and optional system fallback share
    /// one budget; constructor resolution has its own bounded budget.
    public func ping(sequence: Int? = nil, allowSystemFallback: Bool = true) -> ICMPReply {
        ping(sequence: sequence, allowSystemFallback: allowSystemFallback, deadline: PingDeadline(timeout: timeout))
    }

    func ping(sequence: Int? = nil, allowSystemFallback: Bool, deadline: PingDeadline) -> ICMPReply {
        let seq = UInt16(truncatingIfNeeded: sequence ?? Int(nextSequence))
        nextSequence &+= 1
        if cancellation?.isCancelled == true { return Ping.reply(.error(t("Diagnostic cancelled")), sequence: seq) }
        guard deadline.remaining > 0 else { return Ping.reply(.timeout, sequence: seq) }
        guard socketFD >= 0 else {
            return Ping.reply(.error(t("The ICMP socket is closed.")), sequence: seq)
        }
        // Reserve half the remaining time for Darwin's system-client fallback.
        let nativeDeadline = allowSystemFallback ? deadline.limited(to: deadline.remaining / 2) : deadline
        let packet = buildPacket(sequence: seq)
        let start = deadline.now()
        let sent = packet.withUnsafeBytes { raw in
            target.sockaddrBytes.withUnsafeBytes { sa in
                sendto(socketFD, raw.baseAddress, raw.count, MSG_DONTWAIT,
                       sa.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(sa.count))
            }
        }
        let result: ICMPReply
        if sent < 0 {
            result = Ping.reply(.error(String(cString: strerror(errno))), sequence: seq)
        } else {
            result = Self.receiveReply(fd: socketFD, family: target.family, sequence: seq,
                                       start: start, deadline: nativeDeadline, cancellation: cancellation)
        }
        if cancellation?.isCancelled == true { return Ping.reply(.error(t("Diagnostic cancelled")), sequence: seq) }
        guard deadline.remaining > 0 else { return Ping.reply(.timeout, sequence: seq) }
        if allowSystemFallback {
            switch result.outcome {
            case .timeout, .error:
                return SystemPing.run(target: target, ttl: currentTTL, sequence: seq, deadline: deadline, cancellation: cancellation)
            default: break
            }
        }
        return result
    }

    /// Polling and nonblocking receive keep silence and unrelated traffic under
    /// the same deadline, even without an explicit cancellation token.
    static func receiveReply(fd: Int32, family: Int32, sequence: UInt16, start: ContinuousClock.Instant,
                             deadline: PingDeadline, cancellation: DiagnosticCancellation?) -> ICMPReply {
        while true {
            if cancellation?.isCancelled == true { return Ping.reply(.error(t("Diagnostic cancelled")), sequence: sequence) }
            let remaining = deadline.remaining
            guard remaining > 0 else { return Ping.reply(.timeout, sequence: sequence) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, min(50, ceil(remaining * 1_000)))))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return Ping.reply(.error(String(cString: strerror(errno))), sequence: sequence)
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else {
                return Ping.reply(.error(POSIXError(.EIO).localizedDescription), sequence: sequence)
            }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var control = [UInt8](repeating: 0, count: 512)
            var sourceStorage = sockaddr_storage()
            var receivedTTL: Int?
            let received = buffer.withUnsafeMutableBytes { bufferBytes in
                control.withUnsafeMutableBytes { controlBytes in
                    var iov = iovec(iov_base: bufferBytes.baseAddress, iov_len: bufferBytes.count)
                    return withUnsafeMutablePointer(to: &sourceStorage) { sourcePointer in
                        withUnsafeMutablePointer(to: &iov) { iovPointer in
                            var message = msghdr()
                            message.msg_name = UnsafeMutableRawPointer(sourcePointer)
                            message.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                            message.msg_iov = iovPointer
                            message.msg_iovlen = 1
                            message.msg_control = controlBytes.baseAddress
                            message.msg_controllen = socklen_t(controlBytes.count)
                            let result = recvmsg(fd, &message, MSG_DONTWAIT)
                            if result >= 0 { receivedTTL = Self.ttl(from: message) }
                            return result
                        }
                    }
                }
            }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return Ping.reply(.error(String(cString: strerror(errno))), sequence: sequence)
            }
            if cancellation?.isCancelled == true { return Ping.reply(.error(t("Diagnostic cancelled")), sequence: sequence) }
            guard deadline.remaining > 0 else { return Ping.reply(.timeout, sequence: sequence) }
            guard let parsed = parseICMP(Array(buffer.prefix(received)), family: family) else { continue }
            let rtt = max(0, PingDeadline.seconds(start.duration(to: deadline.now())))
            let source = Self.numericHost(sourceStorage)
            switch parsed.type {
            case 0 where family == AF_INET, 129 where family == AF_INET6:
                guard parsed.sequence == sequence || parsed.sequence == 0 else { continue }
                return ICMPReply(sequence: Int(sequence), outcome: .success, rtt: rtt, ttl: receivedTTL, source: source)
            case 11 where family == AF_INET, 3 where family == AF_INET6:
                return ICMPReply(sequence: Int(sequence), outcome: .ttlExpired(hop: source ?? "?"),
                                 rtt: rtt, ttl: receivedTTL, source: source)
            case 3 where family == AF_INET, 1 where family == AF_INET6:
                return ICMPReply(sequence: Int(sequence), outcome: .unreachable(reason: unreachableReason(parsed.code), from: source ?? "?"),
                                 rtt: rtt, ttl: receivedTTL, source: source)
            default: continue
            }
        }
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

    static func parseSystemPing(_ output: String, fallbackAddress: String, sequence: UInt16) -> ICMPReply? {
        let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard let replyLine = lines.first(where: { $0.contains("bytes from") && $0.contains("icmp_seq=") }) else {
            return nil
        }

        var source = fallbackAddress
        if let fromRange = replyLine.range(of: "bytes from ") {
            let remainder = replyLine[fromRange.upperBound...]
            source = remainder.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? fallbackAddress
            // IPv4 replies end the source with a colon; ping6 uses a comma.
            if source.last == ":" || source.last == "," { source.removeLast() }
        }
        let ttl = (value(after: "ttl=", in: replyLine) ?? value(after: "hlim=", in: replyLine)).flatMap(Int.init)
        let rttMilliseconds = value(after: "time=", in: replyLine).flatMap(Double.init)
        return ICMPReply(sequence: Int(sequence), outcome: .success,
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
            let header = base.advanced(by: offset).loadUnaligned(as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerSize, length <= limit - offset else { break }
            let ipv6HopLimit: Int32 = 47
            if header.cmsg_level == IPPROTO_IP && header.cmsg_type == IP_RECVTTL
                || header.cmsg_level == IPPROTO_IPV6 && header.cmsg_type == ipv6HopLimit {
                guard length - headerSize >= MemoryLayout<Int32>.size else { return nil }
                let value = base.advanced(by: offset + headerSize).loadUnaligned(as: Int32.self)
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
    /// One total network budget covers resolution, native ICMP and fallback.
    /// Bounded subprocess teardown can finish after the network budget expires.
    public static func once(host: String, timeout: TimeInterval = 2, cancellation: DiagnosticCancellation? = nil) async -> ICMPReply {
        await once(host: host, timeout: timeout, cancellation: cancellation, operations: .live)
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
