import SwiftUI
import AppKit
import NMCore

public struct DashboardView: View {
    @Environment(\.palette) private var palette
    @NMStateCompat private var interfaces: [NetworkInterfaceInfo] = []
    @NMStateCompat private var sockets: [SocketEntry] = []
    @NMStateCompat private var neighbors: [NeighborEntry] = []
    @NMStateCompat private var gateway = ""
    @NMStateCompat private var routeInterface = ""
    @NMStateCompat private var routeError: String?
    @NMStateCompat private var gatewayReachable: Bool?
    @NMStateCompat private var gatewayLatency: TimeInterval?
    @NMStateCompat private var gatewayProbeError: String?
    @NMStateCompat private var isProbingGateway = false
    @NMStateCompat private var discoveryRange = ""
    @NMStateCompat private var discoveryResults: [DiscoveredHost] = []
    @NMStateCompat private var selectedDiscoveredHost: String?
    @NMStateCompat private var scannedHosts = 0
    @NMStateCompat private var totalHosts = 0
    @NMStateCompat private var discoveryMessage = ""
    @NMStateCompat private var isScanning = false
    @NMStateCompat private var discoveryTask: Task<Void, Never>?
    @NMStateCompat private var discoveryCancellation: DiagnosticCancellation?
    @NMStateCompat private var showLargeDiscoveryConfirmation = false
    @NMStateCompat private var pendingDiscoveryRange = ""
    @NMStateCompat private var pendingDiscoveryCount = 0
    @NMStateCompat private var refreshedAt: Date?
    @NMStateCompat private var isRefreshing = false
    private let openTool: (String) -> Void
    private let openPortScanner: (String) -> Void

