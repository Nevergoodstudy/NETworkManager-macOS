import Foundation

/// Result of running a child process.
public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let cancelled: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, cancelled: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    public var succeeded: Bool { status == 0 && !timedOut && !cancelled }

    public var output: String {
        stdout.isEmpty ? stderr : stdout
    }
}

/// Process execution helpers.
public enum Shell {
    // MARK: Paths

    public static func which(_ tool: String) -> String? {
        let candidates = ["/usr/bin/\(tool)", "/bin/\(tool)", "/usr/sbin/\(tool)", "/sbin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: Async API

    /// Run an executable and wait for it to finish (or time out).
    public static func run(_ path: String,
                           _ arguments: [String] = [],
                           timeout: TimeInterval = 30,
                           environment: [String: String]? = nil,
                           cancellation: DiagnosticCancellation? = nil) async -> CommandResult {
        let processCancellation = ProcessCancellation()
        return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                guard processCancellation.prepare(process) else {
                    continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: "Cancelled", cancelled: true))
                    return
                }
                do { try process.run() }
                catch {
                    processCancellation.clear(process)
                    continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                processCancellation.terminateIfCancelled(process)

                final class Buffers: @unchecked Sendable { var out = Data(); var err = Data() }
                let buffers = Buffers()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    buffers.out = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    buffers.err = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while process.isRunning && Date() < deadline && !processCancellation.isCancelled && cancellation?.isCancelled != true { usleep(15_000) }
                if process.isRunning {
                    timedOut = !processCancellation.isCancelled && cancellation?.isCancelled != true
                    process.terminate()
                    usleep(120_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
                group.wait()
                processCancellation.clear(process)
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: buffers.out, as: UTF8.self),
                    stderr: String(decoding: buffers.err, as: UTF8.self),
                    timedOut: timedOut,
                    cancelled: processCancellation.isCancelled || cancellation?.isCancelled == true
                ))
            }
        }
        } onCancel: {
            processCancellation.cancel()
        }
    }

    /// Run a `sh -c` command line.
    public static func runShell(_ command: String, timeout: TimeInterval = 30) async -> CommandResult {
        await run("/bin/sh", ["-c", command], timeout: timeout)
    }

    /// Find a tool and run it; returns a failing result when the tool is missing.
    public static func runTool(_ tool: String, _ arguments: [String] = [], timeout: TimeInterval = 30, cancellation: DiagnosticCancellation? = nil) async -> CommandResult {
        let path = tool.hasPrefix("/") ? tool : which(tool)
        guard let path else {
            return CommandResult(status: 127, stdout: "", stderr: "\(tool): command not found")
        }
        return await run(path, arguments, timeout: timeout, cancellation: cancellation)
    }

    /// Ask Terminal.app to open a command. The command is passed as an
    /// osascript argument instead of being interpolated into AppleScript.
    public static func openTerminal(command: String) async -> CommandResult {
        let script = "on run argv\n" +
            "tell application \"Terminal\" to do script (item 1 of argv)\n" +
            "end run"
        return await run("/usr/bin/osascript", ["-e", script, command], timeout: 30)
    }

    // MARK: Sync API

    @discardableResult
    public static func runSync(_ path: String,
                               _ arguments: [String] = [],
                               timeout: TimeInterval = 30,
                               environment: [String: String]? = nil,
                               cancellation: DiagnosticCancellation? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        final class Buffers: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let buffers = Buffers()

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            buffers.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            buffers.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && cancellation?.isCancelled != true {
            usleep(15_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = cancellation?.isCancelled != true
            process.terminate()
            usleep(120_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: buffers.out, as: UTF8.self),
            stderr: String(decoding: buffers.err, as: UTF8.self),
            timedOut: timedOut,
            cancelled: cancellation?.isCancelled == true
        )
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

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var process: Process?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func prepare(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        terminateIfCancelled(current)
    }

    func terminateIfCancelled(_ process: Process?) {
        guard isCancelled, let process, process.isRunning else { return }
        process.terminate()
    }

    func clear(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }
}
