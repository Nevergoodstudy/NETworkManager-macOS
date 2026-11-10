import Foundation
import Darwin

public enum PortStatus: String, Sendable {
    case open
    case closed
    case noResponse
    case filtered
    case openFiltered
    case error
}

public enum TCPProbeStage: String, Codable, Hashable, Sendable {
    case resolution
    case socket
    case connect
    case readiness
    case socketError
}

public enum TCPProbeFailureCode: String, Codable, Hashable, Sendable {
    case refused
    case timedOut
    case unreachable
    case permissionDenied
    case cancelled
    case resolution
    case execution
}

extension TCPProbeFailureCode {
    public var displayName: String {
        switch self {
        case .refused: return t("Connection refused")
        case .timedOut: return t("No response")
        case .unreachable: return t("Unreachable")
        case .permissionDenied: return t("Permission denied")
        case .cancelled: return t("Cancelled")
        case .resolution: return t("Resolution failed")
        case .execution: return t("Error")
        }
    }
}

/// Evidence for one numeric address. A nil code denotes a successful connection.
public struct TCPProbeAttempt: Codable, Hashable, Sendable {
    public let address: String
    public let family: Int32
    public let stage: TCPProbeStage
    public let code: TCPProbeFailureCode?
    public let message: String?
    /// errno from the failing system call, when that call returned an error.
    public let errno: Int32?
    /// Includes EINPROGRESS from the initial nonblocking connect.
    public let connectErrno: Int32?
    /// SO_ERROR read successfully with getsockopt; distinct from getsockopt's errno.
    public let soError: Int32?
    public let readinessEvents: Int16?
    public let readinessInterruptions: Int
    public let elapsed: TimeInterval

    public init(address: String, family: Int32, stage: TCPProbeStage,
                code: TCPProbeFailureCode? = nil, message: String? = nil,
                errno: Int32? = nil, connectErrno: Int32? = nil, soError: Int32? = nil,
                readinessEvents: Int16? = nil, readinessInterruptions: Int = 0,
                elapsed: TimeInterval) {
        self.address = address
        self.family = family
        self.stage = stage
        self.code = code
        self.message = message
        self.errno = errno
        self.connectErrno = connectErrno
        self.soError = soError
        self.readinessEvents = readinessEvents
        self.readinessInterruptions = readinessInterruptions
        self.elapsed = elapsed
    }
}

public struct TCPProbeFailure: Codable, Hashable, Sendable {
    public let code: TCPProbeFailureCode
    public let stage: TCPProbeStage
    public let message: String
    public let errno: Int32?
    public let address: String?
    public let soError: Int32?
    public let family: Int32?
    public let elapsed: TimeInterval?
    public let resolutionErrorCode: Int32?
    public let attempts: [TCPProbeAttempt]

    public init(code: TCPProbeFailureCode, stage: TCPProbeStage, message: String,
                errno: Int32? = nil, address: String? = nil, soError: Int32? = nil,
                family: Int32? = nil, elapsed: TimeInterval? = nil,
                resolutionErrorCode: Int32? = nil, attempts: [TCPProbeAttempt] = []) {
        self.code = code
        self.stage = stage
        self.message = message
        self.errno = errno
        self.address = address
        self.soError = soError
        self.family = family
        self.elapsed = elapsed
        self.resolutionErrorCode = resolutionErrorCode
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case code, stage, message, errno, address, soError, family, elapsed, resolutionErrorCode, attempts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(TCPProbeFailureCode.self, forKey: .code)
        stage = try values.decode(TCPProbeStage.self, forKey: .stage)
        message = try values.decode(String.self, forKey: .message)
        errno = try values.decodeIfPresent(Int32.self, forKey: .errno)
        address = try values.decodeIfPresent(String.self, forKey: .address)
        soError = try values.decodeIfPresent(Int32.self, forKey: .soError)
        family = try values.decodeIfPresent(Int32.self, forKey: .family)
        elapsed = try values.decodeIfPresent(TimeInterval.self, forKey: .elapsed)
        resolutionErrorCode = try values.decodeIfPresent(Int32.self, forKey: .resolutionErrorCode)
        attempts = try values.decodeIfPresent([TCPProbeAttempt].self, forKey: .attempts) ?? []
    }

