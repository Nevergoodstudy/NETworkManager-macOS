import Foundation

public enum PortStatus: String, Sendable {
    case open
    case closed
    case filtered
    case openFiltered
    case error
}

public struct PortProbeResult: Sendable, Identifiable {
    public var id: Int { port }
    public let port: Int
    public let status: PortStatus
    public let latency: TimeInterval?
    public let message: String?

    public init(port: Int, status: PortStatus, latency: TimeInterval?, message: String? = nil) {
        self.port = port
        self.status = status
        self.latency = latency
        self.message = message
    }
}

/// TCP connect based port probing (also used by the IP scanner's "TCP" method).
public enum TCPProbe {
    /// Attempt a TCP connection and report whether it succeeded.
    ///
    /// - Returns: `nil` when the port is closed / rejected, latency on success.
    public static func connect(host: String, port: Int, timeout: TimeInterval = 1.5, cancellation: DiagnosticCancellation? = nil) -> TimeInterval? {
        guard let addresses = try? SocketAddressResolver.resolve(host, port: port, timeout: timeout, cancellation: cancellation) else { return nil }
        return connect(addresses: addresses, timeout: timeout, cancellation: cancellation)
    }

    static func connect(addresses: [ResolvedSocketAddress], timeout: TimeInterval,
                        cancellation: DiagnosticCancellation?) -> TimeInterval? {
        guard cancellation?.isCancelled != true else { return nil }
        for address in addresses {
            if cancellation?.isCancelled == true { return nil }
            let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
            if fd < 0 { continue }
            defer { close(fd) }

            // Non blocking connect + poll for timeout control.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let start = Date()
            let connectResult = address.withSockAddr { Darwin.connect(fd, $0, $1) }
            if connectResult == 0 {
                return 0
            }
            if errno != EINPROGRESS {
                continue
            }

            guard let events = waitForSocketReadiness(fd: fd, events: Int16(POLLOUT), timeout: timeout, cancellation: cancellation),
                  events & Int16(POLLOUT | POLLERR | POLLHUP) != 0 else {
                continue
            }

            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError == 0 {
                return Date().timeIntervalSince(start)
            }
        }
        return nil
    }

    /// Probe a single port and classify the result.
    public static func probe(host: String, port: Int, timeout: TimeInterval = 1.5, cancellation: DiagnosticCancellation? = nil) -> PortProbeResult {
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(host, port: port, timeout: timeout, cancellation: cancellation)
        } catch SocketAddressResolutionError.cancelled {
            return PortProbeResult(port: port, status: .error, latency: nil, message: t("Diagnostic cancelled"))
        } catch SocketAddressResolutionError.timedOut {
            return PortProbeResult(port: port, status: .error, latency: nil, message: t("Host address resolution timed out."))
        } catch {
            return PortProbeResult(port: port, status: .error, latency: nil, message: error.localizedDescription)
        }
        let latency = connect(addresses: addresses, timeout: timeout, cancellation: cancellation)
        if cancellation?.isCancelled == true {
            return PortProbeResult(port: port, status: .error, latency: nil, message: t("Diagnostic cancelled"))
        }
        if let latency {
            return PortProbeResult(port: port, status: .open, latency: latency)
        }
        return PortProbeResult(port: port, status: .closed, latency: nil)
    }

    /// Probe a range of ports concurrently.
    public static func scan(host: String,
                            ports: [Int],
                            timeout: TimeInterval = 1.5,
                            concurrency: Int = 128,
                            cancellation: DiagnosticCancellation? = nil,
                            progress: (@Sendable (PortProbeResult) -> Void)? = nil) async -> [PortProbeResult] {
        await withTaskGroup(of: PortProbeResult.self) { group in
            var results: [PortProbeResult] = []
            var index = 0
            let width = max(1, min(concurrency, ports.count))

            while index < width, index < ports.count, cancellation?.isCancelled != true {
                let port = ports[index]
                group.addTask { probe(host: host, port: port, timeout: timeout, cancellation: cancellation) }
                index += 1
            }

            while let result = await group.next() {
                if cancellation?.isCancelled == true {
                    group.cancelAll()
                    break
                }
                results.append(result)
                progress?(result)
                if index < ports.count, cancellation?.isCancelled != true {
                    let port = ports[index]
                    group.addTask { probe(host: host, port: port, timeout: timeout, cancellation: cancellation) }
                    index += 1
                }
            }
            return results.sorted { $0.port < $1.port }
        }
    }

    /// Parse expressions like `22;80,443`, `1-1024`, `21,22,80-90`.
    public static func parsePorts(_ input: String, maximum: Int = 65_535) -> [Int] {
        var ports = Set<Int>()
        for chunk in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let token = chunk.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if token.contains("-") {
                let parts = token.split(separator: "-", maxSplits: 1).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, parts[0] <= parts[1] {
                    for port in parts[0]...min(parts[1], maximum) where port > 0 { ports.insert(port) }
                }
            } else if let port = Int(token), port > 0, port <= maximum {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }
}
