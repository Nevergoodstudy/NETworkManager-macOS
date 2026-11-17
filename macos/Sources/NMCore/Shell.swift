import Foundation
import Darwin

public enum CommandFailureCode: String, Codable, Hashable, Sendable {
    case missingExecutable
    case launch
    case permissionDenied
    case busy
}

public enum ProcessJobOperation: String, Codable, Hashable, Sendable {
    case command
    case traceroute
}

public enum ProcessJobState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case timedOut
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .timedOut, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

public struct ProcessJobSpec: Sendable, Identifiable {
    public let id: UUID
    public let operation: ProcessJobOperation
    public let targetScope: String
    public let deadline: Date
    // This adapter executes exactly one command for one target per job.
    public let maximumTargetCount = 1
    public let concurrency = 1
    public let maximumOutputBytesPerStream: Int
    public let terminationGrace: TimeInterval
    public let cancellation: DiagnosticCancellation?
    let createdUptime: TimeInterval
    let monotonicDeadline: TimeInterval

    public init(id: UUID = UUID(), operation: ProcessJobOperation, targetScope: String,
                deadline: Date,
                maximumOutputBytesPerStream: Int = 1_048_576, terminationGrace: TimeInterval = 0.5,
                cancellation: DiagnosticCancellation? = nil) {
        self.id = id
        self.operation = operation
        self.targetScope = targetScope
        self.deadline = deadline
        let created = ProcessInfo.processInfo.systemUptime
        self.createdUptime = created
        self.monotonicDeadline = created + max(0, deadline.timeIntervalSinceNow)
        self.maximumOutputBytesPerStream = max(0, min(maximumOutputBytesPerStream, 16_777_216))
        self.terminationGrace = max(0, min(terminationGrace, 2))
        self.cancellation = cancellation
    }
}

/// Result of running a child process.
public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let cancelled: Bool
    public let failureCode: CommandFailureCode?
    public let stdoutBytesObserved: Int
    public let stderrBytesObserved: Int
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let forcedTermination: Bool
    public let cleanupCompleted: Bool
    public let jobID: UUID?
    public let jobState: ProcessJobState
    public let processEvidence: ProcessExecutionEvidence?

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, cancelled: Bool = false,
                failureCode: CommandFailureCode? = nil, stdoutBytesObserved: Int? = nil,
                stderrBytesObserved: Int? = nil, stdoutTruncated: Bool = false,
                stderrTruncated: Bool = false, forcedTermination: Bool = false,
                cleanupCompleted: Bool = true, jobID: UUID? = nil,
                jobState: ProcessJobState? = nil, processEvidence: ProcessExecutionEvidence? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.failureCode = failureCode
        self.stdoutBytesObserved = stdoutBytesObserved ?? stdout.utf8.count
        self.stderrBytesObserved = stderrBytesObserved ?? stderr.utf8.count
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.forcedTermination = forcedTermination
        self.cleanupCompleted = cleanupCompleted
        self.jobID = jobID
        self.processEvidence = processEvidence
        self.jobState = jobState ?? (cancelled ? .cancelled : (timedOut ? .timedOut : (failureCode != nil || status != 0 ? .failed : .succeeded)))
    }

    public var succeeded: Bool { status == 0 && !timedOut && !cancelled && failureCode == nil && cleanupCompleted }

    public var output: String {
        stdout.isEmpty ? stderr : stdout
    }
}

