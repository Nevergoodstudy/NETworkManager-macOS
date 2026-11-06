import SwiftUI
import NMCore
import NMAssets

public struct ZabbixView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @ObservedObject private var assets = AssetStore.shared
    private let openDiagnosticHistory: (String) -> Void

    @NMStateCompat private var baseURLText: String
    @NMStateCompat private var selectedCredentialID: String
    @NMStateCompat private var problems: [ZabbixProblem] = []
    @NMStateCompat private var isWorking = false
    @NMStateCompat private var statusMessage = ""
    @NMStateCompat private var statusKind: StatusKind = .idle
    @NMStateCompat private var runningPingKeys: Set<String> = []
    @NMStateCompat private var pingFeedback: [String: PingFeedback] = [:]

    private enum StatusKind { case idle, working, success, warning, failure }

    private struct PingFeedback {
        let status: DiagnosticRunStatus
        let summary: String
        let latency: TimeInterval?
    }

    public init(openDiagnosticHistory: @escaping (String) -> Void = { _ in }) {
        let saved = Self.savedConfiguration()
        self.openDiagnosticHistory = openDiagnosticHistory
        _baseURLText = NMStateCompat(wrappedValue: saved?.baseURL.absoluteString ?? "https://zabbix.example")
        _selectedCredentialID = NMStateCompat(wrappedValue: saved?.tokenReference ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            connectionForm
            statusRow
            if let fetchedAt {
                Text(tf("Active problems · updated %@", Fmt.dateTime(fetchedAt)))
                    .font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
            }
            problemList
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
        .onChange(of: baseURLText) { _, _ in
            persistConfiguration()
            validateBaseURLInput()
        }
        .onChange(of: selectedCredentialID) { _, _ in persistConfiguration() }
        .onAppear { validateBaseURLInput() }
        .onChange(of: credentials.references) { _, references in
            guard !selectedCredentialID.isEmpty,
                  !references.contains(where: { $0.id.uuidString == selectedCredentialID && $0.kind == .token }) else { return }
            selectedCredentialID = ""
            statusKind = .warning
            statusMessage = t("The selected Keychain credential is no longer available.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("Zabbix problems")).font(.largeTitle.bold())
            Text(t("Read active monitoring problems and launch a diagnostic against a host interface."))
                .font(.callout).foregroundStyle(palette.textSecondary)
        }
    }

    private var connectionForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField(t("Zabbix base URL"), text: $baseURLText)
                    .textFieldStyle(.roundedBorder).disabled(isWorking)
                    .accessibilityIdentifier("zabbixBaseURL")
                HStack(spacing: 12) {
                    Picker(t("API token in Keychain"), selection: $selectedCredentialID) {
                        Text(t("Select a credential")).tag("")
                        ForEach(tokenCredentials) { item in
                            Text(item.account.isEmpty ? item.label : "\(item.label) · \(item.account)")
                                .tag(item.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                    .disabled(isWorking || tokenCredentials.isEmpty)
                    .accessibilityIdentifier("zabbixCredentialPicker")
                    if tokenCredentials.isEmpty {
                        Text(t("Add an API token in Credentials before connecting."))
                            .font(.caption).foregroundStyle(palette.warning)
                    }
                }
                HStack(spacing: 9) {
                    Button { refreshProblems() } label: {
                        Label(t("Refresh problems"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !canConnect)
                    .accessibilityIdentifier("zabbixRefreshProblems")
#if DEBUG
                    Button { loadLoopbackFixture() } label: {
                        Label(t("Load loopback fixture"), systemImage: "testtube.2")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("zabbixLoadLoopbackFixture")
#endif
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(t("Read-only · problems and host interfaces"))
                        .font(.caption).foregroundStyle(palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol).foregroundStyle(statusColor)
            Text(statusTitle).font(.headline)
            if !statusMessage.isEmpty {
                Text(statusMessage).foregroundStyle(palette.textSecondary).textSelection(.enabled)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.vertical, 4)
        .accessibilityIdentifier("zabbixStatus")
    }

    @ViewBuilder
    private var problemList: some View {
        if problems.isEmpty && fetchedAt == nil {
            ContentUnavailableView(t("No problem data"), systemImage: "waveform.path.ecg.rectangle", description: Text(t("Connect to Zabbix to load active problems.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if problems.isEmpty {
            ContentUnavailableView(t("No active problems"), systemImage: "checkmark.circle", description: Text(t("Zabbix returned no active problems.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(problems) {
                TableColumn(t("Severity")) { problem in
                    Label(t(problem.severityName), systemImage: severitySymbol(problem.severity))
                        .foregroundStyle(severityColor(problem.severity))
                }.width(min: 120, ideal: 145)
                TableColumn(t("Problem")) { problem in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.name).lineLimit(2)
                        Text(tf("Event %@ · %@", problem.eventID, Fmt.dateTime(problem.occurredAt)))
                            .font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                    }
                }
                TableColumn(t("Host / target")) { problem in
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(problem.hosts) { host in
                            hostRow(problem: problem, host: host)
                        }
                        if problem.hosts.isEmpty { Text(t("No linked host")).foregroundStyle(palette.textSecondary) }
                    }
                }
                TableColumn(t("Operational data")) { problem in
                    Text(problem.operationalData.isEmpty ? "—" : problem.operationalData)
                        .lineLimit(2).foregroundStyle(palette.textSecondary)
                }
                TableColumn(t("Acknowledged")) { problem in
                    Text(problem.acknowledged ? t("Yes") : t("No"))
                }.width(min: 90, ideal: 110)
            }
            .accessibilityIdentifier("zabbixProblemTable")
        }
    }

    private func hostRow(problem: ZabbixProblem, host: ZabbixHost) -> some View {
        let key = pingKey(problem: problem, host: host)
        let isPingRunning = runningPingKeys.contains(key)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(host.displayName).lineLimit(1)
                if let target = host.target {
                    Text(target).font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                    Button { runPing(for: problem, host: host) } label: {
                        if isPingRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isPingRunning)
                    .help(t(isPingRunning ? "Ping in progress" : "Ping host and save evidence"))
                    .accessibilityLabel(t(isPingRunning ? "Ping in progress" : "Ping host"))
                    .accessibilityIdentifier("zabbixPing-\(problem.eventID)-\(host.hostID)")
                } else {
                    Text(t("No interface address")).font(.caption).foregroundStyle(palette.warning)
                }
            }
            if let feedback = pingFeedback[key] {
                HStack(spacing: 6) {
                    Image(systemName: diagnosticSymbol(feedback.status))
                        .foregroundStyle(diagnosticColor(feedback.status))
                    Text(feedbackTitle(feedback))
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("zabbixPingResult-\(problem.eventID)-\(host.hostID)")
                    if let latency = feedback.latency {
                        Text(Fmt.ms(latency)).font(.caption.monospaced())
                    }
                    Button { openDiagnosticHistory(problem.eventID) } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help(t("View event history"))
                    .accessibilityLabel(tf("View history for event %@", problem.eventID))
                    .accessibilityIdentifier("zabbixPingHistory-\(problem.eventID)-\(host.hostID)")
                }
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var tokenCredentials: [CredentialRef] {
        credentials.references.filter { $0.kind == .token }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var selectedCredential: CredentialRef? { tokenCredentials.first { $0.id.uuidString == selectedCredentialID } }
    private var validBaseURL: URL? {
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ZabbixConnectionPolicy.permits(url) else { return nil }
        return url
    }
    private var baseURLPolicyMessage: String {
        t("Enter an HTTPS Zabbix URL. HTTP is limited to loopback testing.")
    }
    private var canConnect: Bool { validBaseURL != nil && selectedCredential != nil }
    private var fetchedAt: Date? { lastFetchedAt }
    @NMStateCompat private var lastFetchedAt: Date?

    private var statusTitle: String {
        switch statusKind {
        case .idle: return t("Not connected")
        case .working: return t("Loading Zabbix problems…")
        case .success: return t("Zabbix problem queue ready")
        case .warning: return t("Action required")
        case .failure: return t("Zabbix request failed")
        }
    }
    private var statusSymbol: String {
        switch statusKind {
        case .idle: return "circle.dashed"
        case .working: return "arrow.triangle.2.circlepath.icloud"
        case .success: return "checkmark.icloud.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.icloud.fill"
        }
    }
    private var statusColor: Color {
        switch statusKind {
        case .idle: return palette.textSecondary
        case .working: return palette.info
        case .success: return palette.success
        case .warning: return palette.warning
        case .failure: return palette.danger
        }
    }

    private func refreshProblems() {
        guard let url = validBaseURL else {
            statusKind = .warning
            statusMessage = baseURLPolicyMessage
            return
        }
        guard let selectedCredential else {
            statusKind = .warning
            statusMessage = tokenCredentials.isEmpty ? t("No API token is available in Keychain.") : t("Select a Keychain API token before connecting.")
            return
        }
        do {
            guard let token = try credentials.secret(for: selectedCredential).token, !token.isEmpty else {
                statusKind = .warning
                statusMessage = t("The selected Keychain credential does not contain an API token.")
                return
            }
            let configuration = ZabbixConfiguration(baseURL: url, tokenReference: selectedCredential.id.uuidString)
            persist(configuration)
            let client = ZabbixClient(configuration: configuration, token: token)
            isWorking = true
            statusKind = .working
            statusMessage = ""
            Task {
                do {
                    problems = try await client.fetchActiveProblems()
                    lastFetchedAt = Date()
                    statusKind = .success
                    statusMessage = tf("%d active problem(s)", problems.count)
                } catch {
                    statusKind = .failure
                    statusMessage = errorMessage(error, token: token)
                }
                isWorking = false
            }
        } catch {
            statusKind = .failure
            statusMessage = error.localizedDescription
        }
    }

#if DEBUG
    private func loadLoopbackFixture() {
        let host = ZabbixHost(hostID: "fixture-loopback", technicalName: "loopback", displayName: t("Local loopback fixture"), target: "127.0.0.1")
        let problem = ZabbixProblem(
            eventID: "fixture-\(Int(Date().timeIntervalSince1970))",
            triggerID: "fixture-loopback-trigger",
            clock: Int(Date().timeIntervalSince1970),
            name: t("Local loopback diagnostic fixture"),
            severity: 3,
            acknowledged: false,
            operationalData: t("No external service was contacted."),
            hosts: [host]
        )
        problems = [problem]
        lastFetchedAt = Date()
        statusKind = .success
        statusMessage = t("Local loopback fixture loaded; no external service was contacted.")
    }
#endif

    private func validateBaseURLInput() {
        let hasInput = !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasInput, validBaseURL == nil else {
            if statusMessage == baseURLPolicyMessage {
                statusKind = .idle
                statusMessage = ""
            }
            return
        }
        statusKind = .warning
        statusMessage = baseURLPolicyMessage
    }

    private func runPing(for problem: ZabbixProblem, host: ZabbixHost) {
        let key = pingKey(problem: problem, host: host)
        guard runningPingKeys.insert(key).inserted else { return }
        pingFeedback.removeValue(forKey: key)
        Task {
            defer { runningPingKeys.remove(key) }
            guard let runID = await ZabbixDiagnosticRunner.ping(problem: problem, host: host, in: assets),
                  let run = assets.diagnosticRuns.first(where: { $0.id == runID }) else {
                pingFeedback[key] = PingFeedback(status: .failed, summary: t("No diagnostic record was returned."), latency: nil)
                return
            }
            pingFeedback[key] = PingFeedback(status: run.status, summary: run.summary, latency: run.latency)
        }
    }

    private func pingKey(problem: ZabbixProblem, host: ZabbixHost) -> String {
        "\(problem.eventID):\(host.hostID)"
    }

    private func diagnosticLabel(_ status: DiagnosticRunStatus) -> String {
        switch status {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .permissionDenied: return "Permission denied"
        case .unreachable: return "Unreachable"
        }
    }

    private func feedbackTitle(_ feedback: PingFeedback) -> String {
        let state = t(diagnosticLabel(feedback.status))
        let summary = feedback.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return state }
        if summary.localizedCaseInsensitiveCompare(state) == .orderedSame
            || (feedback.status == .succeeded && summary.localizedCaseInsensitiveCompare(t("Success")) == .orderedSame) {
            return state
        }
        return "\(state) · \(summary)"
    }

    private func diagnosticSymbol(_ status: DiagnosticRunStatus) -> String {
        switch status {
        case .running: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        case .timedOut: return "clock.badge.exclamationmark"
        case .permissionDenied: return "lock.fill"
        case .unreachable: return "wifi.slash"
        }
    }

    private func diagnosticColor(_ status: DiagnosticRunStatus) -> Color {
        switch status {
        case .succeeded: return palette.success
        case .running, .interrupted, .cancelled, .timedOut: return palette.warning
        case .failed, .permissionDenied, .unreachable: return palette.danger
        }
    }

    private func severitySymbol(_ severity: Int) -> String {
        severity >= 4 ? "exclamationmark.triangle.fill" : severity >= 2 ? "exclamationmark.circle" : "info.circle"
    }
    private func severityColor(_ severity: Int) -> Color {
        severity >= 5 ? palette.danger : severity >= 3 ? palette.warning : palette.info
    }
    private func safeMessage(_ value: String, token: String) -> String {
        value.replacingOccurrences(of: token, with: "••••••")
    }
    private func errorMessage(_ error: Error, token: String) -> String {
        if let value = error as? ZabbixError, case .timeout = value {
            return t("The Zabbix request timed out. Check the URL and network path, then retry.")
        }
        return safeMessage(error.localizedDescription, token: token)
    }
    private func persistConfiguration(_ configuration: ZabbixConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration), let value = String(data: data, encoding: .utf8) else { return }
        SettingsStore.shared.setString("zabbix.connection", value)
    }
    private func persistConfiguration() {
        guard let url = validBaseURL else { return }
        persistConfiguration(ZabbixConfiguration(baseURL: url, tokenReference: selectedCredentialID.isEmpty ? nil : selectedCredentialID))
    }
    private func persist(_ configuration: ZabbixConfiguration) { persistConfiguration(configuration) }
    private static func savedConfiguration() -> ZabbixConfiguration? {
        let raw = SettingsStore.shared.string("zabbix.connection", default: "")
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ZabbixConfiguration.self, from: data)
    }
}
