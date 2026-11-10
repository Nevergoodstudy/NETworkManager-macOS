import Foundation
import Darwin
@testable import NMCore

private struct TCPSocketPlan {
    var socketErrno: Int32?
    var configurationErrno: Int32?
    var connectErrno: Int32? = EINPROGRESS
    var soError: Int32 = 0
    var socketErrorErrno: Int32?
    var events: [TCPFixturePoll] = [.ready(Int16(POLLOUT))]
    var socketDelay: TimeInterval = 0
    var configurationDelay: TimeInterval = 0
    var connectDelay: TimeInterval = 0
    var socketErrorDelay: TimeInterval = 0
}

private enum TCPFixturePoll {
    case ready(Int16)
    case timeout
    case failure(Int32)
}

private final class TCPSocketFixture: TCPSocketOperations {
    private final class SocketState {
        let plan: TCPSocketPlan
        var pollIndex = 0
        init(_ plan: TCPSocketPlan) { self.plan = plan }
    }

    private let plans: [TCPSocketPlan]
    private var sockets: [Int32: SocketState] = [:]
    private(set) var clock: TimeInterval = 100
    private(set) var socketCalls: [Int32] = []
    private(set) var connectCalls = 0
    private(set) var socketErrorCalls = 0
    private(set) var closed: [Int32] = []
    private(set) var pollMilliseconds: [Int32] = []
    var onPoll: (() -> Void)?
    var onSocketError: (() -> Void)?

    init(_ plans: [TCPSocketPlan]) { self.plans = plans }
    var now: TimeInterval { clock }
    func advance(_ interval: TimeInterval) { clock += interval }

    func makeSocket(family: Int32) -> TCPSocketCall {
        let index = socketCalls.count
        socketCalls.append(family)
        guard index < plans.count else { return TCPSocketCall(result: -1, errno: EMFILE) }
        let plan = plans[index]
        advance(plan.socketDelay)
        if let code = plan.socketErrno { return TCPSocketCall(result: -1, errno: code) }
        let descriptor = Int32(index + 100)
        sockets[descriptor] = SocketState(plan)
        return TCPSocketCall(result: descriptor, errno: nil)
    }

    func setNonBlocking(_ descriptor: Int32) -> TCPSocketCall {
        guard let state = sockets[descriptor] else { return TCPSocketCall(result: -1, errno: EBADF) }
        advance(state.plan.configurationDelay)
        return TCPSocketCall(result: state.plan.configurationErrno == nil ? 0 : -1,
                             errno: state.plan.configurationErrno)
    }

    func connect(_ descriptor: Int32, address: ResolvedSocketAddress) -> TCPSocketCall {
        connectCalls += 1
        guard let state = sockets[descriptor] else { return TCPSocketCall(result: -1, errno: EBADF) }
        advance(state.plan.connectDelay)
        return TCPSocketCall(result: state.plan.connectErrno == nil ? 0 : -1, errno: state.plan.connectErrno)
    }

    func poll(_ descriptor: Int32, milliseconds: Int32) -> TCPSocketPoll {
        pollMilliseconds.append(milliseconds)
        onPoll?()
        guard let state = sockets[descriptor] else { return TCPSocketPoll(result: -1, events: 0, errno: EBADF) }
        let event = state.pollIndex < state.plan.events.count ? state.plan.events[state.pollIndex] : .timeout
        state.pollIndex += 1
        switch event {
        case .ready(let events):
            advance(0.001)
            return TCPSocketPoll(result: 1, events: events, errno: nil)
        case .timeout:
            advance(TimeInterval(milliseconds) / 1_000)
            return TCPSocketPoll(result: 0, events: 0, errno: nil)
        case .failure(let code):
            advance(0.001)
            return TCPSocketPoll(result: -1, events: 0, errno: code)
        }
    }

    func socketError(_ descriptor: Int32) -> TCPSocketErrorRead {
        socketErrorCalls += 1
        guard let state = sockets[descriptor] else { return TCPSocketErrorRead(value: nil, errno: EBADF) }
        advance(state.plan.socketErrorDelay)
        onSocketError?()
        return TCPSocketErrorRead(value: state.plan.socketErrorErrno == nil ? state.plan.soError : nil,
                                  errno: state.plan.socketErrorErrno)
    }

    func close(_ descriptor: Int32) {
        closed.append(descriptor)
        sockets.removeValue(forKey: descriptor)
    }
}