    func recording(_ attempts: [TCPProbeAttempt]) -> TCPProbeFailure {
        TCPProbeFailure(code: code, stage: stage, message: message, errno: errno, address: address,
                        soError: soError, family: family, elapsed: elapsed,
                        resolutionErrorCode: resolutionErrorCode, attempts: attempts)
    }
}

public struct PortProbeResult: Sendable, Identifiable {
    public var id: Int { port }
    public let port: Int
    public let status: PortStatus
    public let latency: TimeInterval?
    public let message: String?
    public let failure: TCPProbeFailure?
    public let address: String?
    public let attempts: [TCPProbeAttempt]

    public init(port: Int, status: PortStatus, latency: TimeInterval?, message: String? = nil,
                failure: TCPProbeFailure? = nil, address: String? = nil,
                attempts: [TCPProbeAttempt] = []) {
        self.port = port
        self.status = status
        self.latency = latency
        self.message = message
        self.failure = failure
        self.address = address
        self.attempts = attempts.isEmpty ? (failure?.attempts ?? []) : attempts
    }
}

enum TCPConnectOutcome: Sendable {
    case connected(latency: TimeInterval, address: String, attempts: [TCPProbeAttempt])
    case failed(TCPProbeFailure)
}

struct TCPSocketCall {
    let result: Int32
    let errno: Int32?
}

struct TCPSocketPoll {
    let result: Int32
    let events: Int16
    let errno: Int32?
}

struct TCPSocketErrorRead {
    let value: Int32?
    let errno: Int32?
}

/// Only the socket boundary and monotonic clock are replaceable in deterministic checks.
protocol TCPSocketOperations {
    var now: TimeInterval { get }
    func makeSocket(family: Int32) -> TCPSocketCall
    func setNonBlocking(_ descriptor: Int32) -> TCPSocketCall
    func connect(_ descriptor: Int32, address: ResolvedSocketAddress) -> TCPSocketCall
    func poll(_ descriptor: Int32, milliseconds: Int32) -> TCPSocketPoll
    func socketError(_ descriptor: Int32) -> TCPSocketErrorRead
    func close(_ descriptor: Int32)
}

struct SystemTCPSocketOperations: TCPSocketOperations {
    var now: TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    func makeSocket(family: Int32) -> TCPSocketCall {
        let result = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        return TCPSocketCall(result: result, errno: result < 0 ? errno : nil)
    }

    func setNonBlocking(_ descriptor: Int32) -> TCPSocketCall {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return TCPSocketCall(result: -1, errno: errno) }
        let result = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        return TCPSocketCall(result: result, errno: result < 0 ? errno : nil)
    }

    func connect(_ descriptor: Int32, address: ResolvedSocketAddress) -> TCPSocketCall {
        let result = address.withSockAddr { Darwin.connect(descriptor, $0, $1) }
        return TCPSocketCall(result: result, errno: result < 0 ? errno : nil)
    }

    func poll(_ descriptor: Int32, milliseconds: Int32) -> TCPSocketPoll {
        var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(&item, 1, milliseconds)
        return TCPSocketPoll(result: result, events: item.revents, errno: result < 0 ? errno : nil)
    }

    func socketError(_ descriptor: Int32) -> TCPSocketErrorRead {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &value, &length)
        return TCPSocketErrorRead(value: result == 0 ? value : nil, errno: result < 0 ? errno : nil)
    }

    func close(_ descriptor: Int32) { _ = Darwin.close(descriptor) }
}

