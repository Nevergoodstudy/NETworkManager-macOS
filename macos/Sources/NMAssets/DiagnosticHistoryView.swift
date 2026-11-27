import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NMCore

public struct DiagnosticHistoryView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var assets = AssetStore.shared
    @StateObject private var filters: Filters
    @NMStateCompat private var pagePosition = PagePosition()
    @NMStateCompat private var loadedPage: LoadedPage?
    @NMStateCompat private var pageError: String?
    @NMStateCompat private var retry = 0
    @NMStateCompat private var exportData = Data()
    @NMStateCompat private var exportMarkdown = true
    @NMStateCompat private var showingExporter = false
    @NMStateCompat private var isExporting = false
    @NMStateCompat private var selectedRerun: DiagnosticRun?

    private struct PageRequest: Equatable {
        let filter: DiagnosticHistorySearch.Filter
        let index: Int
        let revision: Int
        let retry: Int
    }

    private final class Filters: ObservableObject {
        @Published var search: String
        @Published var workspaceID = "all"
        @Published var kind = "all"
        @Published var period = "all"

        init(search: String) { self.search = search }
    }

    private struct PagePosition {
        var filter: DiagnosticHistorySearch.Filter?
        var index = 0
    }

    private struct LoadedPage {
        let request: PageRequest
        let runs: [DiagnosticRun]
    }

    private var filter: DiagnosticHistorySearch.Filter {
        DiagnosticHistorySearch.Filter(workspaceID: UUID(uuidString: filters.workspaceID),
                                       kind: DiagnosticKind(rawValue: filters.kind),
                                       days: filters.period == "day" ? 1 : filters.period == "week" ? 7 : nil,
                                       text: filters.search)
    }

    private var request: PageRequest {
        let filter = self.filter
        return PageRequest(filter: filter, index: pagePosition.filter == filter ? pagePosition.index : 0,
                           revision: assets.diagnosticHistoryRevision, retry: retry)
    }

    public init(initialEventID: String? = nil) {
        _filters = StateObject(wrappedValue: Filters(search: initialEventID ?? ""))
    }

    public var body: some View {
        let request = self.request
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(t("Filter by device, target or result"), text: $filters.search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("diagnosticHistorySearch")
                Picker(t("Workspace"), selection: $filters.workspaceID) {
                    Text(t("All workspaces")).tag("all")
                    ForEach(assets.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id.uuidString)
                    }
                }
                .frame(width: 180)
                .accessibilityIdentifier("diagnosticHistoryWorkspaceFilter")
                Picker(t("Check"), selection: $filters.kind) {
                    Text(t("All checks")).tag("all")
                    ForEach(DiagnosticKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .frame(width: 150)
                Picker(t("Period"), selection: $filters.period) {
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
                .disabled(isExporting || assets.isLoadingWorkspace)
                .help(t("Export filtered evidence"))
            }
            .padding(14)
            Divider()
            if let persistenceError = assets.persistenceError {
                Label(persistenceError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if assets.isLoadingWorkspace {
                ProgressView(t("Loading…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pageError {
                ContentUnavailableView {
                    Label(t("Could not load diagnostic history"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(pageError)
                } actions: {
                    Button(t("Retry")) { retry += 1 }
                }
            } else if let loadedPage, loadedPage.request == request {
                if loadedPage.runs.isEmpty {
                    ContentUnavailableView(t("No matching diagnostics"), systemImage: "waveform.path.ecg", description: Text(t("Completed checks and standalone lookups will appear here.")))
                } else {
                    List(Array(loadedPage.runs.prefix(50))) { run in
                        row(run)
                    }
                    .listStyle(.plain)
                    Divider()
                    HStack {
                        Spacer()
                        Button(t("Previous page")) {
                            pagePosition = PagePosition(filter: request.filter, index: request.index - 1)
                        }
                        .disabled(request.index == 0)
                        Text(String(request.index + 1)).monospacedDigit()
                        Button(t("Next page")) {
                            pagePosition = PagePosition(filter: request.filter, index: request.index + 1)
                        }
                            .disabled(loadedPage.runs.count <= 50)
                    }
                    .padding(10)
                }
            } else {
                ProgressView(t("Loading…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.background)
        .navigationTitle(t("Diagnostic history"))
        .task(id: request) { await load(request) }
        .sheet(item: $selectedRerun) { run in
            VStack(spacing: 0) {
                if let deviceID = run.deviceID, let device = assets.devices.first(where: { $0.id == deviceID }) {
                    DeviceInspector(device: device, rerun: run)
                        .frame(minWidth: 760, minHeight: 560)
                } else {
                    ContentUnavailableView(t("Unknown device"), systemImage: "desktopcomputer", description: Text(t("This device was removed, so the diagnostic cannot be repeated.")))
                        .frame(minWidth: 420, minHeight: 200)
                }
                Divider()
                Button(t("Close")) { selectedRerun = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeDiagnosticRerun")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(12)
            }
            .background(RerunSheetWindow())
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: HistoryEvidenceDocument(data: exportData),
            contentType: exportMarkdown ? .plainText : .json,
            defaultFilename: exportMarkdown ? "NETworkManager-diagnostics.md" : "NETworkManager-diagnostics.json"
        ) { _ in }
    }

    private func load(_ request: PageRequest) async {
        guard !assets.isLoadingWorkspace, request == self.request, !Task.isCancelled else { return }
        pageError = nil
        if request.index == 0 { pagePosition = PagePosition(filter: request.filter) }
        do {
            let runs = try await assets.diagnosticHistoryPage(request.filter, offset: request.index * 50)
            guard request == self.request, !Task.isCancelled else { return }
            if runs.isEmpty && request.index > 0 {
                pagePosition = PagePosition(filter: request.filter)
                return
            }
            loadedPage = LoadedPage(request: request, runs: runs)
        } catch {
            guard request == self.request, !Task.isCancelled else { return }
            pageError = error.localizedDescription
        }
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
        let filter = self.filter
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                exportData = try await assets.exportDiagnosticHistory(filter, markdown: markdown)
                exportMarkdown = markdown
                showingExporter = true
            } catch {
                NSSound.beep()
            }
        }
    }
}

private struct RerunSheetWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> SheetView { SheetView() }

    func updateNSView(_ view: SheetView, context: Context) {}

    final class SheetView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
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
