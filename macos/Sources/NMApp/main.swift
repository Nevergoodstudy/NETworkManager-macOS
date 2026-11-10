import SwiftUI
import AppKit
import NMCore
import NMDashboard
import NMNetworkInfo
import NMScanners
import NMLookups
import NMCalculators
import NMUtilities
import NMRemote
import NMProfiles
import NMAssets
import NMIntegrations
import NMSettingsKit

@main
struct NETworkManagerMacApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate
    @StateObject private var theme = Theme.shared
    @StateObject private var localization = Loc.shared
    @NMStateCompat private var selectedTool: String?
    private let resetSettingsWasDeferred: Bool

    init() {
        resetSettingsWasDeferred = LaunchOptions.current.resetSettings && !SettingsStore.shared.resetFromCommandLine()
        _selectedTool = NMStateCompat(wrappedValue: LaunchOptions.current.tool ?? SettingsStore.shared.lastTool ?? "dashboard")
    }

    var body: some Scene {
        WindowGroup(t("NETworkManager")) {
            ContentView(selectedTool: $selectedTool)
                .environmentObject(theme)
                .environmentObject(localization)
                .themedRoot()
                .onChange(of: selectedTool) { _, value in SettingsStore.shared.lastTool = value }
                .onAppear {
                    if resetSettingsWasDeferred {
                        let alert = NSAlert()
                        alert.messageText = t("Settings recovery required")
                        alert.informativeText = t("The settings file is damaged and was preserved. Open Settings to review recovery before resetting preferences.")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: t("OK"))
                        alert.runModal()
                        return
                    }
                    guard LaunchOptions.current.showHelp else { return }
                    let alert = NSAlert()
                    alert.messageText = t("NETworkManager command line")
                    alert.informativeText = "--application:PingMonitor\n--reset-settings\n--help"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: t("OK"))
                    alert.runModal()
                }
        }
        .defaultSize(width: SettingsStore.shared.windowWidth, height: SettingsStore.shared.windowHeight)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(t("About")) { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            CommandMenu(t("Tools")) {
                Button(t("Dashboard")) { selectedTool = "dashboard" }.keyboardShortcut("1", modifiers: [.command])
                Button(t("Port Scanner")) { selectedTool = "portScanner" }.keyboardShortcut("2", modifiers: [.command])
                Button(t("DNS Lookup")) { selectedTool = "dns" }.keyboardShortcut("3", modifiers: [.command])
                Button(t("Subnet Calculator")) { selectedTool = "subnet" }.keyboardShortcut("4", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(localization)
                .themedRoot()
        }
    }
}

private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 13.0, *) {
            LoginItemManager.shared.migrateLegacyAgentIfNeeded()
            LoginItemManager.shared.refresh()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct ToolItem: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
}

private struct ToolGroup: Identifiable {
    let title: String
    let items: [ToolItem]
    var id: String { title }
}

