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
    public var externalIdentity: ExternalAssetIdentity?
    /// Last address received from the source, independent of an engineer's local override.
    public var sourceAddress: String?
    public var sourcePrimaryAddresses: [AssetIPAddress]?
    public var networkInventory: AssetNetworkInventory?
    package var libreNMSLinks: LibreNMSLinkSnapshot? = nil
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, siteID, subnetID, name, address, kind, vendor, role, notes, credentialRefID, source, sourceFetchedAt, externalIdentity, sourceAddress, sourcePrimaryAddresses, networkInventory, createdAt, updatedAt
        case libreNMSLinks
    }

    public init(id: UUID = UUID(), siteID: UUID, subnetID: UUID? = nil, name: String, address: String, kind: AssetDeviceKind = .other, vendor: String = "", role: String = "", notes: String = "", credentialRefID: UUID? = nil, source: String? = nil, sourceFetchedAt: Date? = nil, externalIdentity: ExternalAssetIdentity? = nil, sourceAddress: String? = nil, sourcePrimaryAddresses: [AssetIPAddress]? = nil, networkInventory: AssetNetworkInventory? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
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
        self.externalIdentity = externalIdentity
        self.sourceAddress = sourceAddress
        self.sourcePrimaryAddresses = sourcePrimaryAddresses
        self.networkInventory = networkInventory
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
        externalIdentity = try values.decodeIfPresent(ExternalAssetIdentity.self, forKey: .externalIdentity)
        sourceAddress = try values.decodeIfPresent(String.self, forKey: .sourceAddress)
        sourcePrimaryAddresses = try values.decodeIfPresent([AssetIPAddress].self, forKey: .sourcePrimaryAddresses)
        networkInventory = try values.decodeIfPresent(AssetNetworkInventory.self, forKey: .networkInventory)
        libreNMSLinks = try values.decodeIfPresent(LibreNMSLinkSnapshot.self, forKey: .libreNMSLinks)
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
    public var externalIdentity: ExternalAssetIdentity?
    public var sourcePrimaryAddresses: [AssetIPAddress]?
    public var networkInventory: AssetNetworkInventory?

    public init(source: String, fetchedAt: Date, siteName: String, siteLocation: String = "", deviceName: String, address: String, kind: AssetDeviceKind = .other, role: String = "", vendor: String = "", externalIdentity: ExternalAssetIdentity? = nil, sourcePrimaryAddresses: [AssetIPAddress]? = nil, networkInventory: AssetNetworkInventory? = nil) {
        self.source = source
        self.fetchedAt = fetchedAt
        self.siteName = siteName
        self.siteLocation = siteLocation
        self.deviceName = deviceName
        self.address = address
        self.kind = kind
        self.role = role
        self.vendor = vendor
        self.externalIdentity = externalIdentity
        self.sourcePrimaryAddresses = sourcePrimaryAddresses
        self.networkInventory = networkInventory
    }

    public func hasSameIdentity(as other: ExternalAssetSnapshot) -> Bool {
        if externalIdentity != nil || other.externalIdentity != nil {
            return externalIdentity != nil && externalIdentity == other.externalIdentity
        }
        return source == other.source &&
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
    case tls
    case http
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
        case .tls: return "TLS"
        case .http: return "HTTP"
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

/// Observable workspace facade; default storage is the SQLite repository.
public final class AssetStore: ObservableObject {
    @MainActor
    public static let shared: AssetStore = {
        let store = AssetStore(openingInBackground: sqliteRepository())
        initializedShared = store
        return store
    }()

    @MainActor package private(set) static var initializedShared: AssetStore?

    @Published public private(set) var workspaces: [OperationsWorkspace] = []
    @Published public private(set) var sites: [AssetSite] = []
    @Published public private(set) var subnets: [AssetSubnet] = []
    @Published public private(set) var devices: [AssetDevice] = []
    @Published public private(set) var diagnosticRuns: [DiagnosticRun] = []
    @Published package private(set) var diagnosticHistoryRevision = 0
    @Published public private(set) var recoveryError: String?
    @Published public private(set) var workspaceAccessError: String?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var preservedCorruptFileURL: URL?
    @Published public private(set) var isLoadingWorkspace = false
    @Published public private(set) var isRestoringBackup = false
    @Published package private(set) var isSavingWorkspace = false

    public struct BackupDocument: Codable, Sendable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var workspaces: [OperationsWorkspace]
        public var sites: [AssetSite]
        public var subnets: [AssetSubnet]
        public var devices: [AssetDevice]
        public var diagnosticRuns: [DiagnosticRun]
    }

    private let repository: any AssetRepository
    private var scheduleBackgroundSave: ((AssetSnapshot) -> Void)?
    @MainActor private var openingTask: Task<Void, Never>?
    @MainActor private var restoreTask: Task<Void, Error>?
    @MainActor private var saveTask: Task<Void, Never>?
    @MainActor private var pendingSnapshot: AssetSnapshot?
    private var hasLoadedWorkspace = false
    private var deferredDiagnosticCompletions: [UUID: DiagnosticRun] = [:]

    public convenience init(storageURL: URL? = nil) {
        if let storageURL, storageURL.pathExtension.lowercased() == "json" {
            self.init(repository: JSONAssetRepository(url: storageURL))
        } else {
            self.init(repository: Self.sqliteRepository(storageURL: storageURL))
        }
    }

    private static func sqliteRepository(storageURL: URL? = nil) -> SQLiteAssetRepository {
        let directory = SettingsStore.resolvedSupportDirectory()
        return SQLiteAssetRepository(
            url: storageURL ?? directory.appendingPathComponent("assets.sqlite"),
            legacyURL: storageURL == nil ? directory.appendingPathComponent("assets.json") : nil,
            requiresExclusiveOwnership: storageURL == nil)
    }

    public convenience init(repository: any AssetRepository) {
        self.init(repository: repository, loading: false)
        load(seedIfEmpty: true)
    }

    @MainActor
    package convenience init(openingInBackground repository: any AssetRepository) {
        self.init(repository: repository, loading: true)
        let enqueue: @MainActor @Sendable (AssetSnapshot) -> Void = { [weak self] value in
            self?.enqueueSave(value)
        }
        scheduleBackgroundSave = { value in MainActor.assumeIsolated { enqueue(value) } }
        startOpeningWorkspace()
    }

    private init(repository: any AssetRepository, loading: Bool) {
        self.repository = repository
        isLoadingWorkspace = loading
    }

    public var canEditWorkspace: Bool {
        workspaceAccessError == nil && recoveryError == nil && !isLoadingWorkspace && !isRestoringBackup
    }

    /// A blocked window can be opened after the owner quits, without replacing
    /// the database or clearing its error before ownership has been acquired.
    public func retryWorkspaceAccess() {
        guard workspaceAccessError != nil else { return }
        load(seedIfEmpty: true)
    }

    @MainActor
    public func retryWorkspaceAccessInBackground() async {
        guard workspaceAccessError != nil, !isLoadingWorkspace else { return }
        isLoadingWorkspace = true
        await startOpeningWorkspace().value
    }

    private var snapshot: AssetSnapshot {
        AssetSnapshot(workspaces: workspaces, sites: sites, subnets: subnets, devices: devices, diagnosticRuns: diagnosticRuns)
    }

    private func apply(_ snapshot: AssetSnapshot) {
        workspaces = snapshot.workspaces
        sites = snapshot.sites
        subnets = snapshot.subnets
        devices = snapshot.devices
        diagnosticRuns = snapshot.diagnosticRuns
    }

    public func diagnosticPage(_ query: DiagnosticPageQuery = DiagnosticPageQuery()) throws -> [DiagnosticRun] {
        try requireWorkspaceAccess()
        guard !isRestoringBackup else { throw AssetBackupError.restoreInProgress }
        guard !isSavingWorkspace else { throw WorkspaceBusy(message: t("Save")) }
        return try repository.diagnosticPage(query)
    }

    @MainActor
    package func diagnosticHistoryPage(_ filter: DiagnosticHistorySearch.Filter, offset: Int) async throws -> [DiagnosticRun] {
        try requireWorkspaceAccess()
        if filter.usesIndex && persistenceError == nil && !isRestoringBackup && !isSavingWorkspace {
            let query = DiagnosticPageQuery(scope: filter.workspaceID.map(DiagnosticPageQuery.Scope.workspace) ?? .all,
                                            limit: 51, offset: offset)
            let revision = diagnosticHistoryRevision
            let repository = self.repository
            let runs = try await Task.detached(priority: .userInitiated) { try repository.diagnosticPage(query) }.value
            if !isRestoringBackup && revision == diagnosticHistoryRevision { return runs }
        }
        let snapshot = self.snapshot
        return await Task.detached(priority: .userInitiated) {
            Array(filter.matchingRuns(in: snapshot).dropFirst(offset).prefix(51))
        }.value
    }

    @MainActor
    package func exportDiagnosticHistory(_ filter: DiagnosticHistorySearch.Filter, markdown: Bool) async throws -> Data {
        try requireWorkspaceAccess()
        let snapshot = self.snapshot
        return try await Task.detached(priority: .userInitiated) {
            let runs = filter.matchingRuns(in: snapshot)
            if markdown { return Data(DiagnosticEvidenceExporter.markdown(runs: runs, devices: snapshot.devices).utf8) }
            return try DiagnosticEvidenceExporter.json(runs: runs, devices: snapshot.devices)
        }.value
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
        guard let workspace = primaryWorkspace else { return false }
        return externalDeviceIndex(for: snapshot, workspaceID: workspace.id) != nil
    }

    public func searchDevices(_ query: String) -> [AssetDevice] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return devices }
        return devices.filter { device in
            ([device.name, device.address, device.vendor, device.role, device.kind.displayName] +
             (device.sourcePrimaryAddresses ?? []).map(\.cidr) + (device.networkInventory?.addresses ?? []).map(\.cidr))
                .contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    public func upsert(_ workspace: OperationsWorkspace) { guard canEditWorkspace else { return }; replace(workspace, in: &workspaces); save() }
    public func upsert(_ site: AssetSite) { guard canEditWorkspace else { return }; replace(site, in: &sites); save() }
    public func upsert(_ subnet: AssetSubnet) { guard canEditWorkspace else { return }; replace(subnet, in: &subnets); save() }
    public func upsert(_ device: AssetDevice) {
        guard canEditWorkspace else { return }
        var value = device
        value.updatedAt = Date()
        replace(value, in: &devices)
        save()
    }

    @discardableResult
    package func applyLibreNMSLinks(_ snapshot: LibreNMSLinkSnapshot, to deviceID: UUID) -> Bool {
        guard canEditWorkspace, let index = devices.firstIndex(where: { $0.id == deviceID }),
              devices[index].libreNMSLinks.map({ $0.fetchedAt <= snapshot.fetchedAt }) ?? true else { return false }
        devices[index].libreNMSLinks = snapshot
        save()
        return true
    }

    /// Merge read-only records from an external source without overwriting
    /// user-authored fields on an existing local device.
    @discardableResult
    public func mergeExternalAssets(_ snapshots: [ExternalAssetSnapshot]) -> Int {
        guard canEditWorkspace, let workspace = primaryWorkspace else { return 0 }
        var changed = 0
        var needsSave = false
        for snapshot in snapshots {
            guard snapshot.externalIdentity?.isValid != false else { continue }
            guard snapshot.sourcePrimaryAddresses.map({ $0.count <= 2 && $0.allSatisfy(\.isValid) }) != false,
                  snapshot.networkInventory.map({ $0.isValid && $0.deviceIdentity == snapshot.externalIdentity }) != false else { continue }
            if let index = externalDeviceIndex(for: snapshot, workspaceID: workspace.id) {
                // Expanded inventory can arrive after the basic preview with the same source date.
                if let inventory = snapshot.networkInventory,
                   devices[index].networkInventory.map({ inventory.fetchedAt > $0.fetchedAt }) ?? true {
                    devices[index].networkInventory = inventory
                    needsSave = true
                }
                guard devices[index].sourceFetchedAt.map({ snapshot.fetchedAt > $0 }) ?? true else { continue }
                if snapshot.externalIdentity != nil {
                    if devices[index].address == devices[index].sourceAddress {
                        devices[index].address = snapshot.address
                    }
                    devices[index].sourceAddress = snapshot.address
                }
                devices[index].sourceFetchedAt = snapshot.fetchedAt
                if let primary = snapshot.sourcePrimaryAddresses { devices[index].sourcePrimaryAddresses = primary }
                if devices[index].vendor.isEmpty { devices[index].vendor = snapshot.vendor }
                if devices[index].role.isEmpty { devices[index].role = snapshot.role }
                needsSave = true
                continue
            }
            let site = matchingSite(for: snapshot, workspaceID: workspace.id)
                ?? AssetSite(workspaceID: workspace.id, name: snapshot.siteName, location: snapshot.siteLocation)
            if !sites.contains(where: { $0.id == site.id }) {
                sites.append(site)
                needsSave = true
            }

            devices.append(AssetDevice(
                    siteID: site.id,
                    name: snapshot.deviceName,
                    address: snapshot.address,
                    kind: snapshot.kind,
                    vendor: snapshot.vendor,
                    role: snapshot.role,
                    source: snapshot.source,
                    sourceFetchedAt: snapshot.fetchedAt,
                    externalIdentity: snapshot.externalIdentity,
                    sourceAddress: snapshot.externalIdentity == nil ? nil : snapshot.address,
                    sourcePrimaryAddresses: snapshot.sourcePrimaryAddresses,
                    networkInventory: snapshot.networkInventory,
                    createdAt: snapshot.fetchedAt,
                    updatedAt: snapshot.fetchedAt
            ))
            changed += 1
            needsSave = true
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

    private func externalDeviceIndex(for snapshot: ExternalAssetSnapshot, workspaceID: UUID) -> Int? {
        let workspaceSites = Set(sites(in: workspaceID).map(\.id))
        let site = matchingSite(for: snapshot, workspaceID: workspaceID)
        return devices.firstIndex { device in
            guard workspaceSites.contains(device.siteID) else { return false }
            if let identity = snapshot.externalIdentity {
                return device.externalIdentity == identity
            }
            return device.externalIdentity == nil && device.siteID == site?.id &&
                device.address.caseInsensitiveCompare(snapshot.address) == .orderedSame &&
                device.source == snapshot.source
        }
    }

    /// Delete a device and all diagnostic evidence attached to it.
    public func removeDevice(id: UUID) {
        guard canEditWorkspace else { return }
        devices.removeAll { $0.id == id }
        diagnosticRuns.removeAll { $0.deviceID == id }
        save()
    }

    /// Delete a subnet and detach devices that referenced it.
    public func removeSubnet(id: UUID) {
        guard canEditWorkspace else { return }
        subnets.removeAll { $0.id == id }
        for index in devices.indices where devices[index].subnetID == id {
            devices[index].subnetID = nil
        }
        save()
    }

    /// Delete a site and its subnets, devices, and diagnostic evidence.
    public func removeSite(id: UUID) {
        guard canEditWorkspace else { return }
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
        guard canEditWorkspace else { return }
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
        guard canEditWorkspace else { return run.id }
        diagnosticRuns.append(run)
        save()
        return run.id
    }

    public func finishDiagnostic(id: UUID, status: DiagnosticRunStatus, summary: String, detail: String = "", latency: TimeInterval? = nil, source: String = "NETworkManager", evidence: DiagnosticRuntimeEvidence? = nil) {
        guard workspaceAccessError == nil, recoveryError == nil,
              let index = diagnosticRuns.firstIndex(where: { $0.id == id }) else { return }
        var run = diagnosticRuns[index]
        run.status = status
        run.finishedAt = Date()
        run.summary = summary
        run.detail = detail
        run.latency = latency
        run.source = source
        run.evidence = evidence
        if isRestoringBackup {
            deferredDiagnosticCompletions[id] = run
            return
        }
        diagnosticRuns[index] = run
        save()
    }

    public func load() { load(seedIfEmpty: false) }

    private func load(seedIfEmpty: Bool) {
        guard !isLoadingWorkspace, !isRestoringBackup, !isSavingWorkspace else { return }
        defer { diagnosticHistoryRevision += 1 }
        do {
            let (value, saveError) = try Self.readWorkspace(repository, firstOpen: !hasLoadedWorkspace, seedIfEmpty: seedIfEmpty)
            publishOpenedWorkspace(value, saveError: saveError)
        } catch {
            publishOpenFailure(error)
        }
    }

    @MainActor
    @discardableResult
    private func startOpeningWorkspace() -> Task<Void, Never> {
        let task = Task {
            await openWorkspaceInBackground()
            openingTask = nil
        }
        openingTask = task
        return task
    }

    @MainActor
    private func openWorkspaceInBackground() async {
        defer {
            isLoadingWorkspace = false
            diagnosticHistoryRevision += 1
        }
        let repository = self.repository
        let firstOpen = !hasLoadedWorkspace
        do {
            let (value, saveError) = try await Task.detached(priority: .userInitiated) {
                try Self.readWorkspace(repository, firstOpen: firstOpen, seedIfEmpty: true)
            }.value
            publishOpenedWorkspace(value, saveError: saveError)
        } catch {
            publishOpenFailure(error)
        }
    }

    private static func readWorkspace(_ repository: any AssetRepository, firstOpen: Bool, seedIfEmpty: Bool) throws -> (AssetSnapshot?, String?) {
        var value = try repository.load()
        var needsSave = false
        if seedIfEmpty && (value?.workspaces.isEmpty ?? true) {
            var seed = localWorkspaceSnapshot()
            seed.diagnosticRuns = value?.diagnosticRuns ?? []
            value = seed
            needsSave = true
        }
        guard var value else { return (nil, nil) }
        if firstOpen {
            for index in value.diagnosticRuns.indices where value.diagnosticRuns[index].status == .running {
                value.diagnosticRuns[index].status = .interrupted
                value.diagnosticRuns[index].finishedAt = Date()
                value.diagnosticRuns[index].summary = t("Interrupted when app closed")
                needsSave = true
            }
        }
        return (value, needsSave ? Self.commit(value, to: repository) : nil)
    }

    private func publishOpenedWorkspace(_ value: AssetSnapshot?, saveError: String?) {
        workspaceAccessError = nil
        workspaceAccessFailure = nil
        recoveryError = nil
        persistenceError = saveError
        hasLoadedWorkspace = true
        if let value { apply(value) }
        logWorkspaceState("ready")
    }

    private func publishOpenFailure(_ error: Error) {
        if let error = error as? AssetWorkspaceAccessError {
            workspaceAccessFailure = error
            workspaceAccessError = error.localizedDescription
            switch error {
            case .inUse: logWorkspaceState("access blocked: in-use")
            case .unavailable: logWorkspaceState("access blocked: unavailable")
            }
            return
        }
        // A retry after contention can acquire ownership and then encounter damage.
        workspaceAccessFailure = nil
        workspaceAccessError = nil
        recoveryError = tf("Asset data could not be read. The original file was preserved. Import a valid backup to restore this workspace. (%@)", error.localizedDescription)
        logWorkspaceState("recovery required")
    }

    public func exportBackup() throws -> Data {
        try Self.encodeBackup(backupForExport())
    }

    @MainActor
    public func exportBackupInBackground() async throws -> Data {
        let backup = try backupForExport()
        return try await Task.detached(priority: .userInitiated) {
            try Self.encodeBackup(backup)
        }.value
    }

    private func backupForExport() throws -> BackupDocument {
        try requireWorkspaceAccess()
        return BackupDocument(formatVersion: 1, exportedAt: Date(), workspaces: workspaces, sites: sites, subnets: subnets, devices: devices, diagnosticRuns: diagnosticRuns)
    }

    private static func encodeBackup(_ backup: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    public func importBackup(_ data: Data) throws {
        try requireWorkspaceAccess()
        guard !isRestoringBackup else { throw AssetBackupError.restoreInProgress }
        guard !isSavingWorkspace else { throw WorkspaceBusy(message: t("Save")) }
        let restored = try Self.decodeBackup(data)
        let preserved = try repository.restore(restored, preservingDamaged: recoveryError != nil)
        publishRestoredBackup(restored, preserved: preserved)
    }

    @MainActor
    public func importBackupInBackground(from url: URL) async throws {
        try requireWorkspaceAccess()
        guard !isRestoringBackup else { throw AssetBackupError.restoreInProgress }
        isRestoringBackup = true
        let task = Task {
            defer { restoreTask = nil }
            await saveTask?.value
            try await restoreBackup(from: url)
        }
        restoreTask = task
        try await task.value
    }

    @MainActor
    private func restoreBackup(from url: URL) async throws {
        let repository = self.repository
        let preservingDamaged = recoveryError != nil
        do {
            let (restored, preserved) = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let snapshot = try Self.decodeBackup(Data(contentsOf: url))
                return (snapshot, try repository.restore(snapshot, preservingDamaged: preservingDamaged))
            }.value
            // The imported snapshot replaces the old workspace, including its diagnostic history.
            deferredDiagnosticCompletions.removeAll()
            publishRestoredBackup(restored, preserved: preserved)
            isRestoringBackup = false
        } catch {
            let completions = deferredDiagnosticCompletions
            deferredDiagnosticCompletions.removeAll()
            isRestoringBackup = false
            if !completions.isEmpty {
                diagnosticRuns = diagnosticRuns.map { completions[$0.id] ?? $0 }
                save()
            }
            throw error
        }
    }

    private static func decodeBackup(_ data: Data) throws -> AssetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupDocument.self, from: data)
        guard backup.formatVersion == 1 else { throw AssetBackupError.unsupportedVersion(backup.formatVersion) }
        guard !backup.workspaces.isEmpty else { throw AssetBackupError.emptyWorkspace }
        return AssetSnapshot(workspaces: backup.workspaces, sites: backup.sites, subnets: backup.subnets, devices: backup.devices, diagnosticRuns: backup.diagnosticRuns)
    }

    private func publishRestoredBackup(_ restored: AssetSnapshot, preserved: URL?) {
        preservedCorruptFileURL = preserved
        apply(restored)
        hasLoadedWorkspace = true
        recoveryError = nil
        persistenceError = nil
        diagnosticHistoryRevision += 1
    }

    public func save() {
        guard canEditWorkspace else { return }
        defer { diagnosticHistoryRevision += 1 }
        let value = snapshot
        if let scheduleBackgroundSave {
            scheduleBackgroundSave(value)
            return
        }
        persistenceError = Self.commit(value, to: repository)
    }

    @MainActor
    package func waitForWorkspaceWrites() async {
        while isLoadingWorkspace || isRestoringBackup || isSavingWorkspace {
            await openingTask?.value
            _ = await restoreTask?.result
            await saveTask?.value
        }
    }

    @MainActor
    private func enqueueSave(_ value: AssetSnapshot) {
        pendingSnapshot = value
        guard saveTask == nil else { return }
        isSavingWorkspace = true
        let repository = self.repository
        saveTask = Task {
            while let value = pendingSnapshot {
                pendingSnapshot = nil
                persistenceError = await Task.detached(priority: .userInitiated) { Self.commit(value, to: repository) }.value
            }
            saveTask = nil
            isSavingWorkspace = false
        }
    }

    private static func commit(_ value: AssetSnapshot, to repository: any AssetRepository) -> String? {
        do {
            try repository.save(value)
            return nil
        } catch {
            return tf("Asset workspace could not be saved: %@", error.localizedDescription)
        }
    }

    private var workspaceAccessFailure: AssetWorkspaceAccessError?

    private func logWorkspaceState(_ state: String) {
        // Stable lifecycle evidence without paths or workspace contents.
        FileHandle.standardError.write(Data("[assets] workspace \(state)\n".utf8))
    }

    private func requireWorkspaceAccess() throws {
        if isLoadingWorkspace { throw WorkspaceBusy(message: t("Loading…")) }
        if let workspaceAccessFailure { throw workspaceAccessFailure }
    }

    private struct WorkspaceBusy: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func localWorkspaceSnapshot() -> AssetSnapshot {
        let workspace = OperationsWorkspace(name: "Local operations")
        let site = AssetSite(workspaceID: workspace.id, name: "This Mac", location: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let device = AssetDevice(siteID: site.id, name: site.location, address: "127.0.0.1", kind: .workstation, vendor: "Apple", role: "Operator workstation")
        return AssetSnapshot(workspaces: [workspace], sites: [site], devices: [device])
    }

    private func replace<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
    }
}

public enum AssetBackupError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case emptyWorkspace
    case restoreInProgress

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported asset backup version: \(version)."
        case .emptyWorkspace: return "Asset backup does not contain a workspace."
        case .restoreInProgress: return t("Local workspace is unavailable")
        }
    }
}