    public init(openTool: @escaping (String) -> Void = { _ in },
                openPortScanner: @escaping (String) -> Void = { _ in }) {
        self.openTool = openTool
        self.openPortScanner = openPortScanner
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    routeStatus
                    metrics
                    if geometry.size.width >= 880 {
                        HStack(alignment: .top, spacing: 14) {
                            leftColumn.frame(maxWidth: .infinity, alignment: .top)
                            rightColumn.frame(maxWidth: .infinity, alignment: .top)
                        }
                    } else {
                        VStack(spacing: 14) {
                            leftColumn
                            rightColumn
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 1440, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(palette.background)
        }
        .task { refresh() }
        .onDisappear { cancelDiscovery() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Operations overview")).font(.largeTitle.bold())
                Text(Host.current().localizedName ?? t("This Mac"))
                    .font(.subheadline).foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 8)
            if let refreshedAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(t("Last collection")).font(.caption).foregroundStyle(palette.textSecondary)
                    Text(Fmt.dateTime(refreshedAt)).font(.caption.monospaced())
                }
            }
            Button { refresh() } label: {
                Label(isRefreshing ? t("Collecting…") : t("Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .accessibilityIdentifier("refreshOperationsOverview")
        }
    }

    private var routeStatus: some View {
        HStack(spacing: 11) {
            Image(systemName: statusIcon).font(.title2).foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.headline)
                Text(statusDetail).font(.subheadline).foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 8)
            if !gateway.isEmpty {
                Text(gateway).font(.callout.monospaced()).textSelection(.enabled)
                Button { openTool("traceroute") } label: {
                    Label(t("Trace route"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
            metric(title: "Primary IPv4", value: primaryIPv4, detail: routeInterface.isEmpty ? t("No default interface") : routeInterface, icon: "network")
            metric(title: "Active sockets", value: "\(sockets.count)", detail: t("Connections and listeners"), icon: "arrow.left.arrow.right")
            metric(title: "Known neighbors", value: neighbors.isEmpty ? "—" : "\(neighbors.count)", detail: neighbors.isEmpty ? t("No ARP data returned") : t("macOS ARP cache"), icon: "point.3.connected.trianglepath.dotted")
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 14) {
            discoveryPanel
            diagnosticsPanel
            routePanel
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 14) {
            interfacesPanel
            neighborsPanel
            socketsPanel
        }
    }

    private var discoveryPanel: some View {
        panel(title: t("Subnet discovery"), icon: "dot.scope") {
            Text(t("Probe a local IPv4 range and list hosts that answer ICMP."))
                .font(.callout).foregroundStyle(palette.textSecondary)
            HStack(spacing: 8) {
                TextField(t("CIDR or host range"), text: $discoveryRange)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("subnetDiscoveryRange")
                    .disabled(isScanning)
                if isScanning {
                    Button { cancelDiscovery() } label: {
                        Label(t("Stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stopSubnetDiscovery")
                } else {
                    Button { requestDiscovery() } label: {
                        Label(t("Discover"), systemImage: "dot.scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(discoveryPreview == nil || (discoveryPreview?.count ?? 0) > 2048)
                    .accessibilityIdentifier("startSubnetDiscovery")
                }
            }
            if let preview = discoveryPreview {
                Label(tf("%d targets: %@ to %@", preview.count, preview.firstTarget, preview.lastTarget), systemImage: "scope")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textSecondary)
                    .accessibilityIdentifier("subnetDiscoveryPreview")
            } else if let error = discoveryPreviewError {
                Text(error).font(.caption).foregroundStyle(palette.danger)
            }
            if let preview = discoveryPreview, preview.count > 2048 {
                Text(t("Use a range of 2,048 addresses or fewer for dashboard discovery."))
                    .font(.caption).foregroundStyle(palette.warning)
            }
            if totalHosts > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: Double(scannedHosts), total: Double(totalHosts))
                    Text("\(scannedHosts)/\(totalHosts)").font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                }
            }
            if !discoveryMessage.isEmpty {
                Text(discoveryMessage).font(.caption).foregroundStyle(palette.textSecondary)
            }
            if !discoveryResults.isEmpty {
                Table(discoveryResults, selection: $selectedDiscoveredHost) {
                    TableColumn(t("Host")) { Text($0.host).font(.callout.monospaced()) }
                    TableColumn(t("Latency")) { Text(Fmt.ms($0.latency)).font(.callout.monospaced()) }
                    TableColumn("TTL") { Text($0.ttl.map(String.init) ?? "—") }
                }
                .frame(minHeight: 116, idealHeight: 178, maxHeight: 235)
                .accessibilityIdentifier("subnetDiscoveryResults")
                if let selectedDiscoveredHost {
                    Button { openPortScanner(selectedDiscoveredHost) } label: {
                        Label(tf("Scan ports on %@", selectedDiscoveredHost), systemImage: "rectangle.connected.to.line.below")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("scanDiscoveredHostPorts")
                }
            }
        }
        .confirmationDialog(t("Confirm large network scan"), isPresented: $showLargeDiscoveryConfirmation, titleVisibility: .visible) {
            Button(tf("Scan %d addresses", pendingDiscoveryCount)) {
                startDiscovery(expression: pendingDiscoveryRange)
            }
            Button(t("Cancel"), role: .cancel) { pendingDiscoveryRange = "" }
        } message: {
            Text(tf("Range %@ contains %d addresses. Continue?", pendingDiscoveryRange, pendingDiscoveryCount))
        }
    }

    private var diagnosticsPanel: some View {
        panel(title: t("Diagnostic tools"), icon: "waveform.path.ecg") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 8)], alignment: .leading, spacing: 8) {
                actionButton("Ping monitor", icon: "waveform.path.ecg", id: "ping")
                actionButton("Port scanner", icon: "rectangle.connected.to.line.below", id: "portScanner")
                actionButton("DNS lookup", icon: "magnifyingglass", id: "dns")
                actionButton("Traceroute", icon: "point.3.connected.trianglepath.dotted", id: "traceroute")
                actionButton("SNMP", icon: "antenna.radiowaves.left.and.right", id: "snmp")
                actionButton("Remote access", icon: "desktopcomputer", id: "remote")
            }
        }
    }

