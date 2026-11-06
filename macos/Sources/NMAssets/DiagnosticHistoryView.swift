import SwiftUI
import UniformTypeIdentifiers
import NMCore

public struct DiagnosticHistoryView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var assets = AssetStore.shared
    @NMStateCompat private var search = ""
    @NMStateCompat private var selectedWorkspaceID = "all"
    @NMStateCompat private var selectedKind = "all"
    @NMStateCompat private var selectedPeriod = "all"
    @NMStateCompat private var exportData = Data()
    @NMStateCompat private var exportMarkdown = true
    @NMStateCompat private var showingExporter = false
    @NMStateCompat private var selectedRerun: DiagnosticRun?

    public init(initialEventID: String? = nil) {
        _search = NMStateCompat(wrappedValue: initialEventID ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(t("Filter by device, target or result"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("diagnosticHistorySearch")
                Picker(t("Workspace"), selection: $selectedWorkspaceID) {
                    Text(t("All workspaces")).tag("all")
                    ForEach(assets.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id.uuidString)
                    }
                }
                .frame(width: 180)
                .accessibilityIdentifier("diagnosticHistoryWorkspaceFilter")
                Picker(t("Check"), selection: $selectedKind) {
                    Text(t("All checks")).tag("all")
                    ForEach(DiagnosticKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .frame(width: 150)
                Picker(t("Period"), selection: $selectedPeriod) {
                    Text(t("All time")).tag("all")
                    Text(t("Last 24 hours")).tag("day")
                    Text(t("Last 7 days")).tag("week")
                }
                .frame(width: 160)
                Menu {
                    Button { export(markdown: true) } label: { Label(t("Export Markdown"), systemImage: "doc.richtext") }
                    Button { export(markdown: false) } label: { Label(t("Export JSON"), systemImage: "curlybraces.square") }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(t("Export filtered evidence"))
            }
            .padding(14)
            Divider()
            if filteredRuns.isEmpty {
                ContentUnavailableView(t("No matching diagnostics"), systemImage: "waveform.path.ecg", description: Text(t("Completed checks and standalone lookups will appear here.")))
            } else {
                List(filteredRuns) { run in
                    row(run)
                }
                .listStyle(.plain)
            }
        }
        .background(palette.background)
        .navigationTitle(t("Diagnostic history"))
        .sheet(item: $selectedRerun) { run in
            if let deviceID = run.deviceID, let device = assets.devices.first(where: { $0.id == deviceID }) {
                DeviceInspector(device: device, rerun: run)
                    .frame(minWidth: 760, minHeight: 600)
            } else {
                ContentUnavailableView(t("Unknown device"), systemImage: "desktopcomputer", description: Text(t("This device was removed, so the diagnostic cannot be repeated.")))
                    .frame(minWidth: 420, minHeight: 240)
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: HistoryEvidenceDocument(data: exportData),
            contentType: exportMarkdown ? .plainText : .json,
            defaultFilename: exportMarkdown ? "NETworkManager-diagnostics.md" : "NETworkManager-diagnostics.json"
        ) { _ in }
    }

    private var filteredRuns: [DiagnosticRun] {
        let cutoff: Date?
        switch selectedPeriod {
        case "day": cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        case "week": cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        default: cutoff = nil
        }
        let workspaceRuns: [DiagnosticRun]
        if selectedWorkspaceID == "all" {
            workspaceRuns = assets.diagnosticRuns
        } else if let workspaceID = UUID(uuidString: selectedWorkspaceID) {
            workspaceRuns = assets.runs(in: workspaceID)
        } else {
            workspaceRuns = []
        }
        return workspaceRuns
            .filter { run in
                (selectedKind == "all" || run.kind.rawValue == selectedKind)
                    && (cutoff == nil || run.startedAt >= cutoff!)
                    && matches(run)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func matches(_ run: DiagnosticRun) -> Bool {
        guard !search.isEmpty else { return true }
        let device = run.deviceID.flatMap { id in assets.devices.first { $0.id == id } }
        let site = device.flatMap { device in assets.sites.first { $0.id == device.siteID } }
        let workspace = site.flatMap { site in assets.workspaces.first { $0.id == site.workspaceID } }
        return [device?.name ?? "", device?.address ?? "", site?.name ?? "", workspace?.name ?? "", run.target ?? "", run.summary, run.detail]
            .contains { $0.localizedCaseInsensitiveContains(search) }
            || DiagnosticHistorySearch.matches(run, query: search)
    }

    private func row(_ run: DiagnosticRun) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(run.status))
                .foregroundStyle(color(run.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(deviceName(run)) · \(run.kind.displayName) · \(label(run.status))")
                    .font(.callout.weight(.medium))
                Text("\(run.summary) · \(run.target ?? deviceAddress(run))")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                Text("\(Fmt.dateTime(run.startedAt)) · \(run.source)")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            if let latency = run.latency { Text(Fmt.ms(latency)).font(.caption.monospaced()) }
            if let deviceID = run.deviceID, assets.devices.contains(where: { $0.id == deviceID }) {
                Button { selectedRerun = run } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(t("Repeat with saved parameters"))
                    .accessibilityLabel(t("Repeat diagnostic"))
                    .accessibilityIdentifier("repeatDiagnostic-\(run.id.uuidString)")
            }
        }
        .padding(.vertical, 4)
    }

    private func deviceName(_ run: DiagnosticRun) -> String {
        guard let deviceID = run.deviceID else { return t("Standalone check") }
        return assets.devices.first { $0.id == deviceID }?.name ?? t("Unknown device")
    }
    private func deviceAddress(_ run: DiagnosticRun) -> String {
        guard let deviceID = run.deviceID else { return run.target ?? "—" }
        return assets.devices.first { $0.id == deviceID }?.address ?? run.target ?? "—"
    }

    private func symbol(_ status: DiagnosticRunStatus) -> String {
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

    private func color(_ status: DiagnosticRunStatus) -> Color {
        switch status {
        case .succeeded: return palette.success
        case .interrupted: return palette.warning
        case .running, .cancelled, .timedOut: return palette.warning
        case .failed, .permissionDenied, .unreachable: return palette.danger
        }
    }

    private func label(_ status: DiagnosticRunStatus) -> String {
        switch status {
        case .running: return t("Running")
        case .succeeded: return t("Succeeded")
        case .failed: return t("Failed")
        case .interrupted: return t("Interrupted")
        case .cancelled: return t("Cancelled")
        case .timedOut: return t("Timed out")
        case .permissionDenied: return t("Permission denied")
        case .unreachable: return t("Unreachable")
        }
    }

    private func export(markdown: Bool) {
        do {
            exportMarkdown = markdown
            exportData = markdown
                ? Data(DiagnosticEvidenceExporter.markdown(runs: filteredRuns, devices: assets.devices).utf8)
                : try DiagnosticEvidenceExporter.json(runs: filteredRuns, devices: assets.devices)
            showingExporter = true
        } catch {
            NSSound.beep()
        }
    }
}

private struct HistoryEvidenceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
