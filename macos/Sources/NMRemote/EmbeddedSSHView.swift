import AppKit
import SwiftTerm
import SwiftUI

public struct SSHLaunchConfiguration: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let displayTarget: String
    public var auditTarget: String {
        guard let separator = displayTarget.firstIndex(of: "@") else { return displayTarget }
        return String(displayTarget[displayTarget.index(after: separator)...])
    }

    public init(executable: String = "/usr/bin/ssh", arguments: [String], displayTarget: String) {
        self.executable = executable
        self.arguments = arguments
        self.displayTarget = displayTarget
    }
}

public struct SSHCommandSubmission: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let command: String

    public init(id: UUID = UUID(), command: String) {
        self.id = id
        self.command = command
    }
}

public enum SSHCommandBuilder {
    public enum ValidationError: LocalizedError {
        case invalidHost
        case invalidPort
        case invalidUsername
        case invalidIdentityFile

        public var errorDescription: String? {
            switch self {
            case .invalidHost: return "Enter a valid SSH host or IP address."
            case .invalidPort: return "Enter a port between 1 and 65535."
            case .invalidUsername: return "Enter a valid SSH username."
            case .invalidIdentityFile: return "The SSH private-key path is invalid."
            }
        }
    }

    /// Builds a direct argv invocation. No shell is involved and no password
    /// or host-key bypass option is ever added.
    public static func build(host: String, port: Int, username: String = "", identityFile: String? = nil) throws -> SSHLaunchConfiguration {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_[]%"))
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) else {
            throw ValidationError.invalidHost
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
        arguments += ["--", host]
        let displayTarget = username.isEmpty ? host : "\(username)@\(host)"
        return SSHLaunchConfiguration(arguments: arguments, displayTarget: displayTarget)
    }
}

/// Embeds the system OpenSSH client in a SwiftTerm PTY. OpenSSH continues to
/// own authentication, host-key prompts, and the user's known_hosts database.
public struct EmbeddedSSHView: NSViewRepresentable {
    public let configuration: SSHLaunchConfiguration
    public let commandSubmission: SSHCommandSubmission?
    public let onExit: (Int32?) -> Void

    public init(configuration: SSHLaunchConfiguration, commandSubmission: SSHCommandSubmission? = nil, onExit: @escaping (Int32?) -> Void = { _ in }) {
        self.configuration = configuration
        self.commandSubmission = commandSubmission
        self.onExit = onExit
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.startProcess(executable: configuration.executable, args: configuration.arguments)
        return view
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        guard let commandSubmission, context.coordinator.lastSubmissionID != commandSubmission.id else { return }
        context.coordinator.lastSubmissionID = commandSubmission.id
        nsView.send(txt: commandSubmission.command + "\r")
    }

    public static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    public final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: (Int32?) -> Void
        var lastSubmissionID: UUID?

        init(onExit: @escaping (Int32?) -> Void) {
            self.onExit = onExit
        }

        public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public func processTerminated(source: TerminalView, exitCode: Int32?) {
            let callback = onExit
            DispatchQueue.main.async { callback(exitCode) }
        }
    }
}