private struct ContentView: View {
    @Environment(\.palette) private var palette
    @Binding var selectedTool: String?
    @NMStateCompat private var searchText = ""
    @NMStateCompat private var dashboardTarget: String?
    @NMStateCompat private var diagnosticHistorySearch = ""
    @FocusState private var searchFocused: Bool
    private let groups = [
        ToolGroup(title: "Monitor", items: [
            ToolItem(id: "dashboard", title: "Dashboard", icon: "rectangle.grid.2x2"),
            ToolItem(id: "zabbix", title: "Zabbix problems", icon: "waveform.path.ecg.rectangle"),
            ToolItem(id: "assets", title: "Assets", icon: "server.rack"),
            ToolItem(id: "network", title: "Network Interface", icon: "network"),
            ToolItem(id: "ping", title: "Ping Monitor", icon: "waveform.path.ecg"),
            ToolItem(id: "connections", title: "Connections", icon: "arrow.left.arrow.right"),
            ToolItem(id: "listeners", title: "Listeners", icon: "dot.radiowaves.left.and.right"),
            ToolItem(id: "wifi", title: "WiFi", icon: "wifi")
        ]),
        ToolGroup(title: "Discover", items: [
            ToolItem(id: "ipScanner", title: "IP Scanner", icon: "dot.scope"),
            ToolItem(id: "portScanner", title: "Port Scanner", icon: "rectangle.connected.to.line.below"),
            ToolItem(id: "discovery", title: "Discovery Protocol", icon: "point.3.connected.trianglepath.dotted"),
            ToolItem(id: "neighbors", title: "Neighbor Table", icon: "rectangle.3.group")
        ]),
        ToolGroup(title: "Diagnose", items: [
            ToolItem(id: "diagnosticHistory", title: "Diagnostic history", icon: "clock.arrow.circlepath"),
            ToolItem(id: "dns", title: "DNS Lookup", icon: "magnifyingglass"),
            ToolItem(id: "traceroute", title: "Traceroute", icon: "point.3.connected.trianglepath.dotted"),
            ToolItem(id: "snmp", title: "SNMP", icon: "antenna.radiowaves.left.and.right"),
            ToolItem(id: "whois", title: "WHOIS", icon: "person.text.rectangle"),
            ToolItem(id: "geolocation", title: "IP Geolocation", icon: "globe.americas"),
            ToolItem(id: "sntp", title: "SNTP Lookup", icon: "clock"),
            ToolItem(id: "subnet", title: "Subnet Calculator", icon: "function"),
            ToolItem(id: "bit", title: "Bit Calculator", icon: "binary"),
            ToolItem(id: "firewall", title: "Firewall", icon: "firewall")
        ]),
        ToolGroup(title: "Operate", items: [
            ToolItem(id: "remote", title: "Remote", icon: "desktopcomputer"),
            ToolItem(id: "web", title: "Web Console", icon: "safari"),
            ToolItem(id: "aws", title: "AWS Session Manager", icon: "cloud"),
            ToolItem(id: "powershell", title: "PowerShell", icon: "terminal"),
            ToolItem(id: "wol", title: "Wake on LAN", icon: "power"),
            ToolItem(id: "hosts", title: "Hosts File Editor", icon: "doc.text")
        ]),
        ToolGroup(title: "Reference", items: [
            ToolItem(id: "oui", title: "OUI Lookup", icon: "tag"),
            ToolItem(id: "portLookup", title: "Port Lookup", icon: "list.number")
        ]),
        ToolGroup(title: "Library", items: [
            ToolItem(id: "netbox", title: "NetBox", icon: "shippingbox.and.arrow.backward"),
            ToolItem(id: "credentials", title: "Credentials", icon: "key.fill"),
            ToolItem(id: "profiles", title: "Profiles", icon: "person.crop.rectangle.stack")
        ])
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTool) {
                ForEach(groups) { group in
                    let visibleItems = group.items.filter(matchesSearch)
                    if !visibleItems.isEmpty {
                        Section(t(group.title)) {
                            ForEach(visibleItems) { item in
                                Label(t(item.title), systemImage: item.icon).tag(Optional(item.id))
                            }
                        }
                    }
                }
                Section(t("Application")) {
                    if searchText.isEmpty || "settings".localizedCaseInsensitiveContains(searchText)
                        || t("Settings").localizedCaseInsensitiveContains(searchText) {
                        Label(t("Settings"), systemImage: "gearshape").tag(Optional("settings"))
                    }
                }
            }
            .navigationTitle("NETworkManager")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 300)
        } detail: {
            detailView
                .navigationTitle(selectedToolTitle)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(palette.textSecondary)
                            TextField(t("Find a tool or workflow"), text: $searchText)
                                .textFieldStyle(.plain)
                                .focused($searchFocused)
                                .onSubmit(openFirstSearchResult)
                                .accessibilityIdentifier("operationsSearch")
                                .accessibilityLabel(t("Find a tool or workflow"))
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(palette.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .help(t("Clear search"))
                            }
                            Text("⌘K")
                                .font(.caption.monospaced())
                                .foregroundStyle(palette.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 330, height: 32)
                        .background(palette.cardAlt, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
                    }
                    ToolbarItem(placement: .automatic) {
                        Button { searchFocused = true } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help(t("Find tools"))
                        .accessibilityLabel(t("Find tools"))
                        .keyboardShortcut("k", modifiers: .command)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button { selectedTool = "settings" } label: {
                            Image(systemName: "gearshape")
                        }
                        .help(t("Settings"))
                        .accessibilityLabel(t("Settings"))
                    }
                }
        }
        .onChange(of: selectedTool) { oldValue, newValue in
            if oldValue == "diagnosticHistory" && newValue != "diagnosticHistory" {
                diagnosticHistorySearch = ""
            }
        }
    }

    private var selectedToolTitle: String {
        if selectedTool == "settings" { return t("Settings") }
        return groups.flatMap(\.items).first { $0.id == (selectedTool ?? "dashboard") }.map { t($0.title) }
            ?? t("Dashboard")
    }

    private func matchesSearch(_ item: ToolItem) -> Bool {
        searchText.isEmpty || t(item.title).localizedCaseInsensitiveContains(searchText)
            || item.title.localizedCaseInsensitiveContains(searchText)
    }

    private func openFirstSearchResult() {
        guard !searchText.isEmpty else { return }
        if "settings".localizedCaseInsensitiveContains(searchText) || t("Settings").localizedCaseInsensitiveContains(searchText) {
            selectedTool = "settings"
            searchFocused = false
            return
        }
        if let item = groups.flatMap(\.items).first(where: matchesSearch) {
            selectedTool = item.id
            searchFocused = false
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTool ?? "dashboard" {
        case "dashboard": DashboardView(
            openTool: { selectedTool = $0 },
            openPortScanner: { host in dashboardTarget = host; selectedTool = "portScanner" }
        )
        case "assets": AssetsView()
        case "diagnosticHistory": DiagnosticHistoryView(initialEventID: diagnosticHistorySearch)
        case "zabbix": ZabbixView(openDiagnosticHistory: { eventID in
            diagnosticHistorySearch = eventID
            selectedTool = "diagnosticHistory"
        })
        case "netbox": NetBoxView()
        case "credentials": CredentialsView()
        case "network": NetworkInfoView()
        case "ipScanner": ScannerView(mode: .ipScanner)
        case "portScanner": ScannerView(mode: .portScanner, initialHost: dashboardTarget)
        case "ping": ScannerView(mode: .ping)
        case "dns": LookupView(kind: .dns)
        case "snmp": SNMPView()
        case "whois": LookupView(kind: .whois)
        case "geolocation": IPGeolocationView()
        case "sntp": LookupView(kind: .sntp)
        case "oui": ReferenceLookupView(kind: .oui)
        case "portLookup": ReferenceLookupView(kind: .port)
        case "subnet": CalculatorView(kind: .subnet)
        case "bit": CalculatorView(kind: .bit)
        case "traceroute": UtilitiesView(kind: .traceroute)
        case "wifi": SystemDiagnosticsView(kind: .wifi)
        case "connections": SystemDiagnosticsView(kind: .connections)
        case "listeners": SystemDiagnosticsView(kind: .listeners)
        case "neighbors": SystemDiagnosticsView(kind: .neighbors)
        case "firewall": SystemDiagnosticsView(kind: .firewall)
        case "discovery": SystemDiagnosticsView(kind: .discovery)
        case "web": UtilitiesView(kind: .web)
        case "aws": UtilitiesView(kind: .aws)
        case "powershell": UtilitiesView(kind: .command)
        case "wol": WakeOnLANView()
        case "hosts": UtilitiesView(kind: .hosts)
        case "remote": RemoteView()
        case "profiles": ProfilesView()
        case "settings": SettingsView()
        default: DashboardView(
            openTool: { selectedTool = $0 },
            openPortScanner: { host in dashboardTarget = host; selectedTool = "portScanner" }
        )
        }
    }
}
