import Darwin
import Foundation

/// A network deadline shared by resolution, ICMP and system fallback.
struct PingDeadline: Sendable {
    let end: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant

    init(timeout: TimeInterval, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.end = now().advanced(by: .seconds(timeout))
        self.now = now
    }

    private init(end: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.end = end
        self.now = now
    }

    var remaining: TimeInterval { max(0, Self.seconds(now().duration(to: end))) }

    func limited(to seconds: TimeInterval) -> PingDeadline {
        PingDeadline(end: min(end, now().advanced(by: .seconds(max(0, seconds)))), now: now)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Phase boundaries keep deadline/cancellation tests independent of remote hosts.
struct PingOperations: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant = { .now }
    var resolve: @Sendable (String, TimeInterval, DiagnosticCancellation) throws -> ResolvedTarget
    var native: @Sendable (ResolvedTarget, PingDeadline, DiagnosticCancellation) throws -> ICMPReply
    var fallback: @Sendable (ResolvedTarget, UInt16, PingDeadline, DiagnosticCancellation) -> ICMPReply

    static let live = PingOperations(
        resolve: { try ResolvedTarget.resolve($0, timeout: $1, cancellation: $2) },
        native: { target, deadline, cancellation in
            let pinger = try ICMPPinger(target: target, timeout: max(0.001, deadline.remaining), cancellation: cancellation)
            return pinger.ping(allowSystemFallback: false, deadline: deadline)
        },
        fallback: { SystemPing.run(target: $0, ttl: 64, sequence: $1, deadline: $2, cancellation: $3) }
    )
}

extension Ping {
    // Bound Duration conversion as well as socket/process wait arithmetic.
    static func validTimeout(_ timeout: TimeInterval) -> Bool {
        timeout.isFinite && timeout > 0 && timeout <= 86_400
    }

    static func reply(_ outcome: ICMPOutcome, sequence: UInt16 = 0) -> ICMPReply {
        ICMPReply(sequence: Int(sequence), outcome: outcome, rtt: nil, ttl: nil, source: nil)
    }

    static func once(host: String, timeout: TimeInterval, cancellation: DiagnosticCancellation?,
                     operations: PingOperations) async -> ICMPReply {
        guard validTimeout(timeout) else { return reply(.error(POSIXError(.EINVAL).localizedDescription)) }
        // Include queueing and resolution in the same monotonic budget.
        let deadline = PingDeadline(timeout: timeout, now: operations.now)
        let token = cancellation ?? DiagnosticCancellation()
        return await withTaskCancellationHandler {
            await runBlockingDiagnostic {
                func interrupted(sequence: UInt16 = 0) -> ICMPReply? {
                    if token.isCancelled { return reply(.error(t("Diagnostic cancelled")), sequence: sequence) }
                    if deadline.remaining <= 0 { return reply(.timeout, sequence: sequence) }
                    return nil
                }
                if let result = interrupted() { return result }
                let target: ResolvedTarget
                do {
                    target = try operations.resolve(host, deadline.remaining, token)
                } catch {
                    if let result = interrupted() { return result }
                    if let reason = error as? SocketAddressResolutionError {
                        switch reason {
                        case .timedOut: return reply(.timeout)
                        case .cancelled: return reply(.error(t("Diagnostic cancelled")))
                        default: break
                        }
                    }
                    return reply(.error(error.localizedDescription))
                }
                if let result = interrupted() { return result }
                let native: ICMPReply
                do {
                    native = try operations.native(target, deadline.limited(to: deadline.remaining / 2), token)
                } catch {
                    native = reply(.error(error.localizedDescription))
                }
                let sequence = UInt16(truncatingIfNeeded: native.sequence)
                if let result = interrupted(sequence: sequence) { return result }
                switch native.outcome {
                case .timeout, .error:
                    let fallback = operations.fallback(target, sequence, deadline, token)
                    return interrupted(sequence: sequence) ?? fallback
                default: return native
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}

enum SystemPing {
    static func arguments(target: ResolvedTarget, ttl: Int, timeout: TimeInterval) -> [String] {
        let hopLimit = String(max(1, min(255, ttl)))
        if target.family == AF_INET6 {
            // Darwin ping6 -W is a node-information flag, not a wait timeout.
            return ["-n", "-c", "1", "-h", hopLimit, target.address]
        }
        let milliseconds = Int32(max(1, min(Double(Int32.max), ceil(timeout * 1_000))))
        return ["-n", "-c", "1", "-W", String(milliseconds), "-m", hopLimit, target.address]
    }

    static func run(target: ResolvedTarget, ttl: Int, sequence: UInt16, deadline: PingDeadline,
                    cancellation: DiagnosticCancellation?) -> ICMPReply {
        if cancellation?.isCancelled == true { return Ping.reply(.error(t("Diagnostic cancelled")), sequence: sequence) }
        guard deadline.remaining > 0 else { return Ping.reply(.timeout, sequence: sequence) }
        guard let path = Shell.which(target.family == AF_INET6 ? "ping6" : "ping") else {
            return Ping.reply(.error(POSIXError(.ENOENT).localizedDescription), sequence: sequence)
        }
        let arguments = arguments(target: target, ttl: ttl, timeout: deadline.remaining)
        // Teardown is bounded by the common process runtime, separately from
        // the network budget. No hostname is passed to a child for re-resolution.
        let job = ProcessJobSpec(operation: .command, targetScope: target.address,
                                 deadline: Date().addingTimeInterval(deadline.remaining),
                                 maximumOutputBytesPerStream: 16_384, terminationGrace: 0.05,
                                 cancellation: cancellation)
        let result = ProcessRuntime.run(path, arguments, job: job, environment: ["LC_ALL": "C"])
        if result.cancelled || cancellation?.isCancelled == true {
            return Ping.reply(.error(t("Diagnostic cancelled")), sequence: sequence)
        }
        if result.timedOut || deadline.remaining <= 0 { return Ping.reply(.timeout, sequence: sequence) }
        if result.failureCode != nil || !result.cleanupCompleted {
            return Ping.reply(.error(result.output.isEmpty ? t("Error") : result.output), sequence: sequence)
        }
        return ICMPPinger.parseSystemPing(result.output, fallbackAddress: target.address, sequence: sequence)
            ?? Ping.reply(.timeout, sequence: sequence)
    }
}