private enum ReadinessOutcome {
    case ready(events: Int16, interruptions: Int)
    case timedOut(interruptions: Int)
    case cancelled(interruptions: Int)
    case failed(errno: Int32, events: Int16, interruptions: Int)
}

typealias TCPAddressResolution = (String, Int, TimeInterval, DiagnosticCancellation?) throws -> [ResolvedSocketAddress]

/// TCP connect based port probing (also used by the IP scanner's "TCP" method).
public enum TCPProbe {
    /// Compatibility API. A nil result means the connection did not succeed;
    /// use `probe` when the failure reason matters.
    public static func connect(host: String, port: Int, timeout: TimeInterval = 1.5,
                               cancellation: DiagnosticCancellation? = nil) -> TimeInterval? {
        if case .connected(let latency, _, _) = probeOutcome(host: host, port: port, timeout: timeout, cancellation: cancellation) {
            return latency
        }
        return nil
    }

    static func connect(addresses: [ResolvedSocketAddress], timeout: TimeInterval,
                        cancellation: DiagnosticCancellation?) -> TimeInterval? {
        if case .connected(let latency, _, _) = connectOutcome(addresses: addresses, timeout: timeout, cancellation: cancellation) {
            return latency
        }
        return nil
    }

    static func connectOutcome(addresses: [ResolvedSocketAddress], timeout: TimeInterval,
                               cancellation: DiagnosticCancellation?,
                               operations: any TCPSocketOperations = SystemTCPSocketOperations()) -> TCPConnectOutcome {
        connectOutcome(addresses: addresses, deadline: operations.now + timeoutBudget(timeout),
                       cancellation: cancellation, operations: operations)
    }

