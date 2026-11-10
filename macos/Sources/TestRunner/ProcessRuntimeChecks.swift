import Foundation
import Darwin
@testable import NMCore

/// Uses local shell fixtures and FIFO handshakes; no network or installed tools
/// beyond the system shell participate in the process-runtime checks.
enum ProcessRuntimeChecks {
    static func run() async throws {
        let fixture = try ProcessRuntimeFixture()
        defer { fixture.remove() }

        try await checkExitResults(fixture)
        try await checkParallelOutput()
        try await checkByteBoundaries()
        try await checkRuntimeSlots(fixture)
        try await checkNoLaunchAfterDeadline(fixture)
        try await checkNoLaunchAfterCancellation(fixture)
        try await checkNoLaunchAfterTaskCancellation(fixture)
        try await checkDeadline(fixture)
        try await checkCancellation(fixture, ignoresTermination: false)
        try await checkCancellation(fixture, ignoresTermination: true)
        try await checkTaskCancellation(fixture)
        try await checkInheritedPipes(fixture)
        try await checkTerminalRaces(fixture)
    }

    private static func checkExitResults(_ fixture: ProcessRuntimeFixture) async throws {
        let successJob = job("successful exit")
        let success = await Shell.run("/bin/sh", ["-c", """
        if IFS= read -r unexpected; then exit 91; fi
        printf 'normal output\n'
        printf 'normal error\n' >&2
        """], job: successJob)
        try check(success.succeeded && success.jobState == .succeeded && success.status == 0,
                  "Process runtime preserves a normal exit and supplies closed stdin")
        try check(success.stdout == "normal output\n" && success.stderr == "normal error\n",
                  "Process runtime captures stdout and stderr separately")
        try check(success.stdoutBytesObserved == 14 && success.stderrBytesObserved == 13,
                  "Process runtime reports exact byte totals for a normal exit")
        try check(!success.stdoutTruncated && !success.stderrTruncated && !success.forcedTermination,
                  "A small successful command has neither truncation nor forced termination")
        try check(success.cleanupCompleted && success.jobID == successJob.id,
                  "Process runtime preserves the job identity and completes normal cleanup")

        let nonzero = await Shell.run("/bin/sh", ["-c", "printf 'exit evidence'; printf 'exit error' >&2; exit 23"],
                                      job: job("nonzero exit"))
        try check(!nonzero.succeeded && nonzero.status == 23 && nonzero.jobState == .failed,
                  "A command's nonzero exit remains distinct from launch failure")
        try check(nonzero.failureCode == nil && nonzero.stdout == "exit evidence" && nonzero.stderr == "exit error",
                  "A nonzero exit retains output without inventing a launch error")
        try check(!nonzero.timedOut && !nonzero.cancelled && nonzero.cleanupCompleted,
                  "A nonzero exit finishes once with completed cleanup")

        let absent = await Shell.run(fixture.path("absent executable"), job: job("missing executable"))
        try check(absent.failureCode == .missingExecutable && absent.jobState == .failed && !absent.succeeded,
                  "An executable confirmed absent by launch is reported as missing")

        let noExecute = fixture.url("existing but not executable.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: noExecute)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noExecute.path)
        let denied = await Shell.run(noExecute.path, job: job("permission denied"))
        try check(denied.failureCode == .permissionDenied && denied.jobState == .failed && !denied.succeeded,
                  "An existing file without execute permission is not classified as a missing dependency")
    }

    private static func checkParallelOutput() async throws {
        let repetitions = 8_192
        let bytesPerChunk = 16
        let cap = 4_096
        let output = await Shell.run("/bin/sh", ["-c", """
        (
            i=0
            while [ "$i" -lt 8192 ]; do
                printf '0123456789abcdef'
                i=$((i + 1))
            done
        ) &
        (
            i=0
            while [ "$i" -lt 8192 ]; do
                printf 'fedcba9876543210'
                i=$((i + 1))
            done
        ) >&2 &
        wait
        """], timeout: 10, maximumOutputBytesPerStream: cap)
        try check(output.succeeded && output.cleanupCompleted,
                  "Independent stdout and stderr writers finish without a pipe-capacity deadlock")
        try check(output.stdoutBytesObserved == repetitions * bytesPerChunk &&
                  output.stderrBytesObserved == repetitions * bytesPerChunk,
                  "Process runtime drains every byte from both parallel writers after reaching the caps")
        try check(output.stdout.utf8.count == cap && output.stderr.utf8.count == cap,
                  "Parallel output retains exactly the configured byte cap per stream")
        try check(output.stdout == String(repeating: "0123456789abcdef", count: cap / bytesPerChunk) &&
                  output.stderr == String(repeating: "fedcba9876543210", count: cap / bytesPerChunk),
                  "Bounded capture preserves each stream's prefix in order")
        try check(output.stdoutTruncated && output.stderrTruncated,
                  "Both oversized output streams report truncation")

        let discarded = await Shell.run("/bin/sh", ["-c", "printf 'discard-out'; printf 'discard-err' >&2"],
                                        timeout: 3, maximumOutputBytesPerStream: 0)
        try check(discarded.succeeded && discarded.stdout.isEmpty && discarded.stderr.isEmpty,
                  "A zero-byte cap retains no output and still lets the command complete")
        try check(discarded.stdoutBytesObserved == 11 && discarded.stderrBytesObserved == 11 &&
                  discarded.stdoutTruncated && discarded.stderrTruncated && discarded.cleanupCompleted,
                  "A zero-byte cap continues draining and records exact discarded byte totals")
    }

    private static func checkByteBoundaries() async throws {
        let unicode = await Shell.run("/bin/sh", ["-c", "printf '你好🙂'"], timeout: 3,
                                      maximumOutputBytesPerStream: 7)
        try check(unicode.succeeded && unicode.stdout.utf8.count <= 7 && unicode.stdoutBytesObserved == 10,
                  "A retained prefix ending within a Unicode scalar respects its presentation byte cap")
        let invalid = await Shell.run("/bin/sh", ["-c", "printf '\\377\\377'"], timeout: 3,
                                      maximumOutputBytesPerStream: 2)
        try check(invalid.succeeded && invalid.stdout.utf8.count <= 2 && invalid.stdoutBytesObserved == 2 && invalid.stdoutTruncated,
                  "Replacement characters for invalid UTF-8 cannot expand beyond the byte cap")
        let deadline = Date().addingTimeInterval(0.2)
        let noisy = await Shell.run("/bin/sh", ["-c", "while :; do printf 'continuous-output'; done"],
                                    job: job("continuous writer deadline", deadline: deadline))
        try check(noisy.timedOut && noisy.cleanupCompleted && noisy.stdoutTruncated,
                  "A continuously readable stream cannot starve deadline and cleanup checks")
    }

    private static func checkRuntimeSlots(_ fixture: ProcessRuntimeFixture) async throws {
        var executions: [Task<CommandResult, Never>] = []
        var cancellations: [DiagnosticCancellation] = []
        defer { for cancellation in cancellations { cancellation.cancel() } }
        for index in 0..<4 {
            let blocked = try fixture.blocked("runtime slot \(index)")
            let cancellation = DiagnosticCancellation()
            cancellations.append(cancellation)
            let spec = job("runtime slot \(index)", cancellation: cancellation)
            let execution = Task { await Shell.run("/bin/sh", blocked.arguments, job: spec) }
            executions.append(execution)
            _ = try await waitForStartedProcess(blocked, execution: execution)
        }
        let marker = fixture.path("busy job marker")
        let rejected = await Shell.run("/bin/sh", markerArguments(marker), job: job("excess runtime work"))
        try check(rejected.failureCode == .busy && !FileManager.default.fileExists(atPath: marker),
                  "The process-wide four-command budget rejects excess work before launch")
        try check(rejected.processEvidence?.events.map(\.state) == [.queued, .failed],
                  "A rejected job has one terminal event and never enters running")
        for cancellation in cancellations { cancellation.cancel() }
        for execution in executions {
            let result = await execution.value
            try check(result.cancelled && result.cleanupCompleted &&
                      result.processEvidence?.events.map(\.state) == [.queued, .running, .cancelled],
                      "Active slot holders finish once and release their runtime permits after cleanup")
        }
        let resumed = await Shell.run("/usr/bin/true", job: job("runtime slot reused"))
        try check(resumed.succeeded, "Runtime capacity is available again after cancelled commands finish")
    }

    private static func checkNoLaunchAfterDeadline(_ fixture: ProcessRuntimeFixture) async throws {
        let marker = fixture.path("expired launch marker")
        let expired = job("expired before launch", deadline: Date().addingTimeInterval(-1))
        let result = await Shell.run("/bin/sh", markerArguments(marker), job: expired)
        try check(result.timedOut && !result.cancelled && result.jobState == .timedOut && result.jobID == expired.id,
                  "An expired absolute deadline produces a timeout before launch")
        try check(!FileManager.default.fileExists(atPath: marker) && result.stdoutBytesObserved == 0,
                  "An already-expired job cannot execute a marker-writing child")
    }

    private static func checkNoLaunchAfterCancellation(_ fixture: ProcessRuntimeFixture) async throws {
        let marker = fixture.path("pre-cancelled launch marker")
        let cancellation = DiagnosticCancellation()
        cancellation.cancel()
        let spec = job("cancelled before launch", cancellation: cancellation)
        let result = await Shell.run("/bin/sh", markerArguments(marker), job: spec)
        try check(result.cancelled && !result.timedOut && result.jobState == .cancelled && result.jobID == spec.id,
                  "A pre-cancelled diagnostic job produces one cancellation result")
        try check(!FileManager.default.fileExists(atPath: marker),
                  "A pre-cancelled diagnostic job cannot launch a marker-writing child")
    }

    private static func checkNoLaunchAfterTaskCancellation(_ fixture: ProcessRuntimeFixture) async throws {
        let marker = fixture.path("pre-cancelled Task launch marker")
        let gate = ProcessRuntimeLaunchGate()
        let arguments = markerArguments(marker)
        let spec = job("Task cancelled before launch")
        let execution = Task {
            await gate.wait()
            return await Shell.run("/bin/sh", arguments, job: spec)
        }
        execution.cancel()
        await gate.release()
        let result = await execution.value
        try check(result.cancelled && !result.timedOut && result.jobState == .cancelled,
                  "Swift Task cancellation is visible before process launch")
        try check(!FileManager.default.fileExists(atPath: marker),
                  "A Task cancelled behind the launch gate cannot start its child")
    }

    private static func checkDeadline(_ fixture: ProcessRuntimeFixture) async throws {
        let blocked = try fixture.blocked("deadline")
        let spec = job("blocked deadline", deadline: Date().addingTimeInterval(1), terminationGrace: 0.15)
        let execution = Task { await Shell.run("/bin/sh", blocked.arguments, job: spec) }
        let pid = try await waitForStartedProcess(blocked, execution: execution)
        let result = await execution.value
        try check(result.timedOut && !result.cancelled && result.jobState == .timedOut,
                  "An absolute deadline interrupts a child blocked in a FIFO read")
        try check(!result.forcedTermination && result.cleanupCompleted,
                  "A child that handles SIGTERM exits within the graceful deadline cleanup")
        try await waitForExit(pid, "The timed-out direct child has been reaped")
    }

    private static func checkCancellation(_ fixture: ProcessRuntimeFixture, ignoresTermination: Bool) async throws {
        let name = ignoresTermination ? "ignores SIGTERM" : "handles SIGTERM"
        let blocked = try fixture.blocked(name, ignoresTermination: ignoresTermination)
        let cancellation = DiagnosticCancellation()
        let spec = job(name, terminationGrace: 0.1, cancellation: cancellation)
        let execution = Task { await Shell.run("/bin/sh", blocked.arguments, job: spec) }
        let pid = try await waitForStartedProcess(blocked, execution: execution)
        cancellation.cancel()
        let result = await execution.value
        try check(result.cancelled && !result.timedOut && result.jobState == .cancelled && result.jobID == spec.id,
                  "Cancellation interrupts a running child while preserving the cancellation reason")
        try check(result.forcedTermination == ignoresTermination && result.cleanupCompleted,
                  ignoresTermination
                    ? "A child ignoring SIGTERM is killed after the grace interval and cleaned up"
                    : "A child handling SIGTERM is cancelled without forced termination")
        try await waitForExit(pid, "A cancelled direct child has been reaped")
    }

    private static func checkTaskCancellation(_ fixture: ProcessRuntimeFixture) async throws {
        let blocked = try fixture.blocked("running Swift Task cancellation")
        let spec = job("running Swift Task cancellation", terminationGrace: 0.1)
        let execution = Task { await Shell.run("/bin/sh", blocked.arguments, job: spec) }
        let pid = try await waitForStartedProcess(blocked, execution: execution)
        execution.cancel()
        let result = await execution.value
        try check(result.cancelled && !result.timedOut && result.jobState == .cancelled && result.cleanupCompleted,
                  "Cancelling the owning Swift Task cancels and cleans up its running process")
        try await waitForExit(pid, "The Swift Task's cancelled child has been reaped")
    }

    private static func checkInheritedPipes(_ fixture: ProcessRuntimeFixture) async throws {
        let childPID = fixture.path("inherited pipe descendant.pid")
        let readyFIFO = try fixture.fifo("inherited pipe ready.fifo")
        let blockedFIFO = try fixture.fifo("inherited pipe blocked.fifo")
        let script = """
        /bin/sh -c '
            trap "" TERM
            printf "%s\\n" "$$" > "$1"
            printf "ready\\n" > "$2"
            IFS= read -r release < "$3"
        ' runtime-descendant "$1" "$2" "$3" &
        IFS= read -r ready < "$2"
        printf 'leader-finished\n'
        exit 0
        """
        let spec = job("descendant inherits output pipes", terminationGrace: 0.1)
        let started = Date()
        let result = await Shell.run("/bin/sh", ["-c", script, "runtime-leader", childPID, readyFIFO, blockedFIFO], job: spec)
        try check(Date().timeIntervalSince(started) < 3,
                  "An exited leader's pipe-inheriting descendant cannot keep the job waiting indefinitely")
        try check(result.succeeded && result.jobState == .succeeded && result.stdout == "leader-finished\n",
                  "Process-group cleanup preserves an exited leader's successful result and captured output")
        try check(result.cleanupCompleted,
                  "Inherited output pipes reach EOF after the runtime cleans up its owned process group")
        let pid = try await readPID(childPID)
        try await waitForExit(pid, "The owned descendant has exited after its leader finishes")
    }

    private static func checkTerminalRaces(_ fixture: ProcessRuntimeFixture) async throws {
        for iteration in 0..<4 {
            let blocked = try fixture.blocked("terminal race \(iteration)")
            let cancellation = DiagnosticCancellation()
            let deadline = Date().addingTimeInterval(0.4)
            let spec = job("exit, deadline and cancellation race \(iteration)", deadline: deadline,
                           terminationGrace: 0.1, cancellation: cancellation)
            let execution = Task { await Shell.run("/bin/sh", blocked.arguments, job: spec) }
            let pid = try await waitForStartedProcess(blocked, execution: execution)
            try await waitUntil(deadline)
            // Both contenders become observable together with the absolute
            // deadline. Whichever terminal event won must remain the result.
            blocked.release()
            cancellation.cancel()
            let result = await execution.value
            try check(result.jobID == spec.id && result.jobState.isTerminal && result.cleanupCompleted,
                      "An exit/deadline/cancellation race returns one terminal result with cleanup")
            try check(!(result.timedOut && result.cancelled) && result.failureCode == nil,
                      "An exit/deadline/cancellation race cannot report two terminal reasons")
            switch result.jobState {
            case .succeeded:
                try check(result.succeeded && result.status == 0 && !result.timedOut && !result.cancelled,
                          "A race won by normal exit has consistent success metadata")
            case .timedOut:
                try check(result.timedOut && !result.cancelled && !result.succeeded,
                          "A race won by the deadline preserves the timeout reason")
            case .cancelled:
                try check(result.cancelled && !result.timedOut && !result.succeeded,
                          "A race won by cancellation preserves the cancellation reason")
            default:
                throw CheckFailure(description: "An exit/deadline/cancellation race produced an unexpected state: \(result.jobState)")
            }
            try await waitForExit(pid, "A terminal-race child has been reaped")
        }
    }

    private static func job(_ scope: String, deadline: Date = Date().addingTimeInterval(5),
                            terminationGrace: TimeInterval = 0.15,
                            cancellation: DiagnosticCancellation? = nil) -> ProcessJobSpec {
        ProcessJobSpec(operation: .command, targetScope: scope, deadline: deadline,
                       maximumOutputBytesPerStream: 4_096,
                       terminationGrace: terminationGrace, cancellation: cancellation)
    }

    private static func markerArguments(_ marker: String) -> [String] {
        ["-c", "printf 'launched' > \"$1\"", "runtime-marker", marker]
    }

    private static func waitForStartedProcess(_ blocked: ProcessRuntimeBlockedFixture,
                                              execution: Task<CommandResult, Never>) async throws -> pid_t {
        do {
            return try await readPID(blocked.pidPath)
        } catch {
            execution.cancel()
            blocked.release()
            _ = await execution.value
            throw error
        }
    }

    private static func readPID(_ path: String) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure(description: "Process fixture did not acknowledge startup: \(path)")
    }

