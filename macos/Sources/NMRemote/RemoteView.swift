import SwiftUI
import AppKit
import NMCore

public struct RemoteView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @NMStateCompat private var proto: ConnectionProtocol = .ssh
    @NMStateCompat private var host = ""
    @NMStateCompat private var port = "22"
    @NMStateCompat private var username = ""
    @NMStateCompat private var selectedSSHCredentialID = "none"
    @NMStateCompat private var status = ""
    @NMStateCompat private var sshSessions: [SSHSession] = []
    @NMStateCompat private var selectedSSHSessionID: UUID?
    @NMStateCompat private var selectedTemplateID = SSHCommandTemplate.readOnly[0].id
    @NMStateCompat private var commandText = SSHCommandTemplate.readOnly[0].command
    @NMStateCompat private var readySSHSessionIDs: Set<UUID> = []
    @NMStateCompat private var queuedCommand: String?
    @NMStateCompat private var showCommandConfirmation = false
    @StateObject private var auditLog = OperationsAuditLog.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Remote")).font(.largeTitle.bold())
            GroupBox(t("Connection")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(t("Protocol"), selection: $proto) { ForEach(ConnectionProtocol.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented)
                    HStack {
                        TextField(t("Host"), text: $host).textFieldStyle(.roundedBorder)
                        TextField(t("Port"), text: $port).textFieldStyle(.roundedBorder).frame(width: 90)
                        TextField(t("Username (optional)"), text: $username).textFieldStyle(.roundedBorder)
                            .onSubmit(connect)
                        Button(t("Connect")) { connect() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                    if proto == .ssh {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill").foregroundStyle(.secondary)
                            Picker(t("SSH identity in Keychain"), selection: $selectedSSHCredentialID) {
                                Text(t("No SSH identity")).tag("none")
                                ForEach(sshKeyReferences) { reference in
                                    Text(reference.label).tag(reference.id.uuidString)
                                }
                            }
                            .frame(maxWidth: 320)
                        }
                    }
                }
            }
            if proto == .ssh {
                Label(t("SSH host keys are verified by OpenSSH. First connections prompt in the terminal; changed keys are rejected."), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(t("SSH sessions run in this window. RDP and VNC open compatible installed clients; web protocols use the default browser."))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(status).foregroundStyle(palette.textSecondary) }
            if !sshSessions.isEmpty {
                operationComposer
                sshSessionWorkspace
                operationHistory
            }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
        .onChange(of: proto) { _, value in port = String(value.defaultPort) }
        .onChange(of: selectedTemplateID) { _, value in
            if let template = SSHCommandTemplate.readOnly.first(where: { $0.id == value }) {
                commandText = template.command
            }
        }
        .confirmationDialog(t("Confirm SSH operation"), isPresented: $showCommandConfirmation, titleVisibility: .visible) {
            Button(t("Send command"), role: .destructive) {
                guard let queuedCommand else { return }
                submitSSHCommand(queuedCommand, confirmed: true)
                self.queuedCommand = nil
            }
            Button(t("Cancel"), role: .cancel) { queuedCommand = nil }
        } message: {
            if let session = selectedSSHSession, let queuedCommand {
            Text(tf("Target: %@\nCommand:\n%@", session.configuration.displayTarget, SSHCommandPolicy.reviewedText(queuedCommand)))
            }
        }
    }

    private func connect() {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        switch proto {
        case .ssh:
            guard let numericPort = Int(port) else {
                status = SSHCommandBuilder.ValidationError.invalidPort.localizedDescription
                return
            }
            do {
                let identity: String?
                var sshUsername = username
                if selectedSSHCredentialID == "none" {
                    identity = nil
                } else {
                    guard let reference = sshKeyReferences.first(where: { $0.id.uuidString == selectedSSHCredentialID }) else {
                        throw SSHCommandBuilder.ValidationError.invalidIdentityFile
                    }
                    let secret = try credentials.secret(for: reference)
                    guard let keyPath = secret.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !keyPath.isEmpty else {
                        throw SSHCommandBuilder.ValidationError.invalidIdentityFile
                    }
                    let expandedPath = (keyPath as NSString).expandingTildeInPath
                    guard FileManager.default.isReadableFile(atPath: expandedPath) else {
                        throw SSHCommandBuilder.ValidationError.invalidIdentityFile
                    }
                    identity = expandedPath
                    if sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sshUsername = reference.account
                    }
                }
                let configuration = try SSHCommandBuilder.build(host: target, port: numericPort, username: sshUsername, identityFile: identity)
                let session = SSHSession(configuration: configuration)
                sshSessions.append(session)
                selectedSSHSessionID = session.id
                auditLog.record(target: configuration.auditTarget, kind: .sshSessionOpened)
                status = tf("SSH terminal opened for %@", configuration.displayTarget)
            } catch {
                status = error.localizedDescription
            }
        case .http, .https:
            guard isSafeEndpoint(target), let numericPort = Int(port), (1...65535).contains(numericPort) else {
                status = t("Enter a valid host and port")
                return
            }
            openURL(scheme: proto.rawValue, host: target, port: numericPort, success: t("Browser opened"))
        case .vnc:
            guard isSafeEndpoint(target), let numericPort = Int(port), (1...65535).contains(numericPort) else {
                status = t("Enter a valid host and port")
                return
            }
            openURL(scheme: "vnc", host: target, port: numericPort, success: t("VNC client opened"))
        case .rdp:
            guard isSafeEndpoint(target), let numericPort = Int(port), (1...65535).contains(numericPort) else {
                status = t("Enter a valid host and port")
                return
            }
            openURL(scheme: "rdp", host: target, port: numericPort, success: t("RDP client opened"))
        case .snmp:
            status = t("Use the SNMP tool to query this profile.")
        case .telnet:
            guard isSafeEndpoint(target), let numericPort = Int(port), (1...65535).contains(numericPort) else {
                status = t("Enter a valid host and port")
                return
            }
            let command = "telnet \(shellQuote(target)) \(numericPort)"
            openTerminal(command)
        }
    }

    private var sshKeyReferences: [CredentialRef] {
        credentials.references.filter { $0.kind == .sshKeyReference }
    }

    private var sshSessionWorkspace: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(sshSessions) { session in
                        HStack(spacing: 4) {
                            Button {
                                selectedSSHSessionID = session.id
                            } label: {
                                Label(session.title, systemImage: "terminal")
                                    .lineLimit(1)
                                    .padding(.leading, 10)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .help(session.configuration.displayTarget)
                            Button {
                                closeSession(session.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(t("Close SSH session"))
                            .accessibilityLabel(t("Close SSH session"))
                        }
                        .background(selectedSSHSessionID == session.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
            }
            Divider()
            ZStack {
                ForEach(sshSessions) { session in
                    EmbeddedSSHView(configuration: session.configuration, commandSubmission: session.commandSubmission) { exitCode in
                        updateSession(session.id, exitCode: exitCode)
                    }
                    .id(session.id)
                    .opacity(selectedSSHSessionID == session.id ? 1 : 0)
                    .allowsHitTesting(selectedSSHSessionID == session.id)
                    .accessibilityHidden(selectedSSHSessionID != session.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minHeight: 320)
        .overlay(alignment: .topLeading) {
            if let session = sshSessions.first(where: { $0.id == selectedSSHSessionID }),
               let exitCode = session.exitCode {
                Text(tf("SSH exited with code %@", String(exitCode)))
                    .font(.caption.monospaced())
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
            }
        }
    }

    private func updateSession(_ id: UUID, exitCode: Int32?) {
        guard let index = sshSessions.firstIndex(where: { $0.id == id }) else { return }
        guard sshSessions[index].exitCode == nil else { return }
        sshSessions[index].exitCode = exitCode ?? -1
        var readyIDs = readySSHSessionIDs
        readyIDs.remove(id)
        readySSHSessionIDs = readyIDs
        auditLog.record(target: sshSessions[index].configuration.auditTarget, kind: .sshSessionClosed)
    }

    private func closeSession(_ id: UUID) {
        if let session = sshSessions.first(where: { $0.id == id }), session.exitCode == nil {
            auditLog.record(target: session.configuration.auditTarget, kind: .sshSessionClosed)
        }
        sshSessions.removeAll { $0.id == id }
        var readyIDs = readySSHSessionIDs
        readyIDs.remove(id)
        readySSHSessionIDs = readyIDs
        if selectedSSHSessionID == id { selectedSSHSessionID = sshSessions.last?.id }
    }

    private var selectedSSHSession: SSHSession? {
        sshSessions.first { $0.id == selectedSSHSessionID }
    }

    private var operationComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("SSH operations")).font(.headline)
                Spacer()
                Toggle(t("I have accepted the host key and can see the device prompt."), isOn: Binding(
                    get: { selectedSSHSessionID.map(readySSHSessionIDs.contains) ?? false },
                    set: { isReady in
                        guard let id = selectedSSHSessionID else { return }
                        var readyIDs = readySSHSessionIDs
                        if isReady { readyIDs.insert(id) } else { readyIDs.remove(id) }
                        readySSHSessionIDs = readyIDs
                    }
                ))
                .toggleStyle(.checkbox)
                .disabled(selectedSSHSession?.exitCode != nil || selectedSSHSession == nil)
            }
            Picker(t("Read-only template"), selection: $selectedTemplateID) {
                ForEach(SSHCommandTemplate.readOnly) { template in
                    Text(t(template.title)).tag(template.id)
                }
            }
            .frame(maxWidth: 340)
            TextField(t("Command"), text: $commandText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: commandText) { _, _ in queuedCommand = nil }
            HStack {
                Text(t("Only exact built-in templates are treated as read-only. Other commands require review and confirmation."))
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(isReadOnlyCommand ? t("Send") : t("Review & send")) { reviewAndSendCommand() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPromptReady || !commandIsValid)
            }
            Text(t("The audit log stores target, time, and action category. It does not store command text or output; direct terminal input is not recorded."))
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 6))
    }

    private var operationHistory: some View {
        GroupBox(t("Operation history")) {
            if auditLog.records.isEmpty {
                Text(t("No operations recorded"))
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(auditLog.records.prefix(8)) { record in
                        HStack(spacing: 8) {
                            Text(record.timestamp, style: .time)
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textSecondary)
                            Text(record.target).font(.callout.monospaced())
                            Text(record.kind.displayName).font(.callout)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var isPromptReady: Bool {
        guard let session = selectedSSHSession, session.exitCode == nil else { return false }
        return readySSHSessionIDs.contains(session.id)
    }

    private var commandIsValid: Bool {
        (try? SSHCommandPolicy.review(commandText)) != nil
    }

    private var isReadOnlyCommand: Bool {
        guard case .readOnly = try? SSHCommandPolicy.review(commandText) else { return false }
        return true
    }

    private func reviewAndSendCommand() {
        guard isPromptReady else { return }
        do {
            switch try SSHCommandPolicy.review(commandText) {
            case .readOnly:
                submitSSHCommand(commandText, confirmed: false)
            case .requiresConfirmation:
                queuedCommand = commandText
                showCommandConfirmation = true
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func submitSSHCommand(_ command: String, confirmed: Bool) {
        guard let id = selectedSSHSessionID,
              let index = sshSessions.firstIndex(where: { $0.id == id }),
              readySSHSessionIDs.contains(id) else { return }
        sshSessions[index].commandSubmission = SSHCommandSubmission(command: command)
        let kind: OperationAuditKind = confirmed ? .confirmedCommandSubmitted : .readOnlyCommandSubmitted
        auditLog.record(target: sshSessions[index].configuration.auditTarget, kind: kind)
        status = t("Command submitted to the active SSH session")
    }

    private func openTerminal(_ command: String) {
        Task {
            let result = await Shell.openTerminal(command: command)
            status = result.succeeded ? t("Terminal opened") : result.output
        }
    }

    private func openURL(scheme: String, host: String, port: Int, success: String) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        guard let url = components.url else {
            status = t("Enter a valid host or IP address")
            return
        }
        NSWorkspace.shared.open(url)
        status = success
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func isSafeEndpoint(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-"), value.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_[]%"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

private struct SSHSession: Identifiable {
    let id = UUID()
    let configuration: SSHLaunchConfiguration
    var exitCode: Int32?
    var commandSubmission: SSHCommandSubmission?

    var title: String {
        let target = configuration.displayTarget
        return exitCode.map { "\(target) (\($0))" } ?? target
    }
}
