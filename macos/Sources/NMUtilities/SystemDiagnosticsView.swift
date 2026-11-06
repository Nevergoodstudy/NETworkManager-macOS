import SwiftUI
import NMCore

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
    @NMStateCompat private var sockets: [SocketEntry] = []
    @NMStateCompat private var neighbors: [NeighborEntry] = []
    @NMStateCompat private var wifi: [WiFiSummary] = []
    @NMStateCompat private var output = ""
    @NMStateCompat private var error: String?
    @NMStateCompat private var isLoading = false

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
            }
            if let error { Text(error).foregroundStyle(palette.danger) }
            content
            Spacer()
        }
        .padding(28)
        .background(palette.background)
        .task { reload() }
        .onChange(of: kind) { _, _ in reload() }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .connections, .listeners:
            Table(sockets) {
                TableColumn(t("Process")) { Text("\($0.command) (\($0.pid))") }
                TableColumn(t("Protocol")) { Text("\($0.transport) / \($0.family)") }
                TableColumn(t("Local")) { Text($0.localAddress).font(.body.monospaced()) }
                TableColumn(t("Remote")) { Text($0.remoteAddress).font(.body.monospaced()) }
                TableColumn(t("Status")) { Text($0.state.isEmpty ? "—" : $0.state) }
            }.frame(minHeight: 420)
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

    private func reload() {
        isLoading = true; error = nil
        let selected = kind
        Task {
            switch selected {
            case .connections:
                let value = await Task.detached { SocketInventory.connections() }.value
                await MainActor.run { sockets = value; output = ""; isLoading = false }
            case .listeners:
                let value = await Task.detached { SocketInventory.listeners() }.value
                await MainActor.run { sockets = value; output = ""; isLoading = false }
            case .neighbors:
                let value = await Task.detached { NeighborTable.list() }.value
                await MainActor.run { neighbors = value; output = ""; isLoading = false }
            case .wifi:
                let value = await Task.detached { WiFiInventory.current() }.value
                await MainActor.run { wifi = value; output = value.first?.raw ?? ""; isLoading = false }
            case .firewall:
                let result = await Shell.runTool("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate", "--listapps"], timeout: 20)
                await MainActor.run { output = result.output; error = result.succeeded ? nil : result.output; isLoading = false }
            case .discovery:
                let result = await Shell.runTool("lldpcli", ["show", "neighbors", "-f", "keyvalue"], timeout: 20)
                await MainActor.run {
                    output = result.succeeded ? result.output : result.output + "\n\n" + t("Install lldpd with Homebrew to enable LLDP/CDP discovery.")
                    error = nil; isLoading = false
                }
            }
        }
    }
}