    private var routePanel: some View {
        panel(title: t("Default route"), icon: "arrow.triangle.turn.up.right.diamond") {
            valueRow("Interface", value: routeInterface.isEmpty ? t("Unavailable") : routeInterface, monospaced: true)
            valueRow("Gateway", value: gateway.isEmpty ? t("No default route") : gateway, monospaced: true)
            valueRow("Gateway probe", value: probeValue, monospaced: false, tint: probeStatusColor)
            if let routeError {
                Text(routeError).font(.caption).foregroundStyle(palette.warning).textSelection(.enabled)
            }
            if let gatewayProbeError {
                Text(gatewayProbeError).font(.caption).foregroundStyle(palette.textSecondary).textSelection(.enabled)
            }
            Button {
                probeGateway()
            } label: {
                Label(isProbingGateway ? t("Probing…") : t("Probe gateway"),
                      systemImage: isProbingGateway ? "hourglass" : "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(gateway.isEmpty || isProbingGateway)
            .accessibilityIdentifier("probeDefaultGateway")
        }
    }

    private var interfacesPanel: some View {
        panel(title: t("Interfaces"), icon: "network", trailing: "\(interfaces.count)") {
            if interfaces.isEmpty {
                emptyMessage("No network interfaces were found.")
            } else {
                ForEach(visibleInterfaces) { item in
                    HStack(spacing: 8) {
                        Circle().fill(item.isUp ? palette.success : palette.textSecondary.opacity(0.55)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.callout.monospaced().weight(.semibold))
                                Text(item.family).font(.caption).foregroundStyle(palette.textSecondary)
                            }
                            Text(item.address).font(.caption.monospaced()).foregroundStyle(palette.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { copy(item.address) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(t("Copy address"))
                            .accessibilityLabel(tf("Copy %@", item.address))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { openTool("network") }
                }
            }
            panelAction("View all interfaces", icon: "arrow.up.right") { openTool("network") }
        }
    }

    private var neighborsPanel: some View {
        panel(title: t("Local neighbors"), icon: "point.3.connected.trianglepath.dotted", trailing: "\(neighbors.count)") {
            if neighbors.isEmpty {
                emptyMessage("macOS returned no neighbor records.")
            } else {
                ForEach(neighbors.prefix(6)) { item in
                    HStack(spacing: 8) {
                        Circle().fill(palette.success).frame(width: 7, height: 7)
                        Text(item.address).font(.callout.monospaced())
                        Spacer(minLength: 4)
                        Text(item.macAddress).font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                        Text(item.interface).font(.caption).foregroundStyle(palette.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            panelAction("Open neighbor table", icon: "arrow.up.right") { openTool("neighbors") }
        }
    }

    private var socketsPanel: some View {
        panel(title: t("Live sockets"), icon: "arrow.left.arrow.right", trailing: "\(sockets.count)") {
            if sockets.isEmpty {
                emptyMessage("No IP sockets were returned by macOS.")
            } else {
                ForEach(sockets.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.command).font(.callout.weight(.medium)).lineLimit(1)
                            Text("PID \(item.pid)").font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                            Spacer(minLength: 4)
                            Text(item.state.isEmpty ? item.transport : item.state)
                                .font(.caption)
                                .foregroundStyle(item.state.uppercased().contains("LISTEN") ? palette.info : palette.textSecondary)
                        }
                        Text(item.remoteAddress.isEmpty ? item.localAddress : "\(item.localAddress)  →  \(item.remoteAddress)")
                            .font(.caption.monospaced()).foregroundStyle(palette.textSecondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                }
            }
            panelAction("Inspect all connections", icon: "arrow.up.right") { openTool("connections") }
        }
    }

    private var visibleInterfaces: [NetworkInterfaceInfo] {
        let primary = interfaces.first { $0.name == routeInterface && $0.family == "IPv4" }
        let rest = interfaces.filter { $0.id != primary?.id }
        return Array(([primary].compactMap { $0 } + rest).prefix(6))
    }

    private var primaryIPv4: String {
        interfaces.first { $0.name == routeInterface && $0.family == "IPv4" }?.address
            ?? interfaces.first { $0.family == "IPv4" }?.address
            ?? "—"
    }

    private var probeValue: String {
        guard !gateway.isEmpty else { return t("Unavailable") }
        guard let gatewayReachable else { return isProbingGateway ? t("Checking…") : t("Not tested") }
        if gatewayReachable { return gatewayLatency.map(Fmt.ms) ?? t("Reachable") }
        return gatewayProbeError == nil ? t("No ICMP echo reply") : t("Probe failed")
    }

    private var statusTitle: String {
        guard !gateway.isEmpty else { return routeError == nil ? t("No default route detected") : t("Route telemetry unavailable") }
        guard let gatewayReachable else { return isRefreshing ? t("Checking gateway") : t("Default route available") }
        if gatewayReachable { return t("Gateway reachable") }
        return gatewayProbeError == nil ? t("No ICMP echo reply") : t("Gateway probe failed")
    }

    private var statusDetail: String {
        guard !gateway.isEmpty else { return routeError ?? t("Check the macOS network service and interface state.") }
        if gatewayReachable == false && gatewayProbeError == nil {
            return t("A route exists, but the gateway may filter ICMP echo requests.")
        }
        return tf("Default route through %@", routeInterface.isEmpty ? gateway : routeInterface)
    }

    private var statusIcon: String {
        guard !gateway.isEmpty else { return "network.slash" }
        guard let gatewayReachable else { return "arrow.triangle.turn.up.right.diamond.fill" }
        if gatewayReachable { return "checkmark.circle.fill" }
        return gatewayProbeError == nil ? "minus.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        guard !gateway.isEmpty else { return palette.textSecondary }
        guard let gatewayReachable else { return palette.info }
        if gatewayReachable { return palette.success }
        return gatewayProbeError == nil ? palette.textSecondary : palette.warning
    }

    private var probeStatusColor: Color? {
        guard !gateway.isEmpty, let gatewayReachable else { return nil }
        if gatewayReachable { return palette.success }
        return gatewayProbeError == nil ? palette.textSecondary : palette.warning
    }

    private func metric(title: String, value: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(palette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.75)
                Text(t(title)).font(.caption).foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 2)
            Text(detail).font(.caption2).foregroundStyle(palette.textSecondary).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
    }

    private func panel<Content: View>(title: String, icon: String, trailing: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(palette.accent)
                Text(title).font(.headline)
                Spacer(minLength: 6)
                if let trailing { Text(trailing).font(.caption.monospaced()).foregroundStyle(palette.textSecondary) }
            }
            Divider()
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
    }

    private func valueRow(_ title: String, value: String, monospaced: Bool, tint: Color? = nil) -> some View {
        HStack {
            Text(t(title)).foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(tint ?? palette.textPrimary).lineLimit(1).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(t(message)).font(.callout).foregroundStyle(palette.textSecondary).padding(.vertical, 5)
    }

    private func panelAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(t(title), systemImage: icon).font(.callout) }
            .buttonStyle(.borderless).padding(.top, 3)
    }

    private func actionButton(_ title: String, icon: String, id: String) -> some View {
        Button { openTool(id) } label: {
            Label(t(title), systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        gatewayReachable = nil
        gatewayLatency = nil
        gatewayProbeError = nil
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                let routeResult = DefaultRouteInventory.current()
                let interfaces = NetworkInterfaces.list()
                let route = routeResult.route
                return DashboardSnapshot(
                    interfaces: interfaces,
                    sockets: SocketInventory.list(),
                    neighbors: NeighborTable.list(),
                    gateway: route?.gateway ?? "",
                    routeInterface: route?.interface ?? "",
                    routeError: routeResult.error,
                    suggestedRange: Self.suggestedRange(interfaces, routeInterface: route?.interface ?? "")
                )
            }.value

            interfaces = snapshot.interfaces
            sockets = snapshot.sockets
            neighbors = snapshot.neighbors
            gateway = snapshot.gateway
            routeInterface = snapshot.routeInterface
            routeError = snapshot.routeError
            if discoveryRange.isEmpty { discoveryRange = snapshot.suggestedRange }
            refreshedAt = Date()
            isRefreshing = false
        }
    }

    private func probeGateway() {
        guard !gateway.isEmpty, !isProbingGateway else { return }
        isProbingGateway = true
        gatewayReachable = nil
        gatewayLatency = nil
        gatewayProbeError = nil
        let target = gateway
        Task {
            let reply = await Self.probeGateway(target)
            if let reply {
                gatewayReachable = reply.outcome.isSuccess
                gatewayLatency = reply.rtt
                if case .error(let message) = reply.outcome { gatewayProbeError = message }
            } else {
                gatewayReachable = false
                gatewayProbeError = t("Unable to create an ICMP probe.")
            }
            isProbingGateway = false
        }
    }

    private var discoveryPreview: HostRangePreview? {
        try? HostRangeParser.preview(discoveryRange)
    }

    private var discoveryPreviewError: String? {
        guard !discoveryRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try HostRangeParser.preview(discoveryRange)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func requestDiscovery() {
        guard let preview = discoveryPreview else {
            discoveryMessage = discoveryPreviewError ?? t("Invalid input")
            return
        }
        guard preview.count <= 2048 else {
            discoveryMessage = t("Use a range of 2,048 addresses or fewer for dashboard discovery.")
            return
        }
        discoveryMessage = ""
        if preview.count > HostRangeParser.largeScanConfirmationThreshold {
            pendingDiscoveryRange = discoveryRange
            pendingDiscoveryCount = preview.count
            showLargeDiscoveryConfirmation = true
        } else {
            startDiscovery(expression: discoveryRange)
        }
    }

    private func cancelDiscovery() {
        discoveryCancellation?.cancel()
        discoveryTask?.cancel()
    }

    private func startDiscovery(expression: String) {
        guard !isScanning else { return }
        do {
            let hosts = try HostRangeParser.parse(expression)
            guard hosts.count <= 2048 else {
                discoveryMessage = t("Use a range of 2,048 addresses or fewer for dashboard discovery.")
                return
            }
            discoveryResults = []
            selectedDiscoveredHost = nil
            discoveryMessage = ""
            totalHosts = hosts.count
            scannedHosts = 0
            isScanning = true
            let cancellation = DiagnosticCancellation()
            discoveryCancellation = cancellation
            let concurrency = min(32, hosts.count)
            discoveryTask = Task {
                var nextIndex = 0
                await withTaskGroup(of: ProbeResult.self) { group in
                    while nextIndex < concurrency {
                        let host = hosts[nextIndex]
                        group.addTask { await Self.probeHost(host, cancellation: cancellation) }
                        nextIndex += 1
                    }
                    while let result = await group.next() {
                        if Task.isCancelled || cancellation.isCancelled {
                            group.cancelAll()
                            break
                        }
                        scannedHosts += 1
                        if let reply = result.reply, reply.outcome.isSuccess {
                            discoveryResults.append(DiscoveredHost(host: result.host, latency: reply.rtt ?? 0, ttl: reply.ttl))
                        }
                        if nextIndex < hosts.count {
                            let host = hosts[nextIndex]
                            group.addTask { await Self.probeHost(host, cancellation: cancellation) }
                            nextIndex += 1
                        }
                    }
                }

                let wasCancelled = Task.isCancelled || cancellation.isCancelled
                isScanning = false
                discoveryTask = nil
                discoveryCancellation = nil
                discoveryMessage = wasCancelled
                    ? tf("Stopped after %d of %d addresses.", scannedHosts, totalHosts)
                    : tf("Completed: %d of %d hosts responded.", discoveryResults.count, totalHosts)
                if !wasCancelled {
                    neighbors = await Task.detached(priority: .utility) { NeighborTable.list() }.value
                    refreshedAt = Date()
                }
            }
        } catch {
            discoveryMessage = error.localizedDescription
            totalHosts = 0
            scannedHosts = 0
        }
    }

    private nonisolated static func probeHost(_ host: String, cancellation: DiagnosticCancellation) async -> ProbeResult {
        let reply = await Task.detached(priority: .utility) { () -> ICMPReply? in
            guard !cancellation.isCancelled,
                  let pinger = try? ICMPPinger(host: host, timeout: 0.6, cancellation: cancellation) else { return nil }
            return pinger.ping()
        }.value
        return ProbeResult(host: host, reply: reply)
    }

    private nonisolated static func probeGateway(_ host: String) async -> ICMPReply? {
        await Task.detached(priority: .userInitiated) { () -> ICMPReply? in
            guard let pinger = try? ICMPPinger(host: host, timeout: 1.5) else { return nil }
            return pinger.ping()
        }.value
    }

    private nonisolated static func suggestedRange(_ interfaces: [NetworkInterfaceInfo], routeInterface: String) -> String {
        let selected = interfaces.first { $0.name == routeInterface && $0.family == "IPv4" }
            ?? interfaces.first { $0.family == "IPv4" && $0.isUp }
        guard let selected, let address = IPv4(selected.address), let mask = IPv4(selected.netmask) else { return "" }
        let prefix = mask.raw.nonzeroBitCount
        let expectedMask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        guard expectedMask == mask.raw else { return "" }
        return IPv4Subnet(base: address, prefix: prefix).cidr
    }
}

private struct DashboardSnapshot: Sendable {
    let interfaces: [NetworkInterfaceInfo]
    let sockets: [SocketEntry]
    let neighbors: [NeighborEntry]
    let gateway: String
    let routeInterface: String
    let routeError: String?
    let suggestedRange: String
}

private struct ProbeResult: Sendable {
    let host: String
    let reply: ICMPReply?
}

private struct DiscoveredHost: Identifiable, Hashable, Sendable {
    var id: String { host }
    let host: String
    let latency: TimeInterval
    let ttl: Int?
}
