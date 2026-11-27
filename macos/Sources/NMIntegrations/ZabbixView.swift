import SwiftUI
import NMCore
import NMAssets

public struct ZabbixView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @ObservedObject private var assets = AssetStore.shared
    private let openDiagnosticHistory: (String) -> Void
    private let stageMetric: ((FieldMetricObservation) -> Void)?

    @NMStateCompat private var baseURLText: String
    @NMStateCompat private var selectedCredentialID: String
    @NMStateCompat private var problems: [ZabbixProblem] = []
    @NMStateCompat private var isWorking = false
    @NMStateCompat private var statusMessage = ""
    @NMStateCompat private var statusKind: StatusKind = .idle
    @NMStateCompat private var pingTasks: [String: Task<Void, Never>] = [:]
    @NMStateCompat private var pingFeedback: [String: PingFeedback] = [:]
    @NMStateCompat private var problemConfiguration: ZabbixConfiguration?
    @NMStateCompat private var metricPreview: ZabbixMetricPreview.Context?

    private enum StatusKind { case idle, working, success, warning, failure }

    private struct PingFeedback {
        let status: DiagnosticRunStatus
        let summary: String
        let latency: TimeInterval?
    }

    public init(openDiagnosticHistory: @escaping (String) -> Void = { _ in },
                stageMetric: ((FieldMetricObservation) -> Void)? = nil) {
        let saved = Self.savedConfiguration()
        self.openDiagnosticHistory = openDiagnosticHistory
        self.stageMetric = stageMetric
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
        .sheet(item: $metricPreview) { context in
            ZabbixMetricPreview(context: context, stageMetric: stageMetric.map { stage in
                { observation in
                    stage(observation)
                    statusKind = .success
                    statusMessage = t("Metric prepared. Select an incident in a field project.")
                }
            })
        }
        .onChange(of: baseURLText) { _, _ in
            invalidateMetricSource()
            persistConfiguration()
            validateBaseURLInput()
        }
        .onChange(of: selectedCredentialID) { _, _ in
            invalidateMetricSource()
            persistConfiguration()
        }
        .onAppear { validateBaseURLInput() }
        .onDisappear { for task in pingTasks.values { task.cancel() } }
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
        let isPingRunning = pingTasks[key] != nil
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
                    .disabled(isPingRunning || assets.isLoadingWorkspace)
                    .help(t(isPingRunning ? "Ping in progress" : "Ping host and save evidence"))
                    .accessibilityLabel(t(isPingRunning ? "Ping in progress" : "Ping host"))
                    .accessibilityIdentifier("zabbixPing-\(problem.eventID)-\(host.hostID)")
                } else {
                    Text(t("No interface address")).font(.caption).foregroundStyle(palette.warning)
                }
                Button { openMetricPreview(for: problem, host: host) } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .buttonStyle(.borderless)
                .disabled(problemConfiguration == nil || problem.clock <= 0 || isWorking)
                .help(t(problem.clock > 0 ? "Metric history" : "The Zabbix problem has an invalid timestamp."))
                .accessibilityLabel(t("Metric history"))
                .accessibilityIdentifier("zabbixMetricHistory-\(problem.eventID)-\(host.hostID)")
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
            invalidateMetricSource()
            persist(configuration)
            let client = ZabbixClient(configuration: configuration, token: token)
            isWorking = true
            statusKind = .working
            statusMessage = ""
            Task {
                do {
                    problems = try await client.fetchActiveProblems()
                    if validBaseURL == configuration.baseURL, self.selectedCredential?.id.uuidString == configuration.tokenReference {
                        problemConfiguration = configuration
                    }
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
        invalidateMetricSource()
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

    private func invalidateMetricSource() {
        problemConfiguration = nil
        metricPreview = nil
    }

    private func openMetricPreview(for problem: ZabbixProblem, host: ZabbixHost) {
        guard let configuration = problemConfiguration, configuration.baseURL == validBaseURL,
              let selectedCredential, configuration.tokenReference == selectedCredential.id.uuidString else { return }
        do {
            let token = try credentials.secret(for: selectedCredential).token
            let client = ZabbixClient(configuration: configuration, token: token)
            metricPreview = ZabbixMetricPreview.Context(client: client, problem: problem, host: host)
        } catch {
            statusKind = .failure
            statusMessage = error.localizedDescription
        }
    }

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
        guard pingTasks[key] == nil, !assets.isLoadingWorkspace else { return }
        let task = ProcessRuntime.startDiagnosticTask(DiagnosticCancellation()) {
            defer { pingTasks[key] = nil }
            guard let runID = await ZabbixDiagnosticRunner.ping(problem: problem, host: host, in: assets),
                  let run = assets.diagnosticRuns.first(where: { $0.id == runID }) else {
                pingFeedback[key] = PingFeedback(status: .failed, summary: t("No diagnostic record was returned."), latency: nil)
                return
            }
            pingFeedback[key] = PingFeedback(status: run.status, summary: run.summary, latency: run.latency)
        }
        guard let task else { return }
        pingFeedback.removeValue(forKey: key)
        pingTasks[key] = task
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

private struct ZabbixMetricPreview: View {
    struct Context: Identifiable {
        let id = UUID()
        let client: ZabbixClient
        let problem: ZabbixProblem
        let host: ZabbixHost
    }

    private struct Query: Hashable {
        var metricID = ""
        var window = ZabbixMetricHistory.Window.fifteen
        var revision = 0
    }

    private struct SampleRow: Identifiable { let id: Int }

    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var metrics: Result<[ZabbixMetric], Error>?
    @NMStateCompat private var query = Query()
    @NMStateCompat private var history: (query: Query, result: Result<ZabbixMetricHistory, Error>)?
    let context: Context
    let stageMetric: ((FieldMetricObservation) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Metric history")).font(.headline)
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            LabeledContent(t("Source"), value: context.client.configuration.baseURL.absoluteString)
            LabeledContent(t("Host"), value: "\(context.host.displayName) · \(context.host.hostID)")
            Text(tf("Event %@ · %@", context.problem.eventID, Fmt.dateTime(context.problem.occurredAt)))
            Divider()
            switch metrics {
            case nil: ProgressView()
            case .failure(let error): errorLabel(error)
            case .success(let items) where items.isEmpty: Text(t("Zabbix returned no visible numeric items."))
            case .success(let items): metricContent(items)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 440)
        .task {
            do { metrics = .success(try await context.client.fetchNumericMetrics(for: context.host)) }
            catch { if !Task.isCancelled { metrics = .failure(error) } }
        }
    }

    private func metricContent(_ items: [ZabbixMetric]) -> some View {
        let selection = query
        let metric = items.first { $0.id == selection.metricID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(t("Monitoring item"), selection: $query.metricID) {
                    Text(t("Select a monitoring item")).tag("")
                    ForEach(items) { Text("\($0.name) · \($0.key)").tag($0.id) }
                }
                Picker(t("Minutes on each side"), selection: $query.window) {
                    ForEach(ZabbixMetricHistory.Window.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                }
                .fixedSize()
                Button { query.revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help(t("Refresh")).accessibilityLabel(t("Refresh")).disabled(metric == nil)
            }
            if let metric {
                Text(metric.key).font(.caption.monospaced()).textSelection(.enabled)
                HStack(spacing: 24) {
                    LabeledContent(t("Unit"), value: metric.units.isEmpty ? "–" : metric.units)
                    LabeledContent(t("Configured interval"), value: metric.delay.isEmpty ? "–" : metric.delay)
                }
                switch history?.query == selection ? history?.result : nil {
                case nil: ProgressView()
                case .failure(let error): errorLabel(error)
                case .success(let result):
                    historyContent(result)
                    if let stageMetric {
                        Button(t("Prepare metric attachment"), systemImage: "paperclip") {
                            guard query == selection else { return }
                            stageMetric(context.client.metricObservation(for: metric, history: result,
                                                                         problem: context.problem, host: context.host))
                            dismiss()
                        }
                        .accessibilityIdentifier("zabbixPrepareMetric")
                    }
                }
            }
        }
        .task(id: selection) {
            guard let metric else { return }
            let result: Result<ZabbixMetricHistory, Error>
            do {
                result = .success(try await context.client.fetchMetricHistory(for: metric, problem: context.problem, window: selection.window))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, query == selection else { return }
            history = (selection, result)
        }
    }

    private func historyContent(_ result: ZabbixMetricHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Fmt.dateTime(Date(timeIntervalSince1970: Double(result.range.lowerBound)))) – \(Fmt.dateTime(Date(timeIntervalSince1970: Double(result.range.upperBound)))) · \(TimeZone.current.identifier)")
                .font(.caption.monospaced())
            if result.afterWindowOpen { Text(t("Post-alert window was still open at query time.")) }
            if result.beforeOrAtLimitReached { Text(t("History at or before the alert was truncated.")) }
            if result.afterLimitReached { Text(t("History after the alert was truncated.")) }
            if result.samples.isEmpty { Text(t("Zabbix returned no samples in this window.")) }
            if !result.samples.isEmpty {
                Table(result.samples.indices.map { SampleRow(id: $0) }) {
                    TableColumn(t("Timestamp")) { row in
                        let sample = result.samples[row.id]
                        let time = Fmt.dateTime(Date(timeIntervalSince1970: Double(sample.seconds)))
                        Text(time + String(format: ".%09d", sample.nanoseconds)).monospacedDigit()
                    }.width(min: 218)
                    TableColumn(t("Alert phase")) { row in
                        let seconds = result.samples[row.id].seconds
                        Text(t(seconds < context.problem.clock ? "Before alert" : seconds == context.problem.clock ? "Alert second" : "After alert"))
                    }
                    TableColumn(t("Value")) { row in
                        Text(result.samples[row.id].rawValue).monospacedDigit().textSelection(.enabled)
                    }.width(min: 140)
                    TableColumn(t("Since previous sample")) { row in
                        if row.id > 0 {
                            let sample = result.samples[row.id]
                            let previous = result.samples[row.id - 1]
                            let delta = Double(sample.seconds - previous.seconds)
                                + Double(sample.nanoseconds - previous.nanoseconds) / 1_000_000_000
                            Text(Fmt.duration(delta)).monospacedDigit()
                        }
                        if row.id == 0 { Text("–") }
                    }
                }.frame(minHeight: 180)
            }
        }
    }

    private func errorLabel(_ error: Error) -> some View {
        let denied = (error as? ZabbixError)?.isAccessDenied == true
        return Label(denied ? t("Permission denied") : t("Zabbix request failed"), systemImage: denied ? "lock" : "exclamationmark.triangle")
            .help(t(error.localizedDescription)).accessibilityHint(t(error.localizedDescription))
    }
}
