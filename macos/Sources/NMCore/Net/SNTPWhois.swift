import Foundation

// MARK: - SNTP

public struct SNTPResult: Sendable {
    public let server: String
    public let address: String
    public let offset: TimeInterval
    public let delay: TimeInterval
    public let stratum: Int
    public let referenceID: String
    public let serverTime: Date
    public let roundTrip: TimeInterval
}

public enum SNTPClient {
    /// Query an SNTP server (RFC 4330) and compute the clock offset.
    public static func query(server: String, timeout: TimeInterval = 3, port: UInt16 = 123,
                             cancellation: DiagnosticCancellation? = nil) throws -> SNTPResult {
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(server, port: Int(port), timeout: timeout, cancellation: cancellation)
        } catch SocketAddressResolutionError.cancelled {
            throw DNSError.cancelled
        } catch SocketAddressResolutionError.timedOut {
            throw DNSError.timeout
        } catch {
            throw DNSError.socket(tf("Cannot resolve %@", server))
        }
        guard let address = addresses.first else { throw DNSError.socket(tf("Cannot resolve %@", server)) }
        guard cancellation?.isCancelled != true else { throw DNSError.cancelled }

        let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DNSError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DNSError.socket(String(cString: strerror(errno)))
        }

        var request = [UInt8](repeating: 0, count: 48)
        request[0] = 0x1B // LI = 0, VN = 3, Mode = 3 (client)

        let t1 = Date()
        writeNTPTimestamp(t1, into: &request, offset: 40)
        let sent = request.withUnsafeBytes { raw in
            address.withSockAddr { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
        }
        guard sent == 48 else {
            if cancellation?.isCancelled == true { throw DNSError.cancelled }
            throw DNSError.socket(String(cString: strerror(errno)))
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var received = -1
        while received < 0 {
            if cancellation?.isCancelled == true { throw DNSError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DNSError.timeout }
            guard let events = waitForSocketReadiness(fd: fd, events: Int16(POLLIN), timeout: remaining, cancellation: cancellation) else {
                if cancellation?.isCancelled == true { throw DNSError.cancelled }
                throw DNSError.timeout
            }
            guard events & Int16(POLLIN | POLLERR | POLLHUP) != 0 else { continue }
            received = recv(fd, &buffer, buffer.count, 0)
            if received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if received < 0 { throw DNSError.socket(String(cString: strerror(errno))) }
        }
        let t4 = Date()
        guard received >= 48 else { throw DNSError.timeout }

        let t2 = ntpTimestampToDate(buffer, offset: 32) // receive timestamp
        let t3 = ntpTimestampToDate(buffer, offset: 40) // transmit timestamp

        let offset = ((t2.timeIntervalSince1970 - t1.timeIntervalSince1970)
            + (t3.timeIntervalSince1970 - t4.timeIntervalSince1970)) / 2
        let delay = (t4.timeIntervalSince(t1) - t3.timeIntervalSince(t2)) / 2

        let stratum = Int(buffer[1])
        let referenceID = String(decoding: buffer[12..<16], as: UTF8.self)

        return SNTPResult(
            server: server,
            address: address.numericAddress,
            offset: offset,
            delay: delay,
            stratum: stratum,
            referenceID: referenceID.trimmingCharacters(in: .controlCharacters),
            serverTime: t3,
            roundTrip: t4.timeIntervalSince(t1)
        )
    }

    private static func writeNTPTimestamp(_ date: Date, into packet: inout [UInt8], offset: Int) {
        let timestamp = date.timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(truncatingIfNeeded: Int64(timestamp.rounded(.down)))
        let fraction = UInt32((timestamp - timestamp.rounded(.down)) * 4_294_967_296)
        for byte in 0..<4 {
            let shift = UInt32((3 - byte) * 8)
            packet[offset + byte] = UInt8(truncatingIfNeeded: seconds >> shift)
            packet[offset + 4 + byte] = UInt8(truncatingIfNeeded: fraction >> shift)
        }
    }

    private static func ntpTimestampToDate(_ buffer: [UInt8], offset: Int) -> Date {
        let seconds = UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
            | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
        let fraction = UInt32(buffer[offset + 4]) << 24 | UInt32(buffer[offset + 5]) << 16
            | UInt32(buffer[offset + 6]) << 8 | UInt32(buffer[offset + 7])
        // NTP epoch starts 1900-01-01.
        let ntpEpoch: TimeInterval = 2_208_988_800
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(fraction) / 4_294_967_296 - ntpEpoch)
    }
}

// MARK: - WHOIS

public struct WhoisResult: Sendable {
    public let server: String
    public let query: String
    public let raw: String
    public let fields: [(String, String)]
    public let elapsed: TimeInterval
    public let error: String?
}

