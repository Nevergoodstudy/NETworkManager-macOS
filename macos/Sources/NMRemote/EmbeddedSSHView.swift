import AppKit
import Darwin
import NMCore
import SwiftTerm
import SwiftUI

public struct SSHLaunchConfiguration: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let displayTarget: String
    public let jumpHost: String?
    public var auditTarget: String {
        guard let separator = displayTarget.firstIndex(of: "@") else { return displayTarget }
        return String(displayTarget[displayTarget.index(after: separator)...])
    }

    public init(executable: String = "/usr/bin/ssh", arguments: [String], displayTarget: String, jumpHost: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.displayTarget = displayTarget
        self.jumpHost = jumpHost
    }
}

public struct SSHCommandSubmission: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let command: String
    public let confirmed: Bool

    public init(id: UUID = UUID(), command: String, confirmed: Bool = false) {
        self.id = id
        self.command = command
        self.confirmed = confirmed
    }
}

public enum SSHCommandBuilder {
    public enum ValidationError: LocalizedError {
        case invalidHost
        case invalidPort
        case invalidUsername
        case invalidIdentityFile
        case invalidJumpHost

        public var errorDescription: String? {
            switch self {
            case .invalidHost: return "Enter a valid SSH host or IP address."
            case .invalidPort: return "Enter a port between 1 and 65535."
            case .invalidUsername: return "Enter a valid SSH username."
            case .invalidIdentityFile: return "The SSH private-key path is invalid."
            case .invalidJumpHost: return t("Enter one jump host in [user@]host[:port] format.")
            }
        }
    }

    static let forwardReadyOutput = Data("NETworkManager SSH forward ready\n".utf8)

    static func localForward(connection: SSHLaunchConfiguration, localPort: Int,
                             targetHost: String, targetPort: Int) throws -> [String] {
        guard (1...65535).contains(localPort), (1...65535).contains(targetPort) else {
            throw ValidationError.invalidPort
        }
        let target = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = target.hasPrefix("[") && target.hasSuffix("]") ? String(target.dropFirst().dropLast()) : target
        let endpoint: String
        if literal.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, literal, &address) == 1 else { throw ValidationError.invalidHost }
            endpoint = "[\(literal)]"
        } else {
            guard literal.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9.-]{0,252}/#) != nil, target == literal else {
                throw ValidationError.invalidHost
            }
            endpoint = literal
        }
        let listen = "127.0.0.1:\(localPort):\(endpoint):\(targetPort)"
        let options = ["-N", "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=/bin/echo NETworkManager SSH forward ready",
                "-L", listen]
        return nonInteractive(connection, options: options)
    }

    package static func nonInteractive(_ connection: SSHLaunchConfiguration, options: [String] = []) -> [String] {
        ["-F", "/dev/null", "-T", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=10"] + options + connection.arguments.dropFirst(3)
    }

    public static func build(host: String, port: Int, username: String = "",
                             identityFile: String? = nil, jumpHost: String = "") throws -> SSHLaunchConfiguration {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketed = host.hasPrefix("[") && host.hasSuffix("]")
        let destination = bracketed ? String(host.dropFirst().dropLast()) : host
        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_%"))
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              destination.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) else {
            throw ValidationError.invalidHost
        }
        if bracketed {
            let addressAndZone = destination.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            var address = in6_addr()
            guard let literal = addressAndZone.first, inet_pton(AF_INET6, String(literal), &address) == 1,
                  addressAndZone.count == 1 || (!addressAndZone[1].isEmpty && !addressAndZone[1].contains("%")) else {
                throw ValidationError.invalidHost
            }
        }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort }

        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            let usernameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-\\"))
            guard username.count <= 128, !username.hasPrefix("-"),
                  username.unicodeScalars.allSatisfy({ usernameCharacters.contains($0) }) else {
                throw ValidationError.invalidUsername
            }
        }

        if let identityFile {
            guard !identityFile.isEmpty, identityFile.count <= 4_096,
                  identityFile.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError.invalidIdentityFile
            }
        }

        var arguments = ["-tt", "-o", "StrictHostKeyChecking=ask", "-p", String(port)]
        if let identityFile {
            arguments += ["-i", identityFile, "-o", "IdentitiesOnly=yes"]
        }
        if !username.isEmpty { arguments += ["-l", username] }
        let jumpHost = jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !jumpHost.isEmpty {
            // OpenSSH interpolates ProxyJump components into a child command.
            let endpoint = #/(?:(?:[A-Za-z0-9_.][A-Za-z0-9_.-]{0,127})@)?([A-Za-z0-9_.][A-Za-z0-9_.-]{0,252}|\[([0-9A-Fa-f:.]{2,45})\])(?::([0-9]{1,5}))?/#
            guard let match = jumpHost.wholeMatch(of: endpoint),
                  match.1.lowercased() != "none" else { throw ValidationError.invalidJumpHost }
            if let literal = match.2 {
                var address = in6_addr()
                guard inet_pton(AF_INET6, String(literal), &address) == 1 else {
                    throw ValidationError.invalidJumpHost
                }
            }
            if let port = match.3 {
                guard let port = Int(port), (1...65535).contains(port) else {
                    throw ValidationError.invalidJumpHost
                }
            }
            arguments += ["-J", jumpHost]
        }
        arguments += ["--", destination]
        let displayTarget = username.isEmpty ? host : "\(username)@\(host)"
        return SSHLaunchConfiguration(arguments: arguments, displayTarget: displayTarget,
                                      jumpHost: jumpHost.isEmpty ? nil : jumpHost)
    }
}

