import Foundation

// MARK: - Local operations workspace

/// The local, user-owned context used to group assets and diagnostic evidence.
///
/// These records intentionally describe the operator's working set. They do
/// not replace NetBox, Zabbix, or another source of truth, and every diagnostic
/// run keeps its target and timestamp so an observation can be distinguished
/// from configured state.
public struct OperationsWorkspace: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String = "Local workspace", notes: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AssetSite: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var name: String
    public var location: String
    public var notes: String

    public init(id: UUID = UUID(), workspaceID: UUID, name: String, location: String = "", notes: String = "") {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.location = location
        self.notes = notes
    }
}

public struct AssetSubnet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var siteID: UUID
    public var name: String
    public var cidr: String
    public var purpose: String
    public var notes: String

    public init(id: UUID = UUID(), siteID: UUID, name: String, cidr: String, purpose: String = "", notes: String = "") {
        self.id = id
        self.siteID = siteID
        self.name = name
        self.cidr = cidr
        self.purpose = purpose
        self.notes = notes
    }
}

public enum AssetDeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case workstation
    case server
    case router
    case networkSwitch
    case firewall
    case accessPoint
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .workstation: return "Workstation"
        case .server: return "Server"
        case .router: return "Router"
        case .networkSwitch: return "Switch"
        case .firewall: return "Firewall"
        case .accessPoint: return "Access point"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .workstation: return "desktopcomputer"
        case .server: return "server.rack"
        case .router: return "arrow.triangle.branch"
        case .networkSwitch: return "rectangle.connected.to.line.below"
        case .firewall: return "firewall"
        case .accessPoint: return "wifi.router"
        case .other: return "questionmark.square"
        }
    }
}

public struct AssetDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var siteID: UUID
    public var subnetID: UUID?
    public var name: String
    public var address: String
    public var kind: AssetDeviceKind
    public var vendor: String
    public var role: String
    public var notes: String
    /// Reference to a Keychain item. The secret itself never belongs in this file.
    public var credentialRefID: UUID?
    /// The system or user that supplied this record, if known.
    public var source: String?
    /// Time the external source record was last fetched successfully.
    public var sourceFetchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, siteID, subnetID, name, address, kind, vendor, role, notes, credentialRefID, source, sourceFetchedAt, createdAt, updatedAt
    }

    public init(id: UUID = UUID(), siteID: UUID, subnetID: UUID? = nil, name: String, address: String, kind: AssetDeviceKind = .other, vendor: String = "", role: String = "", notes: String = "", credentialRefID: UUID? = nil, source: String? = nil, sourceFetchedAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.siteID = siteID
        self.subnetID = subnetID
        self.name = name
        self.address = address
        self.kind = kind
        self.vendor = vendor
        self.role = role
        self.notes = notes
        self.credentialRefID = credentialRefID
        self.source = source
        self.sourceFetchedAt = sourceFetchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        siteID = try values.decode(UUID.self, forKey: .siteID)
        subnetID = try values.decodeIfPresent(UUID.self, forKey: .subnetID)
        name = try values.decode(String.self, forKey: .name)
        address = try values.decode(String.self, forKey: .address)
        kind = try values.decodeIfPresent(AssetDeviceKind.self, forKey: .kind) ?? .other
        vendor = try values.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? ""
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        credentialRefID = try values.decodeIfPresent(UUID.self, forKey: .credentialRefID)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        sourceFetchedAt = try values.decodeIfPresent(Date.self, forKey: .sourceFetchedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

/// A normalized, secret-free record supplied by a read-only external system.
/// Integrations convert their native API models to this shape before merging
/// into the local operations workspace.
public struct ExternalAssetSnapshot: Sendable, Hashable {
    public var source: String
    public var fetchedAt: Date
    public var siteName: String
    public var siteLocation: String
    public var deviceName: String
    public var address: String
    public var kind: AssetDeviceKind
    public var role: String
    public var vendor: String

    public init(source: String, fetchedAt: Date, siteName: String, siteLocation: String = "", deviceName: String, address: String, kind: AssetDeviceKind = .other, role: String = "", vendor: String = "") {
        self.source = source
        self.fetchedAt = fetchedAt
        self.siteName = siteName
        self.siteLocation = siteLocation
        self.deviceName = deviceName
        self.address = address
        self.kind = kind
        self.role = role
        self.vendor = vendor
    }

    public func hasSameIdentity(as other: ExternalAssetSnapshot) -> Bool {
        source == other.source &&
        siteName.caseInsensitiveCompare(other.siteName) == .orderedSame &&
        siteLocation == other.siteLocation &&
        address.caseInsensitiveCompare(other.address) == .orderedSame
    }
}

public enum DiagnosticRunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case interrupted
    case cancelled
    case timedOut
    case permissionDenied
    case unreachable
}

public enum DiagnosticKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ping
    case dns
    case tcp
    case traceroute
    case snmp
    case whois
    case sntp

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ping: return "PING"
        case .dns: return "DNS"
        case .tcp: return "TCP"
        case .traceroute: return "TRACEROUTE"
        case .snmp: return "SNMP"
        case .whois: return "WHOIS"
        case .sntp: return "SNTP"
        }
    }
}