/// Process execution helpers. Collected commands share one bounded runtime.
public enum Shell {
    public static func which(_ tool: String) -> String? {
        let candidates = ["/usr/bin/\(tool)", "/bin/\(tool)", "/usr/sbin/\(tool)", "/sbin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 30,
                           environment: [String: String]? = nil, cancellation: DiagnosticCancellation? = nil,
                           maximumOutputBytesPerStream: Int = 1_048_576,
                           terminationGrace: TimeInterval = 0.5) async -> CommandResult {
        let job = ProcessJobSpec(operation: .command, targetScope: path,
                                 deadline: Date().addingTimeInterval(max(0, timeout)),
                                 maximumOutputBytesPerStream: maximumOutputBytesPerStream,
                                 terminationGrace: terminationGrace, cancellation: cancellation)
        return await run(path, arguments, job: job, environment: environment)
    }

    public static func run(_ path: String, _ arguments: [String] = [], job: ProcessJobSpec,
                           environment: [String: String]? = nil) async -> CommandResult {
        let taskCancellation = DiagnosticCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: ProcessRuntime.run(path, arguments, job: job,
                        environment: environment, taskCancellation: taskCancellation))
                }
            }
        } onCancel: {
            taskCancellation.cancel()
        }
    }

    public static func runShell(_ command: String, timeout: TimeInterval = 30) async -> CommandResult {
        await run("/bin/sh", ["-c", command], timeout: timeout)
    }

    public static func runTool(_ tool: String, _ arguments: [String] = [], timeout: TimeInterval = 30,
                               cancellation: DiagnosticCancellation? = nil,
                               maximumOutputBytesPerStream: Int = 1_048_576) async -> CommandResult {
        let job = ProcessJobSpec(operation: .command, targetScope: tool,
                                 deadline: Date().addingTimeInterval(max(0, timeout)),
                                 maximumOutputBytesPerStream: maximumOutputBytesPerStream, cancellation: cancellation)
        return await runTool(tool, arguments, job: job)
    }

    public static func runTool(_ tool: String, _ arguments: [String] = [], job: ProcessJobSpec) async -> CommandResult {
        // Let spawn report ENOENT/EACCES for a concrete path. Search failure has a
        // separate explanation and does not infer permission denial.
        let path = tool.hasPrefix("/") ? tool : (which(tool) ?? "/usr/bin/\(tool)")
        return await run(path, arguments, job: job)
    }

    public static func openTerminal(command: String) async -> CommandResult {
        let script = "on run argv\n" +
            "tell application \"Terminal\" to do script (item 1 of argv)\n" +
            "end run"
        return await run("/usr/bin/osascript", ["-e", script, command], timeout: 30)
    }

    @discardableResult
    public static func runSync(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 30,
                               environment: [String: String]? = nil, cancellation: DiagnosticCancellation? = nil,
                               maximumOutputBytesPerStream: Int = 1_048_576) -> CommandResult {
        let job = ProcessJobSpec(operation: .command, targetScope: path,
                                 deadline: Date().addingTimeInterval(max(0, timeout)),
                                 maximumOutputBytesPerStream: maximumOutputBytesPerStream, cancellation: cancellation)
        return ProcessRuntime.run(path, arguments, job: job, environment: environment)
    }

    // MARK: Streaming

    /// Stream stdout line by line from a long running process (ptx excluded, for
    /// tools such as `traceroute` or `log stream`). Cancelling the consuming task
    /// terminates the process.
    public static func streamLines(_ path: String, _ arguments: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let handle = pipe.fileHandleForReading
            var buffer = Data()

            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let idx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer = buffer[buffer.index(after: idx)...]
                    if let line = String(data: Data(lineData), encoding: .utf8) {
                        continuation.yield(line.trimmingCharacters(in: .newlines))
                    }
                }
            }

            process.terminationHandler = { _ in
                handle.readabilityHandler = nil
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
        }
    }

    // MARK: Privileged helper

    /// Run a shell command with administrator privileges through the standard
    /// macOS authorisation dialog.
    public static func runPrivileged(_ command: String) async -> CommandResult {
        // Keep the AppleScript source constant. Passing the shell command as
        // argv prevents quotes, backslashes, and newlines in user data from
        // changing the AppleScript program itself.
        let script = "on run argv\n" +
            "if (count of argv) is 0 then error \"Missing command\" number -50\n" +
            "do shell script (item 1 of argv) with administrator privileges\n" +
            "end run"
        let result = await run("/usr/bin/osascript", ["-e", script, command], timeout: 120)
        if result.status != 0, result.stderr.contains("-128") {
            return CommandResult(status: 1, stdout: "", stderr: t("Authorization was cancelled."))
        }
        return result
    }
}