/// Embeds the system OpenSSH client in a SwiftTerm PTY. OpenSSH continues to
/// own authentication, host-key prompts, and the user's known_hosts database.
public struct EmbeddedSSHView: NSViewRepresentable {
    public let configuration: SSHLaunchConfiguration
    public let commandSubmission: SSHCommandSubmission?
    public let onCommandSubmitted: (SSHCommandSubmission) -> Void
    public let onExit: @MainActor (Int32?) -> Void

    public init(configuration: SSHLaunchConfiguration, commandSubmission: SSHCommandSubmission? = nil,
                onCommandSubmitted: @escaping (SSHCommandSubmission) -> Void = { _ in },
                onExit: @escaping @MainActor (Int32?) -> Void = { _ in }) {
        self.configuration = configuration
        self.commandSubmission = commandSubmission
        self.onCommandSubmitted = onCommandSubmitted
        self.onExit = onExit
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.startProcess(executable: configuration.executable, args: configuration.arguments)
        context.coordinator.observeExit(pid: view.process.shellPid)
        return view
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        guard let commandSubmission, context.coordinator.lastSubmissionID != commandSubmission.id else { return }
        context.coordinator.lastSubmissionID = commandSubmission.id
        guard isRunning(nsView.process) else { return }
        nsView.send(txt: commandSubmission.command + "\r")
        DispatchQueue.main.async { onCommandSubmitted(commandSubmission) }
    }

    private func isRunning(_ process: LocalProcess) -> Bool {
        guard process.running, process.childfd >= 0 else { return false }
        let pid = process.shellPid
        guard pid > 0 else { return true }
        // The PTY can report EOF before SwiftTerm delivers the exit callback.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size &&
            info.pbi_ppid == UInt32(getpid()) && info.pbi_status != SZOMB
    }

    public static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stopObservingExit()
        let pid = nsView.process.shellPid
        guard pid > 0 else { return }
        var event = siginfo_t()
        while Darwin.waitid(P_PID, id_t(pid), &event, WEXITED | WNOHANG | WNOWAIT) != 0 {
            guard errno == EINTR else { return }
        }

        // SwiftTerm 1.11.2 cancels its exit monitor on explicit termination.
        nsView.terminate()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    @MainActor
    public final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: @MainActor (Int32?) -> Void
        var lastSubmissionID: UUID?
        private var exitMonitor: DispatchSourceProcess?
        private var didReportExit = false

        init(onExit: @escaping @MainActor (Int32?) -> Void) {
            self.onExit = onExit
        }

        func observeExit(pid: pid_t) {
            guard pid > 0 else {
                DispatchQueue.main.async { self.reportExit(waitStatus: nil) }
                return
            }
            // SwiftTerm can cancel its process monitor when the PTY reaches EOF first.
            let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            let reap: @Sendable () -> Void = { [weak self] in
                var status: Int32 = 0
                var result = Darwin.waitpid(pid, &status, WNOHANG)
                while result < 0 && errno == EINTR { result = Darwin.waitpid(pid, &status, WNOHANG) }
                if result == pid { MainActor.assumeIsolated { self?.reportExit(waitStatus: status) } }
            }
            monitor.setRegistrationHandler(handler: reap)
            monitor.setEventHandler(handler: reap)
            exitMonitor = monitor
            monitor.activate()
        }

        func stopObservingExit() {
            exitMonitor?.cancel()
            exitMonitor = nil
        }

        public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public nonisolated func processTerminated(source: TerminalView, exitCode waitStatus: Int32?) {
            DispatchQueue.main.async { self.reportExit(waitStatus: waitStatus) }
        }

        private func reportExit(waitStatus: Int32?) {
            guard !didReportExit else { return }
            didReportExit = true
            stopObservingExit()
            // SwiftTerm 1.11.2 forwards the raw waitpid status from its macOS PTY.
            let exitCode = waitStatus.map { status in
                let signal = status & 0x7f
                return signal == 0 ? (status >> 8) & 0xff : 128 + signal
            }
            onExit(exitCode)
        }
    }
}