    private static func connectOutcome(addresses: [ResolvedSocketAddress], deadline: TimeInterval,
                                       cancellation: DiagnosticCancellation?,
                                       operations: any TCPSocketOperations) -> TCPConnectOutcome {
        var attempts: [TCPProbeAttempt] = []
        var failures: [TCPProbeFailure] = []
        guard cancellation?.isCancelled != true else { return .failed(cancelled(stage: .connect)) }
        guard operations.now < deadline else { return .failed(timedOut(stage: .connect)) }

        func record(_ source: TCPProbeFailure, address: ResolvedSocketAddress, started: TimeInterval,
                    connectErrno: Int32? = nil, events: Int16? = nil, interruptions: Int = 0) {
            let elapsed = max(0, operations.now - started)
            attempts.append(TCPProbeAttempt(address: address.numericAddress, family: address.family,
                                            stage: source.stage, code: source.code, message: source.message,
                                            errno: source.errno, connectErrno: connectErrno, soError: source.soError,
                                            readinessEvents: events, readinessInterruptions: interruptions,
                                            elapsed: elapsed))
            failures.append(TCPProbeFailure(code: source.code, stage: source.stage, message: source.message,
                                            errno: source.errno, address: address.numericAddress,
                                            soError: source.soError, family: address.family, elapsed: elapsed))
        }

        func terminalFailure(at address: ResolvedSocketAddress, read: TCPSocketErrorRead? = nil) -> TCPProbeFailure? {
            let source: TCPProbeFailure
            if cancellation?.isCancelled == true {
                source = cancelled(stage: .socketError, address: address.numericAddress)
            } else if operations.now >= deadline {
                source = timedOut(stage: .socketError, address: address.numericAddress)
            } else { return nil }
            return TCPProbeFailure(code: source.code, stage: source.stage, message: source.message,
                                   errno: read?.errno, address: address.numericAddress, soError: read?.value)
        }

        func connected(_ address: ResolvedSocketAddress, started: TimeInterval, connectStarted: TimeInterval,
                       stage: TCPProbeStage, connectErrno: Int32? = nil, soError: Int32? = nil,
                       events: Int16? = nil, interruptions: Int = 0) -> TCPConnectOutcome {
            let finished = operations.now
            attempts.append(TCPProbeAttempt(address: address.numericAddress, family: address.family,
                                            stage: stage, connectErrno: connectErrno, soError: soError,
                                            readinessEvents: events, readinessInterruptions: interruptions,
                                            elapsed: max(0, finished - started)))
            return .connected(latency: max(0, finished - connectStarted), address: address.numericAddress,
                              attempts: attempts)
        }

        for address in addresses {
            if cancellation?.isCancelled == true {
                return .failed(cancelled(stage: .connect, address: address.numericAddress).recording(attempts))
            }
            guard operations.now < deadline else {
                return .failed(timedOut(stage: .connect, address: address.numericAddress).recording(attempts))
            }
            let started = operations.now
            let created = operations.makeSocket(family: address.family)
            guard created.result >= 0 else {
                record(failure(created.errno ?? EIO, stage: .socket, address: address.numericAddress),
                       address: address, started: started)
                continue
            }
            let fd = created.result
            defer { operations.close(fd) }

            let configured = operations.setNonBlocking(fd)
            guard configured.result >= 0 else {
                record(failure(configured.errno ?? EIO, stage: .socket, address: address.numericAddress),
                       address: address, started: started)
                continue
            }
            if cancellation?.isCancelled == true {
                record(cancelled(stage: .connect, address: address.numericAddress), address: address, started: started)
                return .failed(failures.last!.recording(attempts))
            }
            guard operations.now < deadline else {
                record(timedOut(stage: .connect, address: address.numericAddress), address: address, started: started)
                return .failed(failures.last!.recording(attempts))
            }

            let connectStarted = operations.now
            let result = operations.connect(fd, address: address)
            if cancellation?.isCancelled == true {
                record(cancelled(stage: .connect, address: address.numericAddress), address: address,
                       started: started, connectErrno: result.errno)
                return .failed(failures.last!.recording(attempts))
            }
            guard operations.now < deadline else {
                record(timedOut(stage: .connect, address: address.numericAddress), address: address,
                       started: started, connectErrno: result.errno)
                return .failed(failures.last!.recording(attempts))
            }
            if result.result == 0 {
                return connected(address, started: started, connectStarted: connectStarted, stage: .connect)
            }
            let connectErrno = result.errno ?? EIO
            guard connectErrno == EINPROGRESS || connectErrno == EWOULDBLOCK else {
                record(failure(connectErrno, stage: .connect, address: address.numericAddress),
                       address: address, started: started, connectErrno: connectErrno)
                continue
            }

            switch wait(fd: fd, deadline: deadline, cancellation: cancellation, operations: operations) {
            case .cancelled(let interruptions):
                record(cancelled(stage: .readiness, address: address.numericAddress), address: address,
                       started: started, connectErrno: connectErrno, interruptions: interruptions)
                return .failed(failures.last!.recording(attempts))
            case .timedOut(let interruptions):
                record(timedOut(stage: .readiness, address: address.numericAddress), address: address,
                       started: started, connectErrno: connectErrno, interruptions: interruptions)
                return .failed(failures.last!.recording(attempts))
            case .failed(let code, let events, let interruptions):
                record(failure(code, stage: .readiness, address: address.numericAddress), address: address,
                       started: started, connectErrno: connectErrno, events: events, interruptions: interruptions)
            case .ready(let events, let interruptions):
                guard events & Int16(POLLNVAL) == 0,
                      events & Int16(POLLOUT | POLLERR | POLLHUP) != 0 else {
                    let source = TCPProbeFailure(code: .execution, stage: .readiness,
                                                 message: "Socket readiness returned an invalid event.",
                                                 address: address.numericAddress)
                    record(source, address: address, started: started, connectErrno: connectErrno,
                           events: events, interruptions: interruptions)
                    continue
                }
                if let source = terminalFailure(at: address) {
                    record(source, address: address, started: started, connectErrno: connectErrno,
                           events: events, interruptions: interruptions)
                    return .failed(failures.last!.recording(attempts))
                }
                // Readiness alone is not connection success. SO_ERROR is read once because it clears the pending error.
                let error = operations.socketError(fd)
                if let source = terminalFailure(at: address, read: error) {
                    record(source, address: address, started: started, connectErrno: connectErrno,
                           events: events, interruptions: interruptions)
                    return .failed(failures.last!.recording(attempts))
                }
                guard let soError = error.value else {
                    record(failure(error.errno ?? EIO, stage: .socketError, address: address.numericAddress),
                           address: address, started: started, connectErrno: connectErrno,
                           events: events, interruptions: interruptions)
                    continue
                }
                if soError == 0 {
                    return connected(address, started: started, connectStarted: connectStarted, stage: .socketError,
                                     connectErrno: connectErrno, soError: 0, events: events, interruptions: interruptions)
                }
                let source = TCPProbeFailure(code: category(soError), stage: .socketError,
                                             message: String(cString: strerror(soError)),
                                             address: address.numericAddress, soError: soError)
                record(source, address: address, started: started, connectErrno: connectErrno,
                       events: events, interruptions: interruptions)
            }
        }
        if cancellation?.isCancelled == true {
            return .failed(cancelled(stage: .connect).recording(attempts))
        }
        return .failed(aggregate(failures).recording(attempts))
    }

