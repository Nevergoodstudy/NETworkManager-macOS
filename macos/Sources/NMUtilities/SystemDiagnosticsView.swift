import SwiftUI
import NMCore

@MainActor
public struct SystemDiagnosticsView: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case wifi, connections, listeners, neighbors, firewall, discovery
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .wifi: return "WiFi"
            case .connections: return "Connections"
            case .listeners: return "Listeners"
            case .neighbors: return "Neighbor Table"
            case .firewall: return "Firewall"
            case .discovery: return "Discovery Protocol"
            }
        }
    }

    @Environment(\.palette) private var palette
    @NMStateCompat private var kind: Kind
    @NMStateCompat private var socketResult: SocketInventoryResult?
    @NMStateCompat private var neighborResult: SystemInventoryResult<NeighborEntry>?
    @NMStateCompat private var wifiResult: SystemInventoryResult<WiFiSummary>?
    @NMStateCompat private var output = ""
    @NMStateCompat private var error: String?
    @NMStateCompat private var isLoading = false
    @NMStateCompat private var refreshTask: Task<Void, Never>?
    @NMStateCompat private var requestID: UUID?

    public init(kind: Kind = .wifi) { _kind = NMStateCompat(wrappedValue: kind) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t(kind.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Tool"), selection: $kind) {
                    ForEach(Kind.allCases) { Text(t($0.title)).tag($0) }
                }.pickerStyle(.menu)
                Button(isLoading ? t("Loading…") : t("Refresh")) { reload() }
                    .buttonStyle(.bordered).disabled(isLoading)
                    .accessibilityIdentifier("systemDiagnosticsRefresh")
                if isLoading {
                    Button(t("Cancel")) { refreshTask?.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(socketScope == nil ? "systemDiagnosticsCancel" : "socketInventoryCancel")
                }
            }
            if let error { Text(error).foregroundStyle(palette.danger) }
            content
            Spacer()
        }
        .padding(28)
        .background(palette.background)
        .task { reload() }
        .onChange(of: kind) { _, _ in reload() }
        .onDisappear { stopRefreshing() }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .connections, .listeners:
            VStack(alignment: .leading, spacing: 12) {
                Text(t("Only sockets visible to the current account are shown. macOS may hide connections owned by other processes."))
                    .font(.callout).foregroundStyle(.secondary)
                if isLoading {
                    ProgressView(t("Reading visible sockets…"))
                        .frame(maxWidth: .infinity, minHeight: 420)
                        .accessibilityIdentifier("socketInventoryLoading")
                } else if let socketResult {
                    SocketInventoryResultsView(result: socketResult, scope: socketScope ?? .connections)
                } else {
                    Text(t("Refresh to read visible sockets."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
        case .neighbors:
            if isLoading {
                ProgressView(t("Reading the neighbor table…"))
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else if let neighborResult {
                capturePanel(result: neighborResult) {
                    if neighborResult.entries.isEmpty {
                        ContentUnavailableView(t(emptyMessage(for: neighborResult.state, kind: .neighbors)),
                                               systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(minHeight: 320)
                    } else {
                        Table(neighborResult.entries) {
                            TableColumn(t("Address")) { Text($0.address).font(.body.monospaced()) }
                            TableColumn(t("MAC address")) { Text($0.macAddress.isEmpty ? "--" : $0.macAddress).font(.body.monospaced()) }
                            TableColumn(t("Interface")) { Text($0.interface) }
                            TableColumn(t("Status")) { Text(t($0.state)) }
                        }.frame(minHeight: 420)
                    }
                }
            } else {
                Text(t("Refresh to read the neighbor table.")).foregroundStyle(.secondary)
            }
        case .wifi:
            if isLoading {
                ProgressView(t("Reading Wi-Fi details…"))
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else if let wifiResult {
                capturePanel(result: wifiResult) {
                    if wifiResult.entries.isEmpty {
                        ContentUnavailableView(t(emptyMessage(for: wifiResult.state, kind: .wifi)),
                                               systemImage: "wifi.slash")
                            .frame(minHeight: 320)
                    } else {
                        Table(wifiResult.entries) {
                            TableColumn(t("Interface")) { Text($0.interface) }
                            TableColumn(t("Network")) { Text($0.ssid) }
                            TableColumn("BSSID") { Text($0.bssid).font(.body.monospaced()) }
                            TableColumn(t("Channel")) { Text($0.channel) }
                            TableColumn(t("Security")) { Text($0.security) }
                            TableColumn(t("Signal")) { Text($0.signal) }
                        }.frame(minHeight: 420)
                    }
                }
            } else {
                Text(t("Refresh to read Wi-Fi details.")).foregroundStyle(.secondary)
            }
        case .firewall, .discovery:
            ScrollView {
                Text(output.isEmpty ? t("Nothing to show") : output)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.background(palette.card, in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 420)
        }
    }

    @ViewBuilder
    private func capturePanel<Entry: Sendable, Content: View>(
        result: SystemInventoryResult<Entry>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            captureSummary(result)
            if !result.issues.isEmpty { captureDetails(result) }
            content()
        }
    }

    private func captureSummary<Entry: Sendable>(_ result: SystemInventoryResult<Entry>) -> some View {
        let title: String
        let color: Color
        switch result.state {
        case .loaded:
            title = tf("Returned %d record(s).", result.entries.count)
            color = .secondary
        case .empty:
            title = "The command completed without returning records."
            color = .secondary
        case .partial:
            title = "System network data may be incomplete."
            color = palette.warning
        case .unavailable:
            title = "System network data is unavailable."
            color = palette.danger
        case .limited:
            title = "Some requested system network fields were not provided."
            color = palette.warning
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(result.state == .loaded ? title : t(title)).font(.headline).foregroundStyle(color)
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                Text(t(captureMessage(for: issue))).font(.callout).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("systemInventoryStatus")
    }

    private func captureDetails<Entry: Sendable>(_ result: SystemInventoryResult<Entry>) -> some View {
        DisclosureGroup(t("Collection details")) {
            VStack(alignment: .leading, spacing: 8) {
                if result.command.status >= 0 {
                    Text(tf("Command exit status: %d", result.command.status))
                }
                if result.unrecognizedRecordCount > 0 {
                    Text(tf("Unrecognized output line(s): %d", result.unrecognizedRecordCount))
                }
                if !result.command.stderr.isEmpty {
                    ScrollView {
                        Text(result.command.stderr).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 160)
                }
            }
            .font(.callout).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("systemInventoryDetails")
    }

    private func captureMessage(for issue: SystemInventoryIssue) -> String {
        switch issue {
        case .missingExecutable: return "The required macOS command could not be found."
        case .permissionDenied: return "macOS denied permission to start the command."
        case .busy: return "The command runner is busy. Try refreshing shortly."
        case .launchFailed: return "The system network command could not be started."
        case .executionFailed: return "The system network command exited with an error."
        case .timedOut: return "System network collection timed out."
        case .cancelled: return "System network collection was cancelled."
        case .outputTruncated: return "The collection reached its output limit; some data was discarded."
        case .cleanupIncomplete: return "The command did not finish cleanup. This result may be incomplete."
        case .commandWarning: return "The command reported a message. See collection details."
        case .unrecognizedOutput: return "Some command output could not be read."
        case .fieldsUnavailable: return "Some requested system network fields were not provided."
        }
    }

    private func emptyMessage(for state: SystemInventoryState, kind: Kind) -> String {
        switch (kind, state) {
        case (.neighbors, .empty): return "No neighbor entries were returned."
        case (.neighbors, .unavailable): return "The neighbor table could not be read."
        case (.neighbors, .partial): return "No complete neighbor entries could be read."
        case (.neighbors, .limited): return "Some neighbor details were not provided."
        case (.wifi, .empty): return "No Wi-Fi entries were returned."
        case (.wifi, .unavailable): return "Wi-Fi data could not be read."
        case (.wifi, .partial): return "Wi-Fi data is incomplete."
        case (.wifi, .limited): return "Some Wi-Fi fields were not provided."
        default: return "No records were returned."
        }
    }

    private var socketScope: SocketInventoryScope? {
        switch kind {
        case .connections: return .connections
        case .listeners: return .listeners
        default: return nil
        }
    }

    private func stopRefreshing() {
        requestID = nil
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }

    private func reload() {
        refreshTask?.cancel()
        let id = UUID()
        requestID = id
        isLoading = true
        error = nil
        socketResult = nil
        output = ""
        neighborResult = nil
        wifiResult = nil
        let selected = kind
        refreshTask = Task { @MainActor in
            defer {
                if requestID == id {
                    refreshTask = nil
                    isLoading = false
                }
            }
            switch selected {
            case .connections, .listeners:
                let scope: SocketInventoryScope = selected == .listeners ? .listeners : .connections
                let value = await SocketInventory.collect(scope: scope)
                guard requestID == id, kind == selected else { return }
                socketResult = value
            case .neighbors:
                let value = await NeighborTable.collect()
                guard requestID == id, kind == selected else { return }
                neighborResult = value
            case .wifi:
                let value = await WiFiInventory.collect()
                guard requestID == id, kind == selected else { return }
                wifiResult = value
            case .firewall:
                let result = await Shell.runTool("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate", "--listapps"], timeout: 20)
                guard requestID == id, kind == selected else { return }
                output = result.output
                error = result.succeeded ? nil : result.output
            case .discovery:
                let result = await Shell.runTool("lldpcli", ["show", "neighbors", "-f", "keyvalue"], timeout: 20)
                guard requestID == id, kind == selected else { return }
                output = result.succeeded ? result.output : result.output + "\n\n" + t("Install lldpd with Homebrew to enable LLDP/CDP discovery.")
            }
        }
    }
}

