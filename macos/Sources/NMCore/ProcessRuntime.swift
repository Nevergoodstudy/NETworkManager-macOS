import Darwin
import Foundation

public struct ProcessJobEvent: Codable, Hashable, Sendable {
    public let state: ProcessJobState
    public let elapsed: TimeInterval
}

/// Bounded, non-localized evidence. Captured command output is stored separately.
public struct ProcessExecutionEvidence: Codable, Hashable, Sendable {
    public let jobID: UUID
    public let operation: ProcessJobOperation
    public let state: ProcessJobState
    public let events: [ProcessJobEvent]
    public let exitStatus: Int32?
    public let terminationSignal: Int32?
    public let launchErrno: Int32?
    public let failureCode: CommandFailureCode?
    public let stdoutBytesObserved: Int
    public let stderrBytesObserved: Int
    public let stdoutBytesRetained: Int
    public let stderrBytesRetained: Int
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let forcedTermination: Bool
    public let cleanupCompleted: Bool
    public let cleanupErrors: [String]
}

private struct OutputCapture {
    var bytes = Data()
    var observed = 0
    let limit: Int
    var truncated: Bool { observed > bytes.count || String(decoding: bytes, as: UTF8.self).utf8.count > limit }

    mutating func append(_ buffer: [UInt8], count: Int) {
        observed += count
        bytes.append(contentsOf: buffer.prefix(min(count, max(0, limit - bytes.count))))
    }

    // Decode invalid bytes with replacement, then cap the presentation on a
    // UTF-8 scalar boundary too. Raw retained/observed counts remain explicit.
    var text: String {
        let decoded = String(decoding: bytes, as: UTF8.self)
        var capped = Data(decoded.utf8.prefix(limit))
        for _ in 0...3 {
            if let value = String(data: capped, encoding: .utf8) { return value }
            if !capped.isEmpty { capped.removeLast() }
        }
        return ""
    }
}

/// One owner performs launch, drain, signals and reap. Cancellation only sets a
/// flag. The unreaped leader reserves the PGID until all group signals finish.
/// Descendants that create a different session/group are outside this ownership.
enum ProcessRuntime {
    private static let slots = DispatchSemaphore(value: 4)

