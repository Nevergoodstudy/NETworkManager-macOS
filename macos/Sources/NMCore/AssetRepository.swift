import Foundation

/// The persisted boundary shared by the legacy JSON and SQLite repositories.
/// Array order is significant: the first workspace is the active workspace.
public struct AssetSnapshot: Codable, Equatable, Sendable {
    public var workspaces: [OperationsWorkspace]
    public var sites: [AssetSite]
    public var subnets: [AssetSubnet]
    public var devices: [AssetDevice]
    public var diagnosticRuns: [DiagnosticRun]

    public init(workspaces: [OperationsWorkspace] = [], sites: [AssetSite] = [], subnets: [AssetSubnet] = [], devices: [AssetDevice] = [], diagnosticRuns: [DiagnosticRun] = []) {
        self.workspaces = workspaces
        self.sites = sites
        self.subnets = subnets
        self.devices = devices
        self.diagnosticRuns = diagnosticRuns
    }

    public func validate() throws {
        func ids<T: Identifiable>(_ records: [T]) throws -> Set<UUID> where T.ID == UUID {
            let result = Set(records.map(\.id))
            guard result.count == records.count else { throw AssetRepositoryError.invalidRelationships }
            return result
        }
        let workspaceIDs = try ids(workspaces)
        let siteIDs = try ids(sites)
        _ = try ids(subnets)
        let deviceIDs = try ids(devices)
        _ = try ids(diagnosticRuns)
        let subnetSites = Dictionary(uniqueKeysWithValues: subnets.map { ($0.id, $0.siteID) })
        guard sites.allSatisfy({ workspaceIDs.contains($0.workspaceID) }),
              subnets.allSatisfy({ siteIDs.contains($0.siteID) }),
              devices.allSatisfy({ device in
                  siteIDs.contains(device.siteID) && (device.subnetID.map { subnetSites[$0] == device.siteID } ?? true)
              }),
              diagnosticRuns.allSatisfy({ $0.deviceID.map(deviceIDs.contains) ?? true }) else {
            throw AssetRepositoryError.invalidRelationships
        }
    }

    static func decodeLegacy(_ data: Data) throws -> AssetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value: AssetSnapshot
        do { value = try decoder.decode(AssetSnapshot.self, from: data) }
        catch { value = try JSONDecoder().decode(AssetSnapshot.self, from: data) }
        try value.validate()
        return value
    }
}

public struct DiagnosticPageQuery: Sendable {
    public enum Scope: Sendable { case all, device(UUID), workspace(UUID) }
    public var scope: Scope
    public var limit: Int
    public var offset: Int

    public init(scope: Scope = .all, limit: Int = 50, offset: Int = 0) {
        self.scope = scope
        self.limit = limit
        self.offset = offset
    }

    func validate() throws {
        guard (1...500).contains(limit), offset >= 0 else { throw AssetRepositoryError.invalidPage }
    }
}

/// Writes return only after commit. Implementations own their I/O serialization;
/// callers must reload after a conflict rather than overwrite another writer.
public protocol AssetRepository: AnyObject {
    func load() throws -> AssetSnapshot?
    func save(_ snapshot: AssetSnapshot) throws
    @discardableResult func restore(_ snapshot: AssetSnapshot, preservingDamaged: Bool) throws -> URL?
    func diagnosticPage(_ query: DiagnosticPageQuery) throws -> [DiagnosticRun]
}

public enum AssetRepositoryError: LocalizedError {
    case invalidRelationships, invalidPage, conflict, missingDatabase, unsupportedSchema(Int), invalidDatabase
    case sqlite(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelationships: return "Asset data contains duplicate IDs or invalid relationships."
        case .invalidPage: return "History pages require a limit of 1–500 and a nonnegative offset."
        case .conflict: return "Asset data changed in another instance. Reload before saving."
        case .missingDatabase: return "The initialized asset database is missing. Restore a backup before saving."
        case .unsupportedSchema(let version): return "Unsupported asset database schema: \(version)."
        case .invalidDatabase: return "The asset database is damaged or belongs to another application."
        case .sqlite(let code, let message): return "Asset database error \(code): \(message)"
        }
    }
}

/// Compatibility adapter for explicitly selected .json files and old fixtures.
public final class JSONAssetRepository: AssetRepository {
    private let url: URL
    private let queue = DispatchQueue(label: "NETworkManager.assets.json")

    public init(url: URL) { self.url = url }

    public func load() throws -> AssetSnapshot? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try AssetSnapshot.decodeLegacy(Data(contentsOf: url))
        }
    }

    public func save(_ snapshot: AssetSnapshot) throws {
        try queue.sync { try write(snapshot) }
    }

    public func restore(_ snapshot: AssetSnapshot, preservingDamaged: Bool) throws -> URL? {
        try queue.sync {
            try snapshot.validate()
            let preserved = preservingDamaged && FileManager.default.fileExists(atPath: url.path)
                ? url.appendingPathExtension("corrupt-\(UUID().uuidString)") : nil
            if let preserved { try FileManager.default.copyItem(at: url, to: preserved) }
            try write(snapshot)
            return preserved
        }
    }

    private func write(_ snapshot: AssetSnapshot) throws {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func diagnosticPage(_ query: DiagnosticPageQuery) throws -> [DiagnosticRun] {
        try query.validate()
        guard let snapshot = try load() else { return [] }
        let matching: [DiagnosticRun]
        switch query.scope {
        case .all: matching = snapshot.diagnosticRuns
        case .device(let id): matching = snapshot.diagnosticRuns.filter { $0.deviceID == id }
        case .workspace(let id):
            let sites = Set(snapshot.sites.filter { $0.workspaceID == id }.map(\.id))
            let devices = Set(snapshot.devices.filter { sites.contains($0.siteID) }.map(\.id))
            matching = snapshot.diagnosticRuns.filter { $0.deviceID.map(devices.contains) ?? false }
        }
        return Array(matching.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }.dropFirst(query.offset).prefix(query.limit))
    }
}
