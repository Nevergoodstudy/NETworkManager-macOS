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
    @NMStateCompat private var neighbors: [NeighborEntry] = []
    @NMStateCompat private var wifi: [WiFiSummary] = []
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
                if isLoading && socketScope != nil {
                    Button(t("Cancel")) { refreshTask?.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("socketInventoryCancel")
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
            Table(neighbors) {
                TableColumn(t("Address")) { Text($0.address).font(.body.monospaced()) }
                TableColumn(t("MAC address")) { Text($0.macAddress).font(.body.monospaced()) }
                TableColumn(t("Interface")) { Text($0.interface) }
                TableColumn(t("Status")) { Text($0.state) }
            }.frame(minHeight: 420)
        case .wifi:
            if wifi.isEmpty {
                ScrollView { Text(output.isEmpty ? t("No WiFi data was returned by macOS.") : output)
                        .font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 420)
            } else {
                Table(wifi) {
                    TableColumn(t("Interface")) { Text($0.interface) }
                    TableColumn(t("Network")) { Text($0.ssid) }
                    TableColumn("BSSID") { Text($0.bssid).font(.body.monospaced()) }
                    TableColumn(t("Channel")) { Text($0.channel) }
                    TableColumn(t("Security")) { Text($0.security) }
                    TableColumn(t("Signal")) { Text($0.signal) }
                }.frame(minHeight: 420)
            }
        case .firewall, .discovery:
            ScrollView {
                Text(output.isEmpty ? t("Nothing to show") : output)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.background(palette.card, in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 420)
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
        neighbors = []
        wifi = []
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
                let value = await Task.detached { NeighborTable.list() }.value
                guard requestID == id, kind == selected else { return }
                neighbors = value
            case .wifi:
                let value = await Task.detached { WiFiInventory.current() }.value
                guard requestID == id, kind == selected else { return }
                wifi = value
                output = value.first?.raw ?? ""
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

