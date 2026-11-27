import NMCore
import SwiftUI

struct LibreNMSLinksView: View {
    @ObservedObject private var assets = AssetStore.shared
    @NMStateCompat private var endpoint = ""
    @NMStateCompat private var deviceNumber = ""
    @NMStateCompat private var token = ""
    @NMStateCompat private var importTask: Task<Void, Never>?
    @NMStateCompat private var message = ""
    let deviceID: UUID

    private var device: AssetDevice? { assets.devices.first { $0.id == deviceID } }

    var body: some View {
        GroupBox(t("LibreNMS links")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(t("LibreNMS base URL"), text: $endpoint)
                    TextField(t("LibreNMS device ID"), text: $deviceNumber).frame(width: 140)
                    SecureField(t("API token"), text: $token)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(importTask != nil)
                HStack {
                    Button(t("Read LibreNMS links"), action: refresh)
                        .disabled(!assets.canEditWorkspace || importTask != nil)
                    if let importTask { Button(t("Cancel")) { importTask.cancel() } }
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                }
                if let snapshot = device?.libreNMSLinks {
                    LabeledContent(t("Source"), value: "\(snapshot.source.absoluteString) / #\(snapshot.deviceID)")
                    LabeledContent(t("Inventory captured at"), value: Fmt.dateTime(snapshot.fetchedAt))
                    TimelineView(.everyMinute) { context in
                        if snapshot.isStale(at: context.date) { Text(t("LibreNMS snapshot is stale")).foregroundStyle(.secondary) }
                    }
                    if snapshot.links.isEmpty { Text(t("No LibreNMS links returned.")) }
                    ForEach(snapshot.links) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(link.localPort ?? "#\(link.localPortID)") → \(link.remoteLabel)")
                            if let discoveryProtocol = link.discoveryProtocol { Text(discoveryProtocol.uppercased()).font(.caption) }
                            if !link.active { Text(t("Inactive in LibreNMS")).font(.caption).foregroundStyle(.secondary) }
                            if link.conflicts(with: device?.networkInventory) {
                                Label(t("Endpoint differs from NetBox"), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .onAppear {
            guard let snapshot = device?.libreNMSLinks else { return }
            endpoint = snapshot.source.absoluteString
            deviceNumber = String(snapshot.deviceID)
        }
        .onDisappear { importTask?.cancel(); token = "" }
    }

    private func refresh() {
        let requestURL = endpoint
        let selectedDevice = Int(deviceNumber.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let requestToken = token
        token = ""
        message = t("Loading…")
        importTask = Task {
            defer { importTask = nil }
            do {
                let snapshot = try await LibreNMS.readLinks(baseURL: requestURL, deviceID: selectedDevice, token: requestToken)
                try Task.checkCancellation()
                let saved = assets.applyLibreNMSLinks(snapshot, to: deviceID)
                message = saved ? "" : t("LibreNMS links could not be saved.")
            } catch {
                message = Task.isCancelled ? t("Diagnostic cancelled") : error.localizedDescription
            }
        }
    }
}

struct AssetNetworkInventoryView: View {
    let device: AssetDevice

    var body: some View {
        GroupBox(t("Configured interfaces and addresses")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("Source configuration is a dated snapshot. It does not prove reachability or this Mac's actual route; diagnostics keep using the device's local target."))
                    .font(.caption).foregroundStyle(.secondary)
                if let primary = device.sourcePrimaryAddresses, !primary.isEmpty {
                    Text(t("Source primary addresses")).font(.headline)
                    ForEach(Array(primary.enumerated()), id: \.offset) { _, address in addressRow(address) }
                }
                if let inventory = device.networkInventory {
                    LabeledContent(t("NetBox source"), value: inventory.deviceIdentity.instance)
                        .font(.caption.monospaced())
                    LabeledContent(t("Inventory captured at"), value: Fmt.dateTime(inventory.fetchedAt))
                        .font(.caption.monospaced())
                    if let deviceFetchedAt = device.sourceFetchedAt, deviceFetchedAt > inventory.fetchedAt {
                        LabeledContent(t("Device synced at"), value: Fmt.dateTime(deviceFetchedAt))
                            .font(.caption.monospaced())
                        Text(t("Device details are newer than this interface inventory."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if inventory.interfaces.isEmpty { Text(t("No configured interfaces returned.")) }
                    ForEach(inventory.interfaces) { interface in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(interface.routingDomain.title).font(.caption)
                                if let enabled = interface.enabled {
                                    LabeledContent(t("Configured enabled"), value: t(enabled ? "Yes" : "No"))
                                }
                                if let mtu = interface.mtu { LabeledContent("MTU", value: String(mtu)) }
                                if let mac = interface.macAddress { LabeledContent(t("MAC address"), value: mac) }
                                cableRows(interface.configuredCable)
                                let addresses = inventory.addresses.filter { $0.interfaceIdentity == interface.identity }
                                if addresses.isEmpty { Text(t("No assigned addresses returned.")).foregroundStyle(.secondary) }
                                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in addressRow(address) }
                            }
                            .font(.callout).padding(.vertical, 5)
                        } label: {
                            Text("\(interface.name) · \(inventory.addresses.filter { $0.interfaceIdentity == interface.identity }.count)")
                        }
                    }
                } else {
                    Text(t("Interface inventory has not been read. In NetBox preview, choose Read interfaces and addresses, then confirm import."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("deviceNetworkInventory")
    }

    @ViewBuilder
    private func cableRows(_ cable: AssetConfiguredCable?) -> some View {
        switch cable {
        case .none:
            Text(t("Cable configuration unavailable")).foregroundStyle(.secondary)
        case .unassigned:
            Text(t("No cable configured")).foregroundStyle(.secondary)
        case let .assigned(id, peers):
            LabeledContent(t("Configured cable"), value: "#\(id)")
            if let peers {
                if peers.isEmpty { Text(t("No configured cable endpoints")).foregroundStyle(.secondary) }
                ForEach(peers) { peer in
                    let kind = switch peer.kind {
                    case .interface: t("Interface")
                    case .frontPort: t("Front port")
                    case .rearPort: t("Rear port")
                    }
                    LabeledContent(kind, value: "\(peer.deviceName) (#\(peer.deviceID)) / \(peer.portName) (#\(peer.portID))")
                }
            }
            if peers == nil { Text(t("Cable endpoint details unavailable")).foregroundStyle(.secondary) }
        }
    }

    private func addressRow(_ address: AssetIPAddress) -> some View {
        HStack(alignment: .top) {
            Text(address.cidr).font(.callout.monospaced())
            Text(address.family == .ipv6 ? "IPv6" : "IPv4").font(.caption)
            Text(address.routingDomain.title).font(.caption).foregroundStyle(.secondary)
            if address.isPrimary { Text(t("Primary IP")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