public struct DiagnosticRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var deviceID: UUID?
    public var kind: DiagnosticKind
    public var status: DiagnosticRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var parameters: [String: String]
    public var summary: String
    public var detail: String
    public var latency: TimeInterval?
    public var source: String
    public var target: String?
    public var evidence: DiagnosticRuntimeEvidence?

    public init(id: UUID = UUID(), deviceID: UUID? = nil, kind: DiagnosticKind, status: DiagnosticRunStatus = .running, startedAt: Date = Date(), finishedAt: Date? = nil, parameters: [String: String] = [:], summary: String = "", detail: String = "", latency: TimeInterval? = nil, source: String = "NETworkManager", target: String? = nil, evidence: DiagnosticRuntimeEvidence? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.parameters = parameters
        self.summary = summary
        self.detail = detail
        self.latency = latency
        self.source = source
        self.target = target
        self.evidence = evidence
    }
}

/// JSON-backed local store for the P1 asset and diagnostic slice.
public final class AssetStore: ObservableObject {
    public static let shared = AssetStore()

    @Published public private(set) var workspaces: [OperationsWorkspace] = []
    @Published public private(set) var sites: [AssetSite] = []
    @Published public private(set) var subnets: [AssetSubnet] = []
    @Published public private(set) var devices: [AssetDevice] = []
    @Published public private(set) var diagnosticRuns: [DiagnosticRun] = []
    @Published public private(set) var recoveryError: String?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var preservedCorruptFileURL: URL?

    private struct Payload: Codable {
        var workspaces: [OperationsWorkspace]
        var sites: [AssetSite]
        var subnets: [AssetSubnet]
        var devices: [AssetDevice]
        var diagnosticRuns: [DiagnosticRun]
    }