public enum WhoisClient {
    /// Query a WHOIS server (TCP 43) directly.
    public static func query(_ target: String, server explicitServer: String? = nil, timeout: TimeInterval = 10,
                             port: UInt16 = 43, cancellation: DiagnosticCancellation? = nil) async -> WhoisResult {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = explicitServer ?? DataStore.shared.whoisServer(for: cleanTarget) ?? "whois.iana.org"
        let start = Date()

        guard !cleanTarget.isEmpty,
              !cleanTarget.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return WhoisResult(server: server, query: target, raw: "", fields: [],
                               elapsed: 0, error: t("Enter a valid WHOIS query."))
        }
        if cancellation?.isCancelled == true {
            return WhoisResult(server: server, query: target, raw: "", fields: [],
                               elapsed: 0, error: t("Diagnostic cancelled"))
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let raw: String
                do {
                    raw = try performQuery(cleanTarget, server: server, port: port, timeout: timeout,
                                           start: start, cancellation: cancellation)
                } catch {
                    continuation.resume(returning: WhoisResult(server: server, query: target, raw: "", fields: [],
                                                              elapsed: Date().timeIntervalSince(start),
                                                              error: error.localizedDescription))
                    return
                }
                continuation.resume(returning: WhoisResult(
                    server: server,
                    query: target,
                    raw: raw,
                    fields: parseFields(raw),
                    elapsed: Date().timeIntervalSince(start),
                    error: raw.isEmpty ? t("The server returned an empty response.") : nil
                ))
            }
        }
    }

    private static func performQuery(_ target: String, server: String, port: UInt16, timeout: TimeInterval,
                                     start: Date, cancellation: DiagnosticCancellation?) throws -> String {
        let deadline = start.addingTimeInterval(max(0, timeout))
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(server, port: Int(port), timeout: timeout, cancellation: cancellation)
        } catch SocketAddressResolutionError.cancelled {
            throw WhoisQueryError.cancelled
        } catch SocketAddressResolutionError.timedOut {
            throw WhoisQueryError.timedOut
        } catch {
            if cancellation?.isCancelled == true { throw WhoisQueryError.cancelled }
            throw WhoisQueryError.cannotResolve(server)
        }
        guard let address = addresses.first else { throw WhoisQueryError.cannotResolve(server) }
        if cancellation?.isCancelled == true { throw WhoisQueryError.cancelled }

        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw WhoisQueryError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WhoisQueryError.socket(String(cString: strerror(errno)))
        }

        let connectStatus = address.withSockAddr { Darwin.connect(fd, $0, $1) }
        if connectStatus != 0 {
            let connectError = errno
            guard connectError == EINPROGRESS || connectError == EALREADY else {
                throw WhoisQueryError.socket(String(cString: strerror(connectError)))
            }
            _ = try waitForReadiness(fd: fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                throw WhoisQueryError.socket(String(cString: strerror(errno)))
            }
            guard socketError == 0 else { throw WhoisQueryError.socket(String(cString: strerror(socketError))) }
        }

        let request = Data((target + "\r\n").utf8)
        var sent = 0
        while sent < request.count {
            if cancellation?.isCancelled == true { throw WhoisQueryError.cancelled }
            let count = request.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                _ = try waitForReadiness(fd: fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
            } else {
                throw WhoisQueryError.socket(String(cString: strerror(errno)))
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1_500_000 {
            do {
                let events = try waitForReadiness(fd: fd, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
                guard events & Int16(POLLIN | POLLERR | POLLHUP) != 0 else { continue }
                let received = recv(fd, &buffer, min(buffer.count, 1_500_000 - data.count), 0)
                if received > 0 {
                    data.append(contentsOf: buffer[0..<received])
                } else if received == 0 {
                    break
                } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    throw WhoisQueryError.socket(String(cString: strerror(errno)))
                }
            } catch WhoisQueryError.timedOut where !data.isEmpty {
                break
            }
        }

        if data.isEmpty && Date() >= deadline { throw WhoisQueryError.timedOut }
        return String(decoding: data, as: UTF8.self)
    }

    private static func waitForReadiness(fd: Int32, events: Int16, deadline: Date,
                                         cancellation: DiagnosticCancellation?) throws -> Int16 {
        if cancellation?.isCancelled == true { throw WhoisQueryError.cancelled }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw WhoisQueryError.timedOut }
        guard let ready = waitForSocketReadiness(fd: fd, events: events, timeout: remaining, cancellation: cancellation) else {
            if cancellation?.isCancelled == true { throw WhoisQueryError.cancelled }
            throw WhoisQueryError.timedOut
        }
        return ready
    }

    /// Extract `Key: Value` pairs commonly used in WHOIS output.
    public static func parseFields(_ raw: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        var seen = Set<String>()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%"), !trimmed.hasPrefix("#") else { continue }
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            let identity = key.lowercased() + "|" + value
            if seen.insert(identity).inserted {
                fields.append((key, value))
            }
        }
        return fields
    }
}

private enum WhoisQueryError: LocalizedError {
    case cancelled
    case timedOut
    case cannotResolve(String)
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return t("Diagnostic cancelled")
        case .timedOut: return t("The WHOIS server did not answer in time.")
        case .cannotResolve(let server): return tf("Cannot resolve WHOIS server %@", server)
        case .socket(let message): return message
        }
    }
}