enum TCPProbeChecks {
    static func run() throws {
        try check(TCPProbe.parsePorts("").isEmpty && TCPProbe.parsePorts(" , ; ").isEmpty,
                  "Empty port expressions should produce no work")
        try check(TCPProbe.parsePorts("70000-80000").isEmpty,
                  "A port range entirely above the valid limit must not create a descending ClosedRange")
        try check(TCPProbe.parsePorts("65534-80000") == [65_534, 65_535],
                  "A range crossing the maximum valid port should be clipped safely")
        try check(TCPProbe.parsePorts("65535-\(Int.max)") == [65_535]
                    && TCPProbe.parsePorts("\(Int.max)-\(Int.max)").isEmpty,
                  "Extreme range endpoints should not overflow or create an invalid range")
        try check(TCPProbe.parsePorts("1-65535", maximum: 0).isEmpty
                    && TCPProbe.parsePorts("1-65535", maximum: -1).isEmpty
                    && TCPProbe.parsePorts("1-65535", maximum: Int.min).isEmpty,
                  "Zero and negative maximums should produce no valid ports")
        try check(TCPProbe.parsePorts("65535,65536,65535-70000", maximum: Int.max) == [65_535],
                  "An extreme caller-provided maximum must not admit ports above 65535")
        try check(TCPProbe.parsePorts("1-20,22", maximum: 3) == [1, 2, 3],
                  "A smaller caller-provided maximum should apply to ranges and individual ports")
        try check(TCPProbe.parsePorts("-22,-1-3,3-1,1-,--,9999999999999999999999999999").isEmpty,
                  "Malformed, negative, reversed and overflowing port expressions should be rejected")
        try check(TCPProbe.parsePorts("0-2,2;1 0") == [1, 2],
                  "Valid ports should remain sorted and deduplicated after clipping zero")

        let ipv4 = try fixtureAddress("192.0.2.1", family: AF_INET)
        let ipv6 = try fixtureAddress("2001:db8::1", family: AF_INET6)
        let addresses = [ipv4, ipv6]

        let immediate = TCPSocketFixture([TCPSocketPlan(connectErrno: nil)])
        let immediateResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                                       cancellation: nil, operations: immediate))
        try check(immediateResult.status == .open && immediateResult.attempts.count == 1,
                  "An immediate TCP connection should retain its successful address attempt")
        try check(immediateResult.attempts[0].family == AF_INET && immediateResult.attempts[0].code == nil,
                  "A successful TCP attempt should retain numeric address family and have no failure code")
        try check(immediate.socketErrorCalls == 0 && immediate.closed.count == 1,
                  "An immediate connection should close its socket without reading SO_ERROR")

        let pending = TCPSocketFixture([TCPSocketPlan()])
        let pendingResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                                     cancellation: nil, operations: pending))
        try check(pendingResult.status == .open && pendingResult.attempts[0].connectErrno == EINPROGRESS,
                  "A pending connection should preserve connect's EINPROGRESS separately")
        try check(pendingResult.attempts[0].soError == 0 && pending.socketErrorCalls == 1,
                  "A writable TCP socket should be considered connected only after reading SO_ERROR once")

        let refused = TCPSocketFixture([TCPSocketPlan(soError: ECONNREFUSED)])
        let refusalResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                                     cancellation: nil, operations: refused))
        try check(refusalResult.status == .closed && refusalResult.failure?.soError == ECONNREFUSED,
                  "Explicit SO_ERROR refusal should produce a closed port and preserve SO_ERROR")
        try check(refusalResult.failure?.errno == nil && refusalResult.attempts[0].errno == nil,
                  "A successful getsockopt must not report SO_ERROR as getsockopt's errno")
        try check(refusalResult.attempts[0].elapsed > 0 && refusalResult.attempts[0].address == "192.0.2.1",
                  "TCP evidence should retain per-address elapsed time and numeric address")

        let timeout = TCPSocketFixture([TCPSocketPlan(events: [.timeout]), TCPSocketPlan()])
        let timeoutResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: addresses, timeout: 0.12,
                                                                                     cancellation: nil, operations: timeout))
        try check(timeoutResult.status == .noResponse && timeoutResult.failure?.code == .timedOut,
                  "Poll timeout should mean no response rather than filtered or permission denied")
        try check(timeoutResult.failure?.errno == nil && timeoutResult.attempts[0].stage == .readiness,
                  "Poll timeout should remain distinct from an operating system error")
        try check(timeout.socketCalls.count == 1 && timeout.connectCalls == 1 && timeout.closed.count == 1,
                  "An expired deadline should prevent sockets and connects for subsequent addresses")
        try check(timeout.pollMilliseconds.allSatisfy { (1...50).contains($0) } && timeout.clock <= 100.121,
                  "TCP readiness polling should share a bounded monotonic deadline")

        for code in [EACCES, EPERM] {
            let fixture = TCPSocketFixture([TCPSocketPlan(connectErrno: code)])
            let result = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                                    cancellation: nil, operations: fixture))
            try check(result.status == .error && result.failure?.code == .permissionDenied && result.failure?.errno == code,
                      "Permission errno should remain a permission-related error without a Local Network denial claim")
            try check(result.attempts[0].stage == .connect && fixture.closed.count == 1,
                      "Immediate connect failure should preserve its source and release the socket")
        }

        for code in [ENETUNREACH, EHOSTUNREACH, ENETDOWN] {
            let fixture = TCPSocketFixture([TCPSocketPlan(soError: code)])
            let result = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv6], timeout: 1,
                                                                                    cancellation: nil, operations: fixture))
            try check(result.status == .error && result.failure?.code == .unreachable && result.failure?.soError == code,
                      "A route or interface error should preserve SO_ERROR and remain distinct from refusal")
        }

        let pollError = TCPSocketFixture([TCPSocketPlan(events: [.failure(EIO)])])
        let pollFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1, cancellation: nil, operations: pollError))
        try check(pollFailure.code == .execution && pollFailure.stage == .readiness && pollFailure.errno == EIO,
                  "Poll failure should retain readiness-stage errno")
        try check(pollError.socketErrorCalls == 0 && pollError.closed.count == 1,
                  "Poll failure must release the socket without reading SO_ERROR")

        let pollErrnoTimeout = TCPSocketFixture([TCPSocketPlan(events: [.failure(ETIMEDOUT)])])
        let pollErrnoFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                  cancellation: nil, operations: pollErrnoTimeout))
        try check(pollErrnoFailure.code == .execution && pollErrnoFailure.errno == ETIMEDOUT,
                  "A poll syscall error must remain distinct from a poll deadline expiry")

        let socketError = TCPSocketFixture([TCPSocketPlan(socketErrorErrno: EBADF)])
        let socketFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1, cancellation: nil, operations: socketError))
        try check(socketFailure.stage == .socketError && socketFailure.errno == EBADF && socketFailure.soError == nil,
                  "A getsockopt failure should preserve its errno without inventing an SO_ERROR value")

        let socketRefusal = TCPSocketFixture([TCPSocketPlan(socketErrorErrno: ECONNREFUSED)])
        let socketRefusalFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                      cancellation: nil, operations: socketRefusal))
        try check(socketRefusalFailure.code == .execution && socketRefusalFailure.soError == nil,
                  "A getsockopt syscall error must not be treated as an explicit connection refusal")

        let lateSocketError = TCPSocketFixture([TCPSocketPlan(socketErrorDelay: 0.2), TCPSocketPlan()])
        let lateSocketFailure = try failure(TCPProbe.connectOutcome(addresses: addresses, timeout: 0.1,
                                                                    cancellation: nil, operations: lateSocketError))
        try check(lateSocketFailure.code == .timedOut && lateSocketFailure.stage == .socketError
                    && lateSocketFailure.soError == 0 && lateSocketError.socketCalls.count == 1
                    && lateSocketError.closed.count == 1,
                  "An SO_ERROR result observed after the deadline should retain its value without reporting late success")

        let socketErrorCancellation = DiagnosticCancellation()
        let cancelledSocketError = TCPSocketFixture([TCPSocketPlan(soError: ECONNREFUSED), TCPSocketPlan()])
        cancelledSocketError.onSocketError = { socketErrorCancellation.cancel() }
        let cancelledSocketFailure = try failure(TCPProbe.connectOutcome(addresses: addresses, timeout: 1,
                                                                         cancellation: socketErrorCancellation,
                                                                         operations: cancelledSocketError))
        try check(cancelledSocketFailure.code == .cancelled && cancelledSocketFailure.stage == .socketError
                    && cancelledSocketFailure.soError == ECONNREFUSED && cancelledSocketError.socketCalls.count == 1
                    && cancelledSocketError.closed.count == 1,
                  "Cancellation during SO_ERROR reads should preserve the observed socket error and prevent more addresses")

        let interrupted = TCPSocketFixture([TCPSocketPlan(events: [.failure(EINTR), .ready(Int16(POLLOUT))])])
        let interruptedResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                                         cancellation: nil, operations: interrupted))
        try check(interruptedResult.status == .open && interruptedResult.attempts[0].readinessInterruptions == 1,
                  "Interrupted poll should retry under the same deadline and retain the interruption count")

        let invalid = TCPSocketFixture([TCPSocketPlan(events: [.ready(Int16(POLLNVAL))])])
        let invalidFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1, cancellation: nil, operations: invalid))
        try check(invalidFailure.code == .execution && invalidFailure.attempts[0].readinessEvents == Int16(POLLNVAL)
                    && invalid.socketErrorCalls == 0,
                  "Invalid readiness should retain its event bits and must not appear connected")

        let cancellation = DiagnosticCancellation()
        let cancelled = TCPSocketFixture([TCPSocketPlan(), TCPSocketPlan()])
        cancelled.onPoll = { cancellation.cancel() }
        let cancelledFailure = try failure(TCPProbe.connectOutcome(addresses: addresses, timeout: 1,
                                                                  cancellation: cancellation, operations: cancelled))
        try check(cancelledFailure.code == .cancelled && cancelledFailure.stage == .readiness,
                  "Cancellation while waiting should remain distinct from timeout and poll failure")
        try check(cancelled.socketCalls.count == 1 && cancelled.closed.count == 1 && cancelled.socketErrorCalls == 0,
                  "Cancellation should close the active socket and prevent subsequent address attempts")

        let alreadyCancelled = DiagnosticCancellation()
        alreadyCancelled.cancel()
        let untouched = TCPSocketFixture([TCPSocketPlan()])
        let preCancelledFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1,
                                                                     cancellation: alreadyCancelled, operations: untouched))
        try check(preCancelledFailure.code == .cancelled && untouched.socketCalls.isEmpty,
                  "Pre-cancelled TCP work should not allocate a socket")

        let mixed = TCPSocketFixture([TCPSocketPlan(connectErrno: ECONNREFUSED), TCPSocketPlan(soError: ENETUNREACH)])
        let mixedResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: addresses, timeout: 1,
                                                                                   cancellation: nil, operations: mixed))
        try check(mixedResult.status == .error && mixedResult.failure?.code == .unreachable && mixedResult.attempts.count == 2,
                  "Mixed refusal and unreachable addresses must retain both attempts and must not mark the port closed")
        try check(mixedResult.attempts[0].errno == ECONNREFUSED && mixedResult.attempts[1].soError == ENETUNREACH,
                  "Aggregate results should preserve each address's distinct failure source")

        let allRefused = TCPSocketFixture([TCPSocketPlan(connectErrno: ECONNREFUSED), TCPSocketPlan(soError: ECONNREFUSED)])
        let allRefusedResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: addresses, timeout: 1,
                                                                                        cancellation: nil, operations: allRefused))
        try check(allRefusedResult.status == .closed && allRefusedResult.attempts.count == 2 && allRefused.closed.count == 2,
                  "A multi-address port should be closed only when every attempt explicitly refuses")

        let fallback = TCPSocketFixture([TCPSocketPlan(connectErrno: ECONNREFUSED), TCPSocketPlan()])
        let fallbackResult = TCPProbe.result(port: 443, outcome: TCPProbe.connectOutcome(addresses: addresses, timeout: 1,
                                                                                      cancellation: nil, operations: fallback))
        try check(fallbackResult.status == .open && fallbackResult.attempts.count == 2 && fallbackResult.address == "2001:db8::1",
                  "A successful fallback address should retain the preceding failed attempt")

        let setup = TCPSocketFixture([TCPSocketPlan(configurationErrno: EACCES)])
        let setupFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1, cancellation: nil, operations: setup))
        try check(setupFailure.stage == .socket && setupFailure.errno == EACCES && setup.closed.count == 1 && setup.connectCalls == 0,
                  "A socket configuration failure should preserve errno and close without connecting")

        let allocation = TCPSocketFixture([TCPSocketPlan(socketErrno: EMFILE)])
        let allocationFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 1, cancellation: nil, operations: allocation))
        try check(allocationFailure.stage == .socket && allocationFailure.errno == EMFILE && allocation.closed.isEmpty,
                  "A socket allocation failure should preserve errno without closing an invalid descriptor")

        let beforeConnect = TCPSocketFixture([TCPSocketPlan(configurationDelay: 0.2)])
        let beforeConnectFailure = try failure(TCPProbe.connectOutcome(addresses: addresses, timeout: 0.1,
                                                                      cancellation: nil, operations: beforeConnect))
        try check(beforeConnectFailure.code == .timedOut && beforeConnect.connectCalls == 0 && beforeConnect.closed.count == 1,
                  "A deadline expiring during socket setup should prevent the connect call")

        let delayedConnection = TCPSocketFixture([TCPSocketPlan(connectErrno: nil, connectDelay: 0.2)])
        let delayedFailure = try failure(TCPProbe.connectOutcome(addresses: addresses, timeout: 0.1,
                                                                 cancellation: nil, operations: delayedConnection))
        try check(delayedFailure.code == .timedOut && delayedConnection.socketCalls.count == 1 && delayedConnection.closed.count == 1,
                  "A connect result observed after the deadline must not grant a successful result or another address budget")

        let noBudget = TCPSocketFixture([TCPSocketPlan()])
        let noBudgetFailure = try failure(TCPProbe.connectOutcome(addresses: [ipv4], timeout: 0, cancellation: nil, operations: noBudget))
        try check(noBudgetFailure.code == .timedOut && noBudget.socketCalls.isEmpty,
                  "A zero timeout should not be silently extended or allocate sockets")

        let resolvedLate = TCPSocketFixture([TCPSocketPlan()])
        var resolutionBudget: TimeInterval = 0
        let resolutionFailure = try failure(TCPProbe.probeOutcome(host: "fixture.invalid", port: 443, timeout: 0.1,
                                                                  cancellation: nil, operations: resolvedLate,
                                                                  resolver: { _, _, remaining, _ in
                                                                      resolutionBudget = remaining
                                                                      resolvedLate.advance(0.1)
                                                                      return addresses
                                                                  }))
        try check(resolutionBudget <= 0.1 && resolutionFailure.code == .timedOut && resolvedLate.socketCalls.isEmpty,
                  "Host resolution and TCP attempts must use one deadline without granting a fresh connect budget")

        let partlyResolved = TCPSocketFixture([TCPSocketPlan(events: [.timeout])])
        let sharedBudgetFailure = try failure(TCPProbe.probeOutcome(host: "fixture.invalid", port: 443, timeout: 0.1,
                                                                    cancellation: nil, operations: partlyResolved,
                                                                    resolver: { _, _, _, _ in
                                                                        partlyResolved.advance(0.08)
                                                                        return addresses
                                                                    }))
        try check(sharedBudgetFailure.code == .timedOut && partlyResolved.clock <= 100.102 && partlyResolved.socketCalls.count == 1,
                  "Resolution time should be deducted from the connection deadline across every address")

        let dnsFixture = TCPSocketFixture([])
        let dnsFailure = try failure(TCPProbe.probeOutcome(host: "fixture.invalid", port: 443, timeout: 1,
                                                         cancellation: nil, operations: dnsFixture,
                                                         resolver: { _, _, _, _ in throw SocketAddressResolutionError.service(-65538) }))
        try check(dnsFailure.code == .resolution && dnsFailure.resolutionErrorCode == -65538 && dnsFixture.socketCalls.isEmpty,
                  "DNS-SD failures should preserve the resolver code separately from POSIX errno")

        let encoded = try JSONEncoder().encode(mixedResult.failure!)
        let decoded = try JSONDecoder().decode(TCPProbeFailure.self, from: encoded)
        try check(decoded == mixedResult.failure, "TCP failure evidence should survive Codable round trips")
        let legacy = Data(#"{"code":"refused","stage":"connect","message":"Connection refused","errno":61}"#.utf8)
        let legacyFailure = try JSONDecoder().decode(TCPProbeFailure.self, from: legacy)
        try check(legacyFailure.attempts.isEmpty && legacyFailure.soError == nil,
                  "Previously stored TCP failures should decode with absent evidence fields")
    }

    private static func failure(_ outcome: TCPConnectOutcome) throws -> TCPProbeFailure {
        guard case .failed(let failure) = outcome else { throw CheckFailure(description: "Expected a TCP fixture failure") }
        return failure
    }

    private static func fixtureAddress(_ address: String, family: Int32) throws -> ResolvedSocketAddress {
        if family == AF_INET {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            let converted = address.withCString { inet_pton(AF_INET, $0, &value.sin_addr) }
            try check(converted == 1, "TCP fixture IPv4 address should be valid")
            let result = withUnsafePointer(to: &value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { ResolvedSocketAddress.copy(from: $0, port: 443) }
            }
            guard let result else { throw CheckFailure(description: "Unable to construct TCP IPv4 fixture") }
            return result
        }
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        let converted = address.withCString { inet_pton(AF_INET6, $0, &value.sin6_addr) }
        try check(converted == 1, "TCP fixture IPv6 address should be valid")
        let result = withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { ResolvedSocketAddress.copy(from: $0, port: 443) }
        }
        guard let result else { throw CheckFailure(description: "Unable to construct TCP IPv6 fixture") }
        return result
    }
}