    public struct BackupDocument: Codable, Sendable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var workspaces: [OperationsWorkspace]
        public var sites: [AssetSite]
        public var subnets: [AssetSubnet]
        public var devices: [AssetDevice]
        public var diagnosticRuns: [DiagnosticRun]
    }

    private let storageURL: URL

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? SettingsStore.supportDirectory.appendingPathComponent("assets.json")
        load()
        if workspaces.isEmpty && recoveryError == nil { seedLocalWorkspace() }
    }

    public var primaryWorkspace: OperationsWorkspace? { workspaces.first }

    public func sites(in workspaceID: UUID) -> [AssetSite] { sites.filter { $0.workspaceID == workspaceID } }
    public func subnets(in siteID: UUID) -> [AssetSubnet] { subnets.filter { $0.siteID == siteID } }
    public func devices(in siteID: UUID) -> [AssetDevice] { devices.filter { $0.siteID == siteID } }
    public func runs(for deviceID: UUID) -> [DiagnosticRun] { diagnosticRuns.filter { $0.deviceID == deviceID }.sorted { $0.startedAt > $1.startedAt } }

    public func runs(in workspaceID: UUID) -> [DiagnosticRun] {
        let siteIDs = Set(sites(in: workspaceID).map(\.id))
        let deviceIDs = Set(devices.filter { siteIDs.contains($0.siteID) }.map(\.id))
        return diagnosticRuns.filter { run in
            guard let deviceID = run.deviceID else { return false }
            return deviceIDs.contains(deviceID)
        }
    }

    public func containsExternalAsset(_ snapshot: ExternalAssetSnapshot) -> Bool {
        guard let workspace = primaryWorkspace,
              let site = matchingSite(for: snapshot, workspaceID: workspace.id) else { return false }
        return devices.contains { matchesExternalDevice($0, snapshot: snapshot, siteID: site.id) }
    }

    public func searchDevices(_ query: String) -> [AssetDevice] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return devices }
        return devices.filter { device in
            [device.name, device.address, device.vendor, device.role, device.kind.displayName]
                .contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    public func upsert(_ workspace: OperationsWorkspace) { replace(workspace, in: &workspaces); save() }
    public func upsert(_ site: AssetSite) { replace(site, in: &sites); save() }
    public func upsert(_ subnet: AssetSubnet) { replace(subnet, in: &subnets); save() }
    public func upsert(_ device: AssetDevice) {
        var value = device
        value.updatedAt = Date()
        replace(value, in: &devices)
        save()
    }

    /// Merge read-only records from an external source without overwriting
    /// user-authored fields on an existing local device.
    @discardableResult
    public func mergeExternalAssets(_ snapshots: [ExternalAssetSnapshot]) -> Int {
        guard let workspace = primaryWorkspace else { return 0 }
        var changed = 0
        var needsSave = false
        for snapshot in snapshots {
            let site = matchingSite(for: snapshot, workspaceID: workspace.id)
                ?? AssetSite(workspaceID: workspace.id, name: snapshot.siteName, location: snapshot.siteLocation)
            if !sites.contains(where: { $0.id == site.id }) {
                sites.append(site)
                needsSave = true
            }

            if let index = devices.firstIndex(where: { matchesExternalDevice($0, snapshot: snapshot, siteID: site.id) }) {
                if devices[index].sourceFetchedAt.map({ snapshot.fetchedAt > $0 }) ?? true {
                    devices[index].sourceFetchedAt = snapshot.fetchedAt
                    needsSave = true
                }
                if devices[index].vendor.isEmpty && !snapshot.vendor.isEmpty {
                    devices[index].vendor = snapshot.vendor
                    needsSave = true
                }
                if devices[index].role.isEmpty && !snapshot.role.isEmpty {
                    devices[index].role = snapshot.role
                    needsSave = true
                }
            } else {
                devices.append(AssetDevice(
                    siteID: site.id,
                    name: snapshot.deviceName,
                    address: snapshot.address,
                    kind: snapshot.kind,
                    vendor: snapshot.vendor,
                    role: snapshot.role,
                    source: snapshot.source,
                    sourceFetchedAt: snapshot.fetchedAt,
                    createdAt: snapshot.fetchedAt,
                    updatedAt: snapshot.fetchedAt
                ))
                changed += 1
                needsSave = true
            }
        }
        if needsSave { save() }
        return changed
    }

    private func matchingSite(for snapshot: ExternalAssetSnapshot, workspaceID: UUID) -> AssetSite? {
        sites.first {
            $0.workspaceID == workspaceID &&
            $0.name.caseInsensitiveCompare(snapshot.siteName) == .orderedSame &&
            $0.location == snapshot.siteLocation
        }
    }

    private func matchesExternalDevice(_ device: AssetDevice, snapshot: ExternalAssetSnapshot, siteID: UUID) -> Bool {
        device.siteID == siteID &&
        device.address.caseInsensitiveCompare(snapshot.address) == .orderedSame &&
        device.source == snapshot.source
    }

    /// Delete a device and all diagnostic evidence attached to it.
    public func removeDevice(id: UUID) {
        devices.removeAll { $0.id == id }
        diagnosticRuns.removeAll { $0.deviceID == id }
        save()
    }

    /// Delete a subnet and detach devices that referenced it.
    public func removeSubnet(id: UUID) {
        subnets.removeAll { $0.id == id }
        for index in devices.indices where devices[index].subnetID == id {
            devices[index].subnetID = nil
        }
        save()
    }

    /// Delete a site and its subnets, devices, and diagnostic evidence.
    public func removeSite(id: UUID) {
        let subnetIDs = Set(subnets.filter { $0.siteID == id }.map(\.id))
        let deviceIDs = Set(devices.filter { device in
            device.siteID == id || device.subnetID.map(subnetIDs.contains) == true
        }.map(\.id))
        sites.removeAll { $0.id == id }
        subnets.removeAll { $0.siteID == id }
        devices.removeAll { deviceIDs.contains($0.id) }
        diagnosticRuns.removeAll { run in run.deviceID.map(deviceIDs.contains) ?? false }
        save()
    }

    /// Delete a workspace and all sites, subnets, devices, and evidence below it.
    public func removeWorkspace(id: UUID) {
        let siteIDs = Set(sites.filter { $0.workspaceID == id }.map(\.id))
        let deviceIDs = Set(devices.filter { siteIDs.contains($0.siteID) }.map(\.id))
        workspaces.removeAll { $0.id == id }
        sites.removeAll { siteIDs.contains($0.id) }
        subnets.removeAll { siteIDs.contains($0.siteID) }
        devices.removeAll { siteIDs.contains($0.siteID) }
        diagnosticRuns.removeAll { run in run.deviceID.map(deviceIDs.contains) ?? false }
        save()
    }

    @discardableResult
    public func beginDiagnostic(deviceID: UUID? = nil, kind: DiagnosticKind, target: String? = nil, parameters: [String: String] = [:]) -> UUID {
        let run = DiagnosticRun(deviceID: deviceID, kind: kind, parameters: parameters, target: target)
        diagnosticRuns.append(run)
        save()
        return run.id
    }

    public func finishDiagnostic(id: UUID, status: DiagnosticRunStatus, summary: String, detail: String = "", latency: TimeInterval? = nil, source: String = "NETworkManager", evidence: DiagnosticRuntimeEvidence? = nil) {
        guard let index = diagnosticRuns.firstIndex(where: { $0.id == id }) else { return }
        diagnosticRuns[index].status = status
        diagnosticRuns[index].finishedAt = Date()
        diagnosticRuns[index].summary = summary
        diagnosticRuns[index].detail = detail
        diagnosticRuns[index].latency = latency
        diagnosticRuns[index].source = source
        diagnosticRuns[index].evidence = evidence
        save()
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            recoveryError = tf("Asset data could not be read. The original file was preserved. Import a valid backup to restore this workspace. (%@)", error.localizedDescription)
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            do {
                payload = try JSONDecoder().decode(Payload.self, from: data)
            } catch {
                recoveryError = t("Asset data is damaged or from an unsupported format. The original file was preserved. Import a valid backup to restore this workspace.")
                return
            }
        }
        workspaces = payload.workspaces
        sites = payload.sites
        subnets = payload.subnets
        devices = payload.devices
        var recoveredRun = false
        diagnosticRuns = payload.diagnosticRuns.map { run in
            guard run.status == .running else { return run }
            var recovered = run
            recovered.status = .interrupted
            recovered.finishedAt = Date()
            recovered.summary = t("Interrupted when app closed")
            recoveredRun = true
            return recovered
        }
        if recoveredRun { save() }
    }

    public func exportBackup() throws -> Data {
        let backup = BackupDocument(formatVersion: 1, exportedAt: Date(), workspaces: workspaces, sites: sites, subnets: subnets, devices: devices, diagnosticRuns: diagnosticRuns)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    public func importBackup(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupDocument.self, from: data)
        guard backup.formatVersion == 1 else { throw AssetBackupError.unsupportedVersion(backup.formatVersion) }
        guard !backup.workspaces.isEmpty else { throw AssetBackupError.emptyWorkspace }
        let payload = Payload(workspaces: backup.workspaces, sites: backup.sites, subnets: backup.subnets, devices: backup.devices, diagnosticRuns: backup.diagnosticRuns)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restoredData = try encoder.encode(payload)
        if recoveryError != nil, FileManager.default.fileExists(atPath: storageURL.path) {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let preservedURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(timestamp)")
            try FileManager.default.copyItem(at: storageURL, to: preservedURL)
            preservedCorruptFileURL = preservedURL
        }
        try restoredData.write(to: storageURL, options: .atomic)
        workspaces = backup.workspaces
        sites = backup.sites
        subnets = backup.subnets
        devices = backup.devices
        diagnosticRuns = backup.diagnosticRuns
        recoveryError = nil
        persistenceError = nil
    }

    public func save() {
        guard recoveryError == nil else { return }
        let payload = Payload(workspaces: workspaces, sites: sites, subnets: subnets, devices: devices, diagnosticRuns: diagnosticRuns)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            try data.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = tf("Asset workspace could not be saved: %@", error.localizedDescription)
        }
    }

    private func seedLocalWorkspace() {
        let workspace = OperationsWorkspace(name: "Local operations")
        let site = AssetSite(workspaceID: workspace.id, name: "This Mac", location: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let device = AssetDevice(siteID: site.id, name: site.location, address: "127.0.0.1", kind: .workstation, vendor: "Apple", role: "Operator workstation")
        workspaces = [workspace]
        sites = [site]
        devices = [device]
        save()
    }

    private func replace<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
    }
}

public enum AssetBackupError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case emptyWorkspace

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported asset backup version: \(version)."
        case .emptyWorkspace: return "Asset backup does not contain a workspace."
        }
    }
}