    static func run(_ path: String, _ arguments: [String], job: ProcessJobSpec,
                    environment: [String: String]?, taskCancellation: DiagnosticCancellation? = nil) -> CommandResult {
        let started = job.createdUptime
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func isCancelled() -> Bool { job.cancellation?.isCancelled == true || taskCancellation?.isCancelled == true }
        var events = [ProcessJobEvent(state: .queued, elapsed: 0)]
        var out = OutputCapture(limit: job.maximumOutputBytesPerStream)
        var err = OutputCapture(limit: job.maximumOutputBytesPerStream)
        var cleanupErrors: [String] = []
        var forced = false
        var exitStatus: Int32?
        var terminationSignal: Int32?

        func finish(_ state: ProcessJobState, failure: CommandFailureCode? = nil,
                    launchErrno: Int32? = nil, message: String = "", cleanup: Bool = true) -> CommandResult {
            events.append(ProcessJobEvent(state: state, elapsed: max(0, now() - started)))
            let evidence = ProcessExecutionEvidence(jobID: job.id, operation: job.operation, state: state,
                events: events, exitStatus: exitStatus, terminationSignal: terminationSignal, launchErrno: launchErrno,
                failureCode: failure, stdoutBytesObserved: out.observed, stderrBytesObserved: err.observed,
                stdoutBytesRetained: out.bytes.count, stderrBytesRetained: err.bytes.count,
                stdoutTruncated: out.truncated, stderrTruncated: err.truncated, forcedTermination: forced,
                cleanupCompleted: cleanup, cleanupErrors: cleanupErrors)
            return CommandResult(status: exitStatus ?? -1, stdout: out.text, stderr: message.isEmpty ? err.text : message,
                timedOut: state == .timedOut, cancelled: state == .cancelled, failureCode: failure,
                stdoutBytesObserved: out.observed, stderrBytesObserved: err.observed,
                stdoutTruncated: out.truncated, stderrTruncated: err.truncated,
                forcedTermination: forced, cleanupCompleted: cleanup, jobID: job.id, jobState: state,
                processEvidence: evidence)
        }
        func launchFailure(_ code: Int32) -> CommandResult {
            let reason: CommandFailureCode = code == ENOENT ? .missingExecutable :
                ((code == EACCES || code == EPERM) ? .permissionDenied : .launch)
            return finish(.failed, failure: reason, launchErrno: code, message: String(cString: strerror(code)))
        }
        if isCancelled() { return finish(.cancelled) }
        if now() >= job.monotonicDeadline { return finish(.timedOut) }
        // No unbounded wait queue is added by this adapter. Existing MCP slots
        // are a separate service budget; this cap is shared by GUI and sync use.
        guard slots.wait(timeout: .now()) == .success else {
            return finish(.failed, failure: .busy, message: "Four command jobs are already running.")
        }
        var releaseSlot = true
        defer { if releaseSlot { slots.signal() } }
        guard !path.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }) else { return launchFailure(EINVAL) }
        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { _, new in new }
        guard mergedEnvironment.allSatisfy({ !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            return launchFailure(EINVAL)
        }

        var descriptors: [Int32] = []
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        func ownedDescriptor(_ original: Int32) throws -> Int32 {
            guard original >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let fd = fcntl(original, F_DUPFD_CLOEXEC, 3)
            let code = errno
            Darwin.close(original)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            descriptors.append(fd)
            return fd
        }
        func makePipe() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let first: Int32
            do { first = try ownedDescriptor(pair[0]) }
            catch { Darwin.close(pair[1]); throw error }
            return (first, try ownedDescriptor(pair[1]))
        }
        func closeOwned(_ fd: Int32) {
            if let index = descriptors.firstIndex(of: fd) { Darwin.close(fd); descriptors[index] = -1 }
        }
        let output: (Int32, Int32)
        let errorOutput: (Int32, Int32)
        let input: Int32
        do {
            output = try makePipe()
            errorOutput = try makePipe()
            input = try ownedDescriptor(open("/dev/null", O_RDONLY | O_CLOEXEC))
            for fd in [output.0, errorOutput.0] {
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } catch { return launchFailure(Int32((error as NSError).code)) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { return launchFailure(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { return launchFailure(code) }
        defer { posix_spawnattr_destroy(&attributes) }
        for (fd, target) in [(input, STDIN_FILENO), (output.1, STDOUT_FILENO), (errorOutput.1, STDERR_FILENO)] {
            code = posix_spawn_file_actions_adddup2(&actions, fd, target)
            guard code == 0 else { return launchFailure(code) }
        }
        var emptyMask = sigset_t()
        var defaultSignals = sigset_t()
        sigemptyset(&emptyMask)
        sigfillset(&defaultSignals)
        for result in [posix_spawnattr_setpgroup(&attributes, 0),
                       posix_spawnattr_setsigmask(&attributes, &emptyMask),
                       posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
                       posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))] {
            guard result == 0 else { return launchFailure(result) }
        }
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        var envp = mergedEnvironment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { return launchFailure(ENOMEM) }
        if isCancelled() { return finish(.cancelled) }
        if now() >= job.monotonicDeadline { return finish(.timedOut) }
        var pid: pid_t = 0
        code = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard code == 0 else { return launchFailure(code) }
        closeOwned(output.1); closeOwned(errorOutput.1); closeOwned(input)
        events.append(ProcessJobEvent(state: .running, elapsed: max(0, now() - started)))

        var terminal: ProcessJobState?
        var leaderExited = false
        var ownsLeader = true
        var stdoutEOF = false
        var stderrEOF = false
        var stopStarted: TimeInterval?
        var killAt: TimeInterval?
        var cleanupDeadline: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func signalGroup(_ signal: Int32) {
            guard ownsLeader else { return }
            // Signal errors can race with the last member exiting. Final group,
            // pipe and reap checks below decide whether cleanup failed.
            _ = kill(-pid, signal)
        }
        func drain(_ fd: Int32, capture: inout OutputCapture, eof: inout Bool) {
            guard !eof else { return }
            // Return to the lifecycle loop even for a continuous writer.
            for _ in 0..<16 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { capture.append(buffer, count: count); continue }
                if count == 0 { eof = true; return }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                cleanupErrors.append("read errno=\(errno)")
                eof = true
                return
            }
        }
        while true {
            var info = siginfo_t()
            let observation = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if observation == 0 && info.si_pid == pid {
                if !leaderExited {
                    leaderExited = true
                    if info.si_code == CLD_EXITED { exitStatus = info.si_status }
                    else { terminationSignal = info.si_status; exitStatus = 128 + info.si_status }
                    // An observed exit wins over cancellation arriving later.
                    if terminal == nil { terminal = exitStatus == 0 ? .succeeded : .failed }
                }
            } else if observation != 0 && errno != EINTR {
                let error = errno
                let message = "waitid errno=\(error)"
                if !cleanupErrors.contains(message) { cleanupErrors.append(message) }
                terminal = terminal ?? .failed
                if error == ECHILD { ownsLeader = false; break }
            }
            if terminal == nil {
                if isCancelled() { terminal = .cancelled }
                else if now() >= job.monotonicDeadline { terminal = .timedOut }
            }
            drain(output.0, capture: &out, eof: &stdoutEOF)
            drain(errorOutput.0, capture: &err, eof: &stderrEOF)
            if terminal != nil {
                let live = liveGroupMembers(pid)
                if live == nil && !cleanupErrors.contains("group membership unavailable") { cleanupErrors.append("group membership unavailable") }
                if stopStarted == nil {
                    stopStarted = now()
                    killAt = now() + job.terminationGrace
                    cleanupDeadline = killAt! + 1
                    if live != false { signalGroup(SIGTERM) }
                }
                if leaderExited && live == false && stdoutEOF && stderrEOF { break }
                if now() >= killAt! && !forced && live != false {
                    forced = true
                    signalGroup(SIGKILL)
                }
                if now() >= cleanupDeadline! { break }
            }
            var polls = [pollfd(fd: stdoutEOF ? -1 : output.0, events: Int16(POLLIN | POLLHUP), revents: 0),
                         pollfd(fd: stderrEOF ? -1 : errorOutput.0, events: Int16(POLLIN | POLLHUP), revents: 0)]
            _ = poll(&polls, nfds_t(polls.count), 10)
        }
        let groupStopped = ownsLeader && liveGroupMembers(pid) == false
        if !groupStopped { cleanupErrors.append("owned process group did not finish") }
        if !stdoutEOF || !stderrEOF { cleanupErrors.append("output EOF not reached") }
        var reaped = false
        if ownsLeader {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            reaped = waited == pid
            if !reaped {
                cleanupErrors.append("leader not reaped before cleanup deadline")
                // Transfer only reap ownership. No signals occur after this point.
                releaseSlot = false
                let reapPID = pid
                DispatchQueue.global(qos: .utility).async {
                    defer { slots.signal() }
                    var finalStatus: Int32 = 0
                    while waitpid(reapPID, &finalStatus, 0) < 0 && errno == EINTR {}
                }
            }
        }
        let cleanup = reaped && groupStopped && stdoutEOF && stderrEOF && cleanupErrors.isEmpty
        let state = terminal ?? .failed
        return finish(state == .succeeded && !cleanup ? .failed : state, cleanup: cleanup)
    }

    /// The leader is still unreaped while this snapshot is read, reserving PGID.
    private static func liveGroupMembers(_ pgid: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        for padding in [16, 64, 256] {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            if size == 0 { return false }
            let count = size / MemoryLayout<kinfo_proc>.stride + padding
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
            size = processes.count * MemoryLayout<kinfo_proc>.stride
            let result = processes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { Int32($0.kp_proc.p_stat) != SZOMB }
        }
        return nil
    }
}
