import Darwin
import Foundation
@testable import NMCore

private final class PingFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: TimeInterval = 0
    private var phases: [String] = []
    private var budgets: [TimeInterval] = []
    private var addresses: [String] = []

    func now() -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return origin.advanced(by: .seconds(elapsed))
    }
    func advance(_ seconds: TimeInterval) { lock.lock(); elapsed += seconds; lock.unlock() }
    func record(_ phase: String, _ budget: TimeInterval, address: String) {
        lock.lock(); defer { lock.unlock() }
        phases.append(phase); budgets.append(budget); addresses.append(address)
    }
    var snapshot: (phases: [String], budgets: [TimeInterval], addresses: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (phases, budgets, addresses)
    }
}

private func pingOperations(_ state: PingFixtureState, target: ResolvedTarget,
                            resolve: (@Sendable (DiagnosticCancellation) throws -> Void)? = nil,
                            native: (@Sendable (DiagnosticCancellation) throws -> ICMPReply)? = nil,
                            fallback: (@Sendable (DiagnosticCancellation) -> ICMPReply)? = nil) -> PingOperations {
    PingOperations(now: { state.now() }, resolve: { host, budget, token in
        state.record("resolve", budget, address: host)
        try resolve?(token)
        return target
    }, native: { target, deadline, token in
        state.record("native", deadline.remaining, address: target.address)
        return try native?(token) ?? Ping.reply(.timeout, sequence: 7)
    }, fallback: { target, sequence, deadline, token in
        state.record("fallback", deadline.remaining, address: target.address)
        return fallback?(token) ?? Ping.reply(.success, sequence: sequence)
    })
}

enum PingChecks {
    static func run() async throws {
        let target = try ResolvedTarget.resolve("127.0.0.1")
        let ipv6 = try ResolvedTarget.resolve("::1")
        for invalid in [0, -1, .nan, .infinity, -.infinity, 86_401, Double.greatestFiniteMagnitude] {
            let state = PingFixtureState()
            let result = await Ping.once(host: "fixture.test", timeout: invalid, cancellation: nil,
                                         operations: pingOperations(state, target: target))
            try check(isError(result) && state.snapshot.phases.isEmpty, "Invalid Ping budgets must fail before work")
            do {
                _ = try ICMPPinger(target: target, timeout: invalid)
                throw CheckFailure(description: "Pinger accepted an invalid budget")
            } catch is POSIXError {}
        }
        try check(Ping.validTimeout(86_400) && Ping.validTimeout(0.001), "Supported Ping timeout boundaries")

        let state = PingFixtureState()
        let result = await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
            operations: pingOperations(state, target: target, resolve: { _ in state.advance(0.4) },
                                       native: { _ in state.advance(0.3); return Ping.reply(.timeout, sequence: 7) }))
        let trace = state.snapshot
        try check(result.outcome == .success && result.sequence == 7, "Fallback preserves the caller sequence")
        try check(trace.phases == ["resolve", "native", "fallback"]
                  && trace.addresses == ["fixture.test", "127.0.0.1", "127.0.0.1"],
                  "Ping resolves once and reuses the numeric endpoint")
        try check(abs(trace.budgets[0] - 1) < 0.0001 && abs(trace.budgets[1] - 0.3) < 0.0001
                  && abs(trace.budgets[2] - 0.3) < 0.0001, "All phases consume one shared Ping deadline")

