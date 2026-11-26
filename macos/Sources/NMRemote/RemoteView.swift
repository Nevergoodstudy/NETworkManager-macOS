import SwiftUI
import AppKit
import NMCore

public struct RemoteView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @ObservedObject private var sshLayout = SSHSessionLayoutStore.shared
    @NMStateCompat private var proto: ConnectionProtocol = .ssh
    @NMStateCompat private var host = ""
    @NMStateCompat private var port = "22"
    @NMStateCompat private var username = ""
    @NMStateCompat private var jumpHost = ""
    @NMStateCompat private var selectedSSHCredentialID = "none"
    @NMStateCompat private var status = ""
    @NMStateCompat private var forwardLocalPort = ""
    @NMStateCompat private var forwardTargetHost = ""
    @NMStateCompat private var forwardTargetPort = ""
    @NMStateCompat private var forwardCancellation: DiagnosticCancellation?
    @NMStateCompat private var forwardStatus = ""
    @NMStateCompat private var sshSessions: [UUID: SSHSession] = [:]
    @NMStateCompat private var selectedTemplateID = SSHCommandTemplate.readOnly[0].id
    @NMStateCompat private var commandText = SSHCommandTemplate.readOnly[0].command
    @NMStateCompat private var readySSHSessionIDs: Set<UUID> = []
    @NMStateCompat private var queuedCommand: PendingSSHCommand?
    @NMStateCompat private var showCommandConfirmation = false
    @StateObject private var auditLog = OperationsAuditLog.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Remote")).font(.largeTitle.bold())
            GroupBox(t("Connection")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(t("Protocol"), selection: $proto) { ForEach(ConnectionProtocol.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.segmented)
                        .disabled(forwardCancellation != nil)
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
                            TextField(t("Jump host (optional)"), text: $jumpHost)
                                .textFieldStyle(.roundedBorder)
                                .help(t("Enter one jump host in [user@]host[:port] format."))
                                .onSubmit(connect)
                        }
                    }
                }
            }
            if proto == .ssh {
                Label(t("SSH host keys are verified by OpenSSH. First connections prompt in the terminal; changed keys are rejected."), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                forwardControls
            }
            Text(t("SSH sessions run in this window. RDP and VNC open compatible installed clients; web protocols use the default browser."))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(status).foregroundStyle(palette.textSecondary) }
            if let error = sshLayout.persistenceError { Text(error).foregroundStyle(palette.textSecondary) }
            if !sshLayout.layout.tabs.isEmpty {
                operationComposer
                sshSessionWorkspace
                operationHistory
            }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
        .onDisappear { forwardCancellation?.cancel() }
        .onChange(of: proto) { _, value in port = String(value.defaultPort) }
        .onChange(of: selectedTemplateID) { _, value in
            if let template = SSHCommandTemplate.readOnly.first(where: { $0.id == value }) {
                commandText = template.command
            }
        }
        .onChange(of: selectedSSHSessionID) { _, _ in cancelCommandConfirmation() }
        .onChange(of: Set(sshLayout.layout.tabs.map(\.id))) { previous, current in
            for id in previous.subtracting(current) { removeLiveSession(id) }
        }
        .onChange(of: commandText) { _, _ in cancelCommandConfirmation() }
        .onChange(of: isPromptReady) { _, ready in
            if !ready { cancelCommandConfirmation() }
        }
        .confirmationDialog(t("Confirm SSH operation"), isPresented: $showCommandConfirmation, titleVisibility: .visible,
                            presenting: queuedCommand) { request in
            Button(t("Send command"), role: .destructive) {
                guard queuedCommand == request, selectedSSHSessionID == request.sessionID,
                      commandText == request.command else { return }
                cancelCommandConfirmation()
                submitSSHCommand(request.command, to: request.sessionID, confirmed: true)
            }
            Button(t("Cancel"), role: .cancel, action: cancelCommandConfirmation)
        } message: { request in
            Text(tf("Target: %@\nCommand:\n%@", request.displayTarget, SSHCommandPolicy.reviewedText(request.command)))
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
                let tab = SSHSessionTab(host: target, port: numericPort,
                                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                        jumpHost: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines),
                                        credentialID: UUID(uuidString: selectedSSHCredentialID))
                try startSession(for: tab)
                var layout = sshLayout.layout
                layout.tabs.append(tab)
                layout.selectedID = tab.id
                sshLayout.save(layout)
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

    private func startSession(for tab: SSHSessionTab) throws {
        guard sshSessions[tab.id] == nil else { return }
        let configuration = try sshConfiguration(for: tab)
        sshSessions[tab.id] = SSHSession(configuration: configuration)
        auditLog.record(target: configuration.auditTarget, kind: .sshSessionOpened)
        status = tf("SSH terminal opened for %@", tab.displayTarget(configuration: configuration))
    }

    private func sshConfiguration(for tab: SSHSessionTab) throws -> SSHLaunchConfiguration {
        var username = tab.username
        var identity: String?
        if let credentialID = tab.credentialID {
            guard let reference = sshKeyReferences.first(where: { $0.id == credentialID }) else {
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
            if username.isEmpty { username = reference.account }
        }
        return try SSHCommandBuilder.build(host: tab.host, port: tab.port, username: username,
                                           identityFile: identity, jumpHost: tab.jumpHost)
    }

    private var forwardControls: some View {
        GroupBox(t("SSH local forwarding")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(t("Local port"), text: $forwardLocalPort).frame(width: 100)
                    TextField(t("Forward destination"), text: $forwardTargetHost)
                    TextField(t("Destination port"), text: $forwardTargetPort).frame(width: 105)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(forwardCancellation != nil)
                HStack {
                    Button(t("Start forwarding")) { startForward() }
                        .disabled(forwardCancellation != nil)
                        .accessibilityIdentifier("sshForwardStart")
                    if let forwardCancellation {
                        Button(t("Stop forwarding")) {
                            forwardStatus = t("Stopping…")
                            forwardCancellation.cancel()
                        }
                        .accessibilityIdentifier("sshForwardStop")
                    }
                    if !forwardStatus.isEmpty {
                        Text(forwardStatus).textSelection(.enabled)
                    }
                }
                Text(t("Listens on 127.0.0.1. Verify the SSH host keys in the terminal before starting."))
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(4)
        }
    }

    private func startForward() {
        guard let sshPort = Int(port), let localPort = Int(forwardLocalPort), let targetPort = Int(forwardTargetPort) else {
            forwardStatus = SSHCommandBuilder.ValidationError.invalidPort.localizedDescription
            return
        }
        do {
            let tab = SSHSessionTab(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: sshPort,
                                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                    jumpHost: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines),
                                    credentialID: UUID(uuidString: selectedSSHCredentialID))
            let connection = try sshConfiguration(for: tab)
            let arguments = try SSHCommandBuilder.localForward(connection: connection, localPort: localPort,
                                                                targetHost: forwardTargetHost, targetPort: targetPort)
            let cancellation = DiagnosticCancellation()
            let job = ProcessJobSpec(operation: .command, targetScope: connection.auditTarget,
                                     deadline: Date().addingTimeInterval(86_400), maximumOutputBytesPerStream: 8192,
                                     cancellation: cancellation)
            forwardCancellation = cancellation
            forwardStatus = t("Starting forwarding…")
            Task {
                let result = await Shell.run(connection.executable, arguments, job: job,
                                             environment: ["SHELL": "/bin/sh", "SSH_ASKPASS_REQUIRE": "never"],
                                             readiness: (SSHCommandBuilder.forwardReadyOutput, 15)) {
                    Task { @MainActor in
                        guard forwardCancellation === cancellation, !cancellation.isCancelled else { return }
                        forwardStatus = tf("Listening on 127.0.0.1:%d", localPort)
                    }
                }
                forwardCancellation = nil
                switch result.jobState {
                case .cancelled, .succeeded:
                    forwardStatus = t("Forwarding stopped")
                case .timedOut:
                    forwardStatus = t("Timed out")
                default:
                    let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    forwardStatus = details.isEmpty ? t("SSH forwarding failed") : details
                }
                if !result.cleanupCompleted { forwardStatus += "\n" + t("Process cleanup incomplete") }
            }
        } catch {
            forwardStatus = error.localizedDescription
        }
    }

    private var selectedSSHSessionID: UUID? { sshLayout.layout.selectedID }

    private var sshSessionWorkspace: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(sshLayout.layout.tabs) { tab in
                        let session = sshSessions[tab.id]
                        let target = tab.displayTarget(configuration: session?.configuration)
                        HStack(spacing: 4) {
                            Button {
                                guard selectedSSHSessionID != tab.id else { return }
                                var layout = sshLayout.layout
                                layout.selectedID = tab.id
                                sshLayout.save(layout)
                            } label: {
                                Label(session?.exitCode.map { "\(target) (\($0))" } ?? target, systemImage: "terminal")
                                    .lineLimit(1)
                                    .padding(.leading, 10)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .help(target)
                            .accessibilityAddTraits(selectedSSHSessionID == tab.id ? .isSelected : [])
                            Button {
                                closeSession(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(t("Close SSH session"))
                            .accessibilityLabel(t("Close SSH session"))
                        }
                        .background(selectedSSHSessionID == tab.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
            }
            Divider()
            ZStack {
                ForEach(sshLayout.layout.tabs) { tab in
                    if let session = sshSessions[tab.id] {
                        EmbeddedSSHView(configuration: session.configuration, commandSubmission: session.commandSubmission) { submission in
                            let kind: OperationAuditKind = submission.confirmed ? .confirmedCommandSubmitted : .readOnlyCommandSubmitted
                            auditLog.record(target: session.configuration.auditTarget, kind: kind)
                            status = t("Command submitted to the active SSH session")
                        } onExit: { exitCode in
                            updateSession(tab.id, exitCode: exitCode)
                        }
                        .opacity(selectedSSHSessionID == tab.id ? 1 : 0)
                        .allowsHitTesting(selectedSSHSessionID == tab.id)
                        .accessibilityHidden(selectedSSHSessionID != tab.id)
                    }
                    if selectedSSHSessionID == tab.id, sshSessions[tab.id] == nil {
                        VStack(spacing: 10) {
                            Text(t("SSH session disconnected")).foregroundStyle(palette.textSecondary)
                            Button(t("Connect")) {
                                do { try startSession(for: tab) }
                                catch { status = error.localizedDescription }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("connectSavedSSHSession")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minHeight: 320)
        .overlay(alignment: .topLeading) {
            if let exitCode = selectedSSHSession?.exitCode {
                Text(tf("SSH exited with code %@", String(exitCode)))
                    .font(.caption.monospaced())
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
            }
        }
    }

    private func updateSession(_ id: UUID, exitCode: Int32?) {
        guard let session = sshSessions[id], session.exitCode == nil else { return }
        sshSessions[id]?.exitCode = exitCode ?? -1
        var readyIDs = readySSHSessionIDs
        readyIDs.remove(id)
        readySSHSessionIDs = readyIDs
        auditLog.record(target: session.configuration.auditTarget, kind: .sshSessionClosed)
    }

    private func closeSession(_ id: UUID) {
        removeLiveSession(id)
        var layout = sshLayout.layout
        layout.tabs.removeAll { $0.id == id }
        if layout.selectedID == id { layout.selectedID = layout.tabs.last?.id }
        sshLayout.save(layout)
    }

    private func removeLiveSession(_ id: UUID) {
        if let session = sshSessions.removeValue(forKey: id), session.exitCode == nil {
            auditLog.record(target: session.configuration.auditTarget, kind: .sshSessionClosed)
        }
        readySSHSessionIDs.remove(id)
    }

    private var selectedSSHSession: SSHSession? {
        selectedSSHSessionID.flatMap { sshSessions[$0] }
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
        guard let id = selectedSSHSessionID, let session = sshSessions[id], session.exitCode == nil else { return false }
        return readySSHSessionIDs.contains(id)
    }

    private var commandIsValid: Bool {
        (try? SSHCommandPolicy.review(commandText)) != nil
    }

    private var isReadOnlyCommand: Bool {
        guard case .readOnly = try? SSHCommandPolicy.review(commandText) else { return false }
        return true
    }

    private func reviewAndSendCommand() {
        guard let id = selectedSSHSessionID, let session = sshSessions[id],
              let tab = sshLayout.layout.tabs.first(where: { $0.id == id }), isPromptReady else { return }
        do {
            switch try SSHCommandPolicy.review(commandText) {
            case .readOnly:
                submitSSHCommand(commandText, to: id, confirmed: false)
            case .requiresConfirmation:
                queuedCommand = PendingSSHCommand(sessionID: id, displayTarget: tab.displayTarget(configuration: session.configuration),
                                                  command: commandText)
                showCommandConfirmation = true
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func cancelCommandConfirmation() {
        showCommandConfirmation = false
        queuedCommand = nil
    }

    private func submitSSHCommand(_ command: String, to id: UUID, confirmed: Bool) {
        guard let session = sshSessions[id], session.exitCode == nil,
              readySSHSessionIDs.contains(id) else { return }
        sshSessions[id]?.commandSubmission = SSHCommandSubmission(command: command, confirmed: confirmed)
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

private struct PendingSSHCommand: Equatable {
    let sessionID: UUID
    let displayTarget: String
    let command: String
}

private struct SSHSession {
    let configuration: SSHLaunchConfiguration
    var exitCode: Int32?
    var commandSubmission: SSHCommandSubmission?
}
