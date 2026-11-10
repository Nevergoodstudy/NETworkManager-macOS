import Foundation
import Darwin

/// Cancellation signal shared by a diagnostic task and its blocking protocol client.
public final class DiagnosticCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func waitForReadiness(fd: Int32, events: Int16, timeout: TimeInterval) -> Int16? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            if isCancelled { return nil }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(50, ceil(remaining * 1_000))))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 { return descriptor.revents }
            if result < 0 && errno != EINTR { return descriptor.revents }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }
}

func waitForSocketReadiness(fd: Int32, events: Int16, timeout: TimeInterval, cancellation: DiagnosticCancellation?) -> Int16? {
    (cancellation ?? DiagnosticCancellation()).waitForReadiness(fd: fd, events: events, timeout: timeout)
}

/// Socket polling must not occupy Swift's cooperative workers: callers need
/// those workers to receive more requests and propagate cancellation.
func runBlockingDiagnostic<Result: Sendable>(_ operation: @escaping @Sendable () -> Result) async -> Result {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: operation())
        }
    }
}