        let success = PingFixtureState()
        let successful = await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
            operations: pingOperations(success, target: target, native: { _ in Ping.reply(.success) }))
        try check(successful.outcome == .success && success.snapshot.phases == ["resolve", "native"],
                  "Native success must not launch a child")
        let setup = PingFixtureState()
        let recovered = await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
            operations: pingOperations(setup, target: target, native: { _ in throw POSIXError(.EPERM) }))
        try check(recovered.outcome == .success && setup.snapshot.phases.count == 3,
                  "Native socket setup failure may use the remaining fallback budget")

        for reason in [SocketAddressResolutionError.timedOut, .cancelled, .noAddresses] {
            let failed = PingFixtureState()
            let reply = await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
                operations: pingOperations(failed, target: target, resolve: { _ in throw reason }))
            try check(failed.snapshot.phases == ["resolve"], "Resolution failures cannot start a probe")
            try check(reason == .timedOut ? reply.outcome == .timeout : isError(reply),
                      "Resolution timeout and cancellation retain their outcomes")
        }
        let preCancelled = PingFixtureState()
        let token = DiagnosticCancellation(); token.cancel()
        let stopped = await Ping.once(host: "fixture.test", timeout: 1, cancellation: token,
                                     operations: pingOperations(preCancelled, target: target))
        try check(isCancelled(stopped) && preCancelled.snapshot.phases.isEmpty, "Pre-cancelled Ping does no work")

        for phase in 0...2 {
            for cancel in [false, true] {
                let fixture = PingFixtureState()
                let action: @Sendable (Int, DiagnosticCancellation) -> Void = { index, token in
                    if phase == index {
                        if cancel { token.cancel() } else { fixture.advance(2) }
                    }
                }
                let reply = await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
                    operations: pingOperations(fixture, target: target, resolve: { action(0, $0) },
                        native: { action(1, $0); return Ping.reply(.timeout) },
                        fallback: { action(2, $0); return Ping.reply(.success) }))
                try check(cancel ? isCancelled(reply) : reply.outcome == .timeout,
                          "Cancellation and expiry override even a late phase success")
                try check(fixture.snapshot.phases.count == phase + 1, "No phase starts after cancellation or expiry")
            }
        }

        let taskState = PingFixtureState()
        let preTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Ping.once(host: "fixture.test", timeout: 1, cancellation: nil,
                                   operations: pingOperations(taskState, target: target))
        }
        let preTaskResult = await preTask.value
        try check(isCancelled(preTaskResult) && taskState.snapshot.phases.isEmpty,
                  "An already-cancelled Swift task propagates cancellation without a supplied token")
        for phase in 0...2 {
            let fixture = PingFixtureState()
            let block: @Sendable (Int, DiagnosticCancellation) -> Void = { index, token in
                if index == phase {
                    let end = ProcessInfo.processInfo.systemUptime + 2
                    while !token.isCancelled && ProcessInfo.processInfo.systemUptime < end {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                }
            }
            let task = Task {
                await Ping.once(host: "fixture.test", timeout: 3, cancellation: nil,
                    operations: pingOperations(fixture, target: target, resolve: { block(0, $0) },
                        native: { block(1, $0); return Ping.reply(.timeout) },
                        fallback: { block(2, $0); return Ping.reply(.success) }))
            }
            let waitEnd = ContinuousClock.now.advanced(by: .seconds(2))
            while fixture.snapshot.phases.count < phase + 1 && ContinuousClock.now < waitEnd {
                try await Task.sleep(for: .milliseconds(2))
            }
            let entered = fixture.snapshot.phases.count == phase + 1
            let started = ContinuousClock.now
            task.cancel()
            let reply = await task.value
            try check(entered && isCancelled(reply) && elapsed(since: started) < 0.5,
                      "Swift task cancellation interrupts every blocking phase")
            try check(fixture.snapshot.phases.count == phase + 1, "Task cancellation prevents later phases")
        }

        try receiveChecks()
        try parserChecks(target: target, ipv6: ipv6)
        for address in ["127.0.0.1", "::1"] {
            let reply = await Ping.once(host: address, timeout: 1)
            try check(reply.outcome == .success && reply.source == address, "Ping loopback must succeed for both families")
        }
        for target in [target, ipv6] {
            let reply = SystemPing.run(target: target, ttl: 64, sequence: 42, deadline: PingDeadline(timeout: 1), cancellation: nil)
            try check(reply.outcome == .success && reply.source == target.address && reply.sequence == 42,
                      "Direct system fallback must preserve IPv4/IPv6 address and requested sequence")
        }
    }

    private static func receiveChecks() throws {
        for family in [AF_INET, AF_INET6] {
            var sockets: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
            defer { close(sockets[0]); close(sockets[1]) }
            let started = ContinuousClock.now
            let silent = ICMPPinger.receiveReply(fd: sockets[0], family: family, sequence: 42, start: started,
                                                 deadline: PingDeadline(timeout: 0.12), cancellation: nil)
            let duration = elapsed(since: started)
            try check(silent.outcome == .timeout && duration >= 0.09 && duration < 0.5,
                      "Silent receive is bounded even without a cancellation token")
            let writerFD = sockets[1]
            let readerFD = sockets[0]
            let finished = DispatchSemaphore(value: 0)
            let stop = DiagnosticCancellation()
            let packet: [UInt8] = [family == AF_INET ? 0 : 129, 0, 0, 0, 0, 1, 0, 43]
            DispatchQueue.global().async {
                defer { finished.signal() }
                let end = ProcessInfo.processInfo.systemUptime + 1
                while !stop.isCancelled && ProcessInfo.processInfo.systemUptime < end {
                    _ = packet.withUnsafeBytes { send(writerFD, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            let floodStart = ContinuousClock.now
            let flood = ICMPPinger.receiveReply(fd: readerFD, family: family, sequence: 42, start: floodStart,
                                                deadline: PingDeadline(timeout: 0.12), cancellation: nil)
            stop.cancel()
            let writerStopped = finished.wait(timeout: .now() + 1) == .success
            try check(writerStopped && flood.outcome == .timeout && elapsed(since: floodStart) < 0.5,
                      "Unrelated echo replies cannot renew the receive deadline")
            var bytes = [UInt8](repeating: 0, count: 100)
            while recv(readerFD, &bytes, bytes.count, MSG_DONTWAIT) > 0 {}
            var matching = packet; matching[7] = 42
            _ = matching.withUnsafeBytes { send(writerFD, $0.baseAddress, $0.count, 0) }
            let matched = ICMPPinger.receiveReply(fd: readerFD, family: family, sequence: 42, start: .now,
                                                  deadline: PingDeadline(timeout: 0.2), cancellation: nil)
            try check(matched.outcome == .success && matched.sequence == 42, "Matching echo reply is accepted")
            let cancel = DiagnosticCancellation()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { cancel.cancel() }
            let cancelStart = ContinuousClock.now
            let cancelled = ICMPPinger.receiveReply(fd: readerFD, family: family, sequence: 42, start: cancelStart,
                                                    deadline: PingDeadline(timeout: 2), cancellation: cancel)
            try check(isCancelled(cancelled) && elapsed(since: cancelStart) < 0.5, "Silent native receive responds to cancellation")
        }
    }

    private static func parserChecks(target: ResolvedTarget, ipv6: ResolvedTarget) throws {
        try check(SystemPing.arguments(target: target, ttl: 999, timeout: 0.12)
                  == ["-n", "-c", "1", "-W", "120", "-m", "255", "127.0.0.1"], "IPv4 fallback uses millisecond wait and clamped TTL")
        try check(SystemPing.arguments(target: ipv6, ttl: 0, timeout: 0.12)
                  == ["-n", "-c", "1", "-h", "1", "::1"], "IPv6 fallback uses hoplimit rather than IPv4 flags")
        let reply = ICMPPinger.parseSystemPing("16 bytes from ::1, icmp_seq=0 hlim=64 time=0.076 ms",
                                               fallbackAddress: "::1", sequence: 42)
        try check(reply?.source == "::1" && reply?.ttl == 64 && reply?.sequence == 42
                  && abs((reply?.rtt ?? 1) - 0.000076) < 0.000001, "IPv6 fallback parser preserves address, hop limit and sequence")
        let reply4 = ICMPPinger.parseSystemPing("64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.100 ms",
                                                fallbackAddress: "127.0.0.1", sequence: 8)
        try check(reply4?.source == "127.0.0.1" && reply4?.ttl == 64 && reply4?.sequence == 8, "IPv4 fallback parser remains compatible")
        try check(ICMPPinger.parseSystemPing("Request timeout for icmp_seq 0", fallbackAddress: "::1", sequence: 42) == nil,
                  "Timeout output must not fabricate success")
        var ancillary = [UInt8](repeating: 0, count: MemoryLayout<cmsghdr>.size + 4)
        let ttl = ancillary.withUnsafeMutableBytes { bytes -> Int? in
            let header = cmsghdr(cmsg_len: socklen_t(MemoryLayout<cmsghdr>.size), cmsg_level: IPPROTO_IP, cmsg_type: IP_RECVTTL)
            bytes.storeBytes(of: header, as: cmsghdr.self)
            var message = msghdr(); message.msg_control = bytes.baseAddress; message.msg_controllen = socklen_t(bytes.count)
            return ICMPPinger.ttl(from: message)
        }
        try check(ttl == nil, "A short ancillary TTL payload cannot be read beyond its declared length")
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        PingDeadline.seconds(start.duration(to: .now))
    }
    private static func isError(_ reply: ICMPReply) -> Bool {
        if case .error = reply.outcome { return true }; return false
    }
    private static func isCancelled(_ reply: ICMPReply) -> Bool {
        reply.outcome == .error(t("Diagnostic cancelled"))
    }
}
