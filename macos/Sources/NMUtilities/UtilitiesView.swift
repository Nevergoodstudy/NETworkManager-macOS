import SwiftUI
import AppKit
import NMCore

public struct UtilitiesView: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case hosts, traceroute, command, web, aws
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .hosts: return "Hosts File Editor"
            case .traceroute: return "Traceroute"
            case .command: return "PowerShell"
            case .web: return "Web Console"
            case .aws: return "AWS Session Manager"
            }
        }
    }

    @Environment(\.palette) private var palette
    @NMStateCompat private var kind: Kind
    @NMStateCompat private var host = "example.com"
    @NMStateCompat private var hostsText = ""
    @NMStateCompat private var command = "networksetup -listallhardwareports"
    @NMStateCompat private var url = "https://example.com"
    @NMStateCompat private var instanceID = "i-"
    @NMStateCompat private var awsProfile = ""
    @NMStateCompat private var awsRegion = ""
    @NMStateCompat private var output = ""
    @NMStateCompat private var error: String?
    @NMStateCompat private var isRunning = false
    @NMStateCompat private var commandTask: Task<Void, Never>?

    public init(kind: Kind = .traceroute) { _kind = NMStateCompat(wrappedValue: kind) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t(kind.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Tool"), selection: $kind) { ForEach(Kind.allCases) { Text(t($0.title)).tag($0) } }.pickerStyle(.menu)
            }
            if kind == .hosts { hostsBody }
            else if kind == .web { webBody }
            else if kind == .aws { awsBody }
            else { commandBody }
            if let error { Text(error).foregroundStyle(palette.danger) }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
        .onChange(of: kind) { _, newValue in
            commandTask?.cancel()
            output = ""
            error = nil
            if newValue == .hosts { loadHosts() }
        }
        .onDisappear { commandTask?.cancel() }
        .task { if kind == .hosts { loadHosts() } }
    }

    private var hostsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("The macOS hosts file is /etc/hosts. Saving requires administrator authorization."))
                .foregroundStyle(palette.textSecondary)
            TextEditor(text: $hostsText)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 420)
            HStack {
                Button(t("Reload")) { loadHosts() }.buttonStyle(.bordered)
                Button(t("Save")) { saveHosts() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var commandBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(kind == .traceroute ? t("Hostname or IP address") : t("Command"), text: kind == .traceroute ? $host : $command)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("utilityCommandInput")
                Button(t("Run")) { run() }.buttonStyle(.borderedProminent).disabled(isRunning)
                    .accessibilityIdentifier("runUtilityCommand")
                if commandTask != nil {
                    Button(t("Cancel")) { commandTask?.cancel() }.buttonStyle(.bordered)
                        .accessibilityIdentifier("cancelUtilityCommand")
                }
            }
            ScrollView {
                Text(output.isEmpty ? t("Nothing to show") : output)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 420)
        }
    }

    private var webBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(t("URL"), text: $url).textFieldStyle(.roundedBorder)
                Button(t("Open")) { openWebConsole() }.buttonStyle(.borderedProminent)
            }
            Text(t("Web Console opens the address in the default macOS browser."))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var awsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(t("Instance ID"), text: $instanceID).textFieldStyle(.roundedBorder)
                TextField(t("Profile (optional)"), text: $awsProfile).textFieldStyle(.roundedBorder)
                TextField(t("Region (optional)"), text: $awsRegion).textFieldStyle(.roundedBorder)
                Button(isRunning ? t("Running…") : t("Connect")) { startAWS() }
                    .buttonStyle(.borderedProminent).disabled(isRunning)
            }
            Text(t("AWS Session Manager uses the installed AWS CLI and session-manager-plugin in Terminal.app."))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func loadHosts() {
        hostsText = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
    }

    private func saveHosts() {
        let data = Data(hostsText.utf8).base64EncodedString()
        Task {
            let result = await Shell.runPrivileged("echo \(data) | /usr/bin/base64 --decode | /usr/bin/tee /etc/hosts >/dev/null")
            if !result.succeeded { error = result.output }
        }
    }

    private func run() {
        let selected = kind
        let input = selected == .traceroute ? host : command
        isRunning = true; error = nil; output = ""
        commandTask = Task {
            defer {
                commandTask = nil
                isRunning = false
            }
            if selected == .traceroute {
                let result = await DiagnosticService.runTraceroute(host: input)
                guard kind == selected else { return }
                output = result.displayOutput ?? result.detail
                if result.status != .succeeded { error = result.summary }
                return
            }
            let result = await Shell.runShell(input, timeout: 30)
            guard kind == selected else { return }
            output = result.stdout.isEmpty || result.stderr.isEmpty ? result.output :
                "\(t("Standard output"))\n\(result.stdout)\n\n\(t("Standard error"))\n\(result.stderr)"
            if result.stdoutTruncated || result.stderrTruncated {
                output += "\n" + t("Output truncated")
            }
            if !result.cleanupCompleted {
                error = t("Process cleanup incomplete")
                return
            }
            if result.cancelled {
                error = t("Cancelled")
                return
            }
            if result.timedOut {
                error = t("Timed out")
                return
            }
            if !result.succeeded {
                error = result.status >= 0 ? tf("Command exit status: %d", result.status) : result.stderr
            }
        }
    }

    private func openWebConsole() {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let target = components.url else {
            error = t("Enter a valid HTTP or HTTPS URL."); return
        }
        NSWorkspace.shared.open(target)
    }

    private func startAWS() {
        let target = instanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { error = t("Enter an EC2 instance ID."); return }
        var command = "aws ssm start-session --target \(shellQuote(target))"
        if !awsProfile.trimmingCharacters(in: .whitespaces).isEmpty { command += " --profile \(shellQuote(awsProfile))" }
        if !awsRegion.trimmingCharacters(in: .whitespaces).isEmpty { command += " --region \(shellQuote(awsRegion))" }
        openTerminal(command)
    }

    private func openTerminal(_ command: String) {
        isRunning = true
        Task {
            let result = await Shell.openTerminal(command: command)
            isRunning = false
            if !result.succeeded { error = result.output }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