    /// Probe a single port and classify its result while preserving every address attempt.
    public static func probe(host: String, port: Int, timeout: TimeInterval = 1.5,
                             cancellation: DiagnosticCancellation? = nil) -> PortProbeResult {
        result(port: port, outcome: probeOutcome(host: host, port: port, timeout: timeout, cancellation: cancellation))
    }

    static func result(port: Int, outcome: TCPConnectOutcome) -> PortProbeResult {
        switch outcome {
        case .connected(let latency, let address, let attempts):
            return PortProbeResult(port: port, status: .open, latency: latency, address: address, attempts: attempts)
        case .failed(let failure):
            let status: PortStatus = failure.code == .refused ? .closed : (failure.code == .timedOut ? .noResponse : .error)
            return PortProbeResult(port: port, status: status, latency: nil, message: failure.message,
                                   failure: failure, address: failure.address, attempts: failure.attempts)
        }
    }

    static func probeOutcome(host: String, port: Int, timeout: TimeInterval,
                             cancellation: DiagnosticCancellation?,
                             operations: any TCPSocketOperations = SystemTCPSocketOperations(),
                             resolver: TCPAddressResolution = { host, port, timeout, cancellation in
                                 try SocketAddressResolver.resolve(host, port: port, timeout: timeout, cancellation: cancellation)
                             }) -> TCPConnectOutcome {
        let started = operations.now
        let deadline = started + timeoutBudget(timeout)
        guard cancellation?.isCancelled != true else { return .failed(cancelled(stage: .resolution)) }
        guard operations.now < deadline else { return .failed(timedOut(stage: .resolution)) }
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try resolver(host, port, max(0, deadline - operations.now), cancellation)
        } catch let error as SocketAddressResolutionError {
            let elapsed = max(0, operations.now - started)
            switch error {
            case .cancelled: return .failed(cancelled(stage: .resolution, elapsed: elapsed))
            case .timedOut: return .failed(timedOut(stage: .resolution, elapsed: elapsed))
            case .service(let code):
                return .failed(TCPProbeFailure(code: .resolution, stage: .resolution, message: error.localizedDescription,
                                               elapsed: elapsed, resolutionErrorCode: code))
            case .noAddresses:
                return .failed(TCPProbeFailure(code: .resolution, stage: .resolution,
                                               message: error.localizedDescription, elapsed: elapsed))
            }
        } catch {
            return .failed(TCPProbeFailure(code: .resolution, stage: .resolution, message: error.localizedDescription,
                                           elapsed: max(0, operations.now - started)))
        }
        // Resolution and all connection attempts share this exact monotonic deadline.
        return connectOutcome(addresses: addresses, deadline: deadline, cancellation: cancellation, operations: operations)
    }

    private static func wait(fd: Int32, deadline: TimeInterval,
                             cancellation: DiagnosticCancellation?,
                             operations: any TCPSocketOperations) -> ReadinessOutcome {
        var interruptions = 0
        while true {
            if cancellation?.isCancelled == true { return .cancelled(interruptions: interruptions) }
            let remaining = deadline - operations.now
            guard remaining > 0 else { return .timedOut(interruptions: interruptions) }
            let milliseconds = Int32(max(1, min(50, ceil(remaining * 1_000))))
            let result = operations.poll(fd, milliseconds: milliseconds)
            if cancellation?.isCancelled == true { return .cancelled(interruptions: interruptions) }
            if result.result < 0 {
                if result.errno == EINTR { interruptions += 1; continue }
                return .failed(errno: result.errno ?? EIO, events: result.events, interruptions: interruptions)
            }
            if operations.now >= deadline { return .timedOut(interruptions: interruptions) }
            if result.result > 0 { return .ready(events: result.events, interruptions: interruptions) }
        }
    }

    static func aggregate(_ failures: [TCPProbeFailure]) -> TCPProbeFailure {
        guard !failures.isEmpty else {
            return TCPProbeFailure(code: .execution, stage: .socket, message: "No TCP connection attempt was made.")
        }
        if failures.allSatisfy({ $0.code == .refused }) { return failures[0] }
        for code in [TCPProbeFailureCode.cancelled, .permissionDenied, .unreachable, .timedOut, .execution, .resolution] {
            if let failure = failures.first(where: { $0.code == code }) { return failure }
        }
        return failures[0]
    }

    static func failure(_ code: Int32, stage: TCPProbeStage, address: String?) -> TCPProbeFailure {
        let category: TCPProbeFailureCode
        switch stage {
        case .connect: category = Self.category(code)
        case .socket: category = code == EACCES || code == EPERM ? .permissionDenied : .execution
        case .readiness, .socketError, .resolution: category = .execution
        }
        return TCPProbeFailure(code: category, stage: stage, message: String(cString: strerror(code)),
                               errno: code, address: address)
    }

    private static func category(_ code: Int32) -> TCPProbeFailureCode {
        switch code {
        case ECONNREFUSED: return .refused
        case ETIMEDOUT: return .timedOut
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN: return .unreachable
        case EACCES, EPERM: return .permissionDenied
        default: return .execution
        }
    }

    private static func timedOut(stage: TCPProbeStage, address: String? = nil,
                                 elapsed: TimeInterval? = nil) -> TCPProbeFailure {
        TCPProbeFailure(code: .timedOut, stage: stage,
                        message: stage == .resolution ? t("Host address resolution timed out.") : t("Connection attempt timed out."),
                        address: address, elapsed: elapsed)
    }

    private static func cancelled(stage: TCPProbeStage, address: String? = nil,
                                  elapsed: TimeInterval? = nil) -> TCPProbeFailure {
        TCPProbeFailure(code: .cancelled, stage: stage, message: t("Diagnostic cancelled"), address: address, elapsed: elapsed)
    }

    private static func timeoutBudget(_ timeout: TimeInterval) -> TimeInterval {
        timeout.isNaN ? 0 : max(0, timeout)
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
        let limit = max(0, min(maximum, 65_535))
        guard limit > 0 else { return [] }
        var ports = Set<Int>()
        for chunk in input.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let token = chunk.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if token.contains("-") {
                let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, parts[0] <= parts[1] {
                    let lower = max(1, parts[0])
                    let upper = min(parts[1], limit)
                    if lower <= upper {
                        for port in lower...upper { ports.insert(port) }
                    }
                }
            } else if let port = Int(token), port > 0, port <= limit {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }
}