    private static func waitForExit(_ pid: pid_t, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        } while Date() < deadline
        throw CheckFailure(description: message)
    }

    private static func waitUntil(_ date: Date) async throws {
        while date.timeIntervalSinceNow > 0 {
            let remaining = max(0, date.timeIntervalSinceNow)
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}

private actor ProcessRuntimeLaunchGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ProcessRuntimeBlockedFixture: Sendable {
    let pidPath: String
    let arguments: [String]
    let fifoDescriptor: Int32

    func release() {
        let line: [UInt8] = [114, 101, 108, 101, 97, 115, 101, 10]
        _ = line.withUnsafeBytes { Darwin.write(fifoDescriptor, $0.baseAddress, $0.count) }
    }
}

private final class ProcessRuntimeFixture {
    private let directory: URL
    private var fifoDescriptors: [Int32] = []

    init() throws {
        // Shell metacharacters in these paths must travel only through argv.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NM runtime '\";$() fixtures \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func path(_ name: String) -> String { url(name).path }

    func fifo(_ name: String) throws -> String {
        let fifoPath = path(name)
        guard Darwin.mkfifo(fifoPath, 0o600) == 0 else {
            throw CheckFailure(description: "Could not create process-fixture FIFO (errno \(errno))")
        }
        let descriptor = Darwin.open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CheckFailure(description: "Could not open process-fixture FIFO (errno \(errno))")
        }
        fifoDescriptors.append(descriptor)
        return fifoPath
    }

    func blocked(_ name: String, ignoresTermination: Bool = false) throws -> ProcessRuntimeBlockedFixture {
        let pidPath = path("\(name).pid")
        let blockedFIFO = try fifo("\(name).fifo")
        let descriptor = fifoDescriptors[fifoDescriptors.count - 1]
        let script = ignoresTermination ? """
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        IFS= read -r release < "$2"
        exit 0
        """ : """
        trap 'exit 0' TERM
        printf '%s\n' "$$" > "$1"
        IFS= read -r release < "$2"
        exit 0
        """
        return ProcessRuntimeBlockedFixture(pidPath: pidPath,
                                            arguments: ["-c", script, "runtime-blocked", pidPath, blockedFIFO],
                                            fifoDescriptor: descriptor)
    }

    func remove() {
        // Releasing all fixture FIFOs also lets a failed check unwind without
        // leaving a blocked descendant behind. Production cleanup is asserted
        // before this fallback runs.
        let line: [UInt8] = [114, 101, 108, 101, 97, 115, 101, 10]
        for descriptor in fifoDescriptors {
            _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            Darwin.close(descriptor)
        }
        fifoDescriptors.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
