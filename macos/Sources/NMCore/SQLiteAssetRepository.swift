import Foundation
import Darwin
import CSQLite

/// A synchronous facade over one serial I/O queue. The file lock coordinates
/// repository instances; a revision token rejects writes based on stale snapshots.
public final class SQLiteAssetRepository: AssetRepository {
    public let url: URL
    private let legacyURL: URL?
    private let ownership: AssetWorkspaceOwnership?
    private let queue = DispatchQueue(label: "NETworkManager.assets.sqlite", qos: .utility)
    private var baseline: AssetSnapshot?
    private var revision: String?
    private let applicationID = 0x4E4D4153
    private var markerURL: URL { url.appendingPathExtension("initialized") }
    private var restoreMarkerURL: URL { url.appendingPathExtension("restore-pending") }

    public init(url: URL, legacyURL: URL? = nil, requiresExclusiveOwnership: Bool = false) {
        self.url = url
        self.legacyURL = legacyURL
        ownership = requiresExclusiveOwnership ? AssetWorkspaceOwnership(databaseURL: url) : nil
    }

    public func load() throws -> AssetSnapshot? {
        try queue.sync { try withFileLock {
            try bootstrap()
            return try withDatabase { db in
                let snapshot = try readSnapshot(db)
                baseline = snapshot
                revision = try db.string("SELECT value FROM metadata WHERE key='revision'")
                return snapshot
            }
        } }
    }

    public func save(_ snapshot: AssetSnapshot) throws {
        try queue.sync { try withFileLock {
            try snapshot.validate()
            try bootstrap()
            try withDatabase { db in
                if baseline == nil {
                    baseline = try readSnapshot(db)
                    revision = try db.string("SELECT value FROM metadata WHERE key='revision'")
                }
                let nextRevision = UUID().uuidString
                try db.transaction {
                    guard try db.string("SELECT value FROM metadata WHERE key='revision'") == revision else {
                        throw AssetRepositoryError.conflict
                    }
                    try writeDelta(snapshot, from: baseline ?? AssetSnapshot(), db: db)
                    try db.execute("UPDATE metadata SET value=? WHERE key='revision'", [.text(nextRevision)])
                }
                baseline = snapshot
                revision = nextRevision
            }
        } }
    }

    public func diagnosticPage(_ query: DiagnosticPageQuery) throws -> [DiagnosticRun] {
        try query.validate()
        return try queue.sync { try withFileLock {
            try bootstrap()
            return try withDatabase { db in
                var sql = "SELECT r.id,r.payload,r.device_id,r.started_at FROM diagnostic_runs r"
                var bindings: [SQLValue] = []
                switch query.scope {
                case .all: break
                case .device(let id):
                    sql += " WHERE r.device_id=?"
                    bindings.append(.text(id.uuidString))
                case .workspace(let id):
                    // Walk the history's ordering index and check membership.
                    // A parent-first join sorts the entire matching history
                    // before returning even a small page at large offsets.
                    sql += " INDEXED BY runs_date WHERE EXISTS (SELECT 1 FROM devices d JOIN sites s ON s.id=d.site_id WHERE d.id=r.device_id AND s.workspace_id=?)"
                    bindings.append(.text(id.uuidString))
                }
                sql += " ORDER BY r.started_at DESC,r.id ASC LIMIT ? OFFSET ?"
                bindings += [.integer(Int64(query.limit)), .integer(Int64(query.offset))]
                return try db.records(sql, bindings, verifying: Self.runColumns)
            }
        } }
    }

    /// SQLite's online backup API includes committed WAL pages. A filesystem
    /// copy of only assets.sqlite would omit those pages while a writer is open.
    public func createBackup(at destination: URL) throws {
        try queue.sync { try withFileLock {
            try bootstrap()
            let temporary = destination.appendingPathExtension("staging-\(UUID().uuidString)")
            defer { removeDatabaseFiles(temporary) }
            try withDatabase { source in
                let target = try AssetDatabase(url: temporary, create: true)
                guard let backup = sqlite3_backup_init(target.handle, "main", source.handle, "main") else {
                    throw target.error()
                }
                let result = sqlite3_backup_step(backup, -1)
                let finished = sqlite3_backup_finish(backup)
                guard result == SQLITE_DONE, finished == SQLITE_OK else { throw target.error() }
                // The source header may describe WAL mode. Normalize this
                // standalone artifact before publishing just its main file.
                try target.execute("PRAGMA journal_mode=DELETE")
                try target.close()
            }
            try publish(temporary, at: destination)
        } }
    }

    public func restore(_ snapshot: AssetSnapshot, preservingDamaged: Bool) throws -> URL? {
        try queue.sync { try withFileLock {
            try snapshot.validate()
            if !preservingDamaged {
                // Keep ordinary imports transactional and preserve a newer writer.
                try bootstrap()
                try withDatabase { db in
                    let current = try readSnapshot(db)
                    let token = try db.string("SELECT value FROM metadata WHERE key='revision'")
                    if let revision, token != revision { throw AssetRepositoryError.conflict }
                    let next = UUID().uuidString
                    try db.transaction {
                        try writeDelta(snapshot, from: current, db: db)
                        try db.execute("UPDATE metadata SET value=? WHERE key='revision'", [.text(next)])
                    }
                    baseline = snapshot
                    revision = next
                }
                return nil
            }

            let temporary = url.appendingPathExtension("restore-\(UUID().uuidString)")
            defer { removeDatabaseFiles(temporary) }
            try buildDatabase(at: temporary, snapshot: snapshot)
            let source = FileManager.default.fileExists(atPath: url.path) ? url : legacyURL
            var preserved: URL?
            if let source, FileManager.default.fileExists(atPath: source.path) {
                let copy = source.appendingPathExtension("corrupt-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: source, to: copy)
                for suffix in ["-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: source.path + suffix) {
                    try FileManager.default.copyItem(atPath: source.path + suffix, toPath: copy.path + suffix)
                }
                preserved = copy
            }
            // If interrupted between swapping the main file and its sidecars,
            // startup refuses to open it. All original bytes are already copied.
            try Data((preserved?.path ?? "restore").utf8).write(to: restoreMarkerURL, options: .atomic)
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
            for suffix in ["-wal", "-shm", "-journal"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
            try Data("1".utf8).write(to: markerURL, options: .atomic)
            try FileManager.default.removeItem(at: restoreMarkerURL)
            baseline = nil
            revision = nil
            return preserved
        } }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        // Default GUI access must own the workspace before even bootstrap or
        // startup recovery. Explicit repositories retain revision semantics.
        try ownership?.acquire()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func bootstrap() throws {
        guard !FileManager.default.fileExists(atPath: restoreMarkerURL.path) else { throw AssetRepositoryError.invalidDatabase }
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { throw AssetRepositoryError.missingDatabase }
        let snapshot: AssetSnapshot
        if let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            snapshot = try AssetSnapshot.decodeLegacy(Data(contentsOf: legacyURL))
        } else { snapshot = AssetSnapshot() }
        let temporary = url.appendingPathExtension("migration-\(UUID().uuidString)")
        defer { removeDatabaseFiles(temporary) }
        try buildDatabase(at: temporary, snapshot: snapshot)
        // link() publishes without overwriting a concurrently created database.
        try publish(temporary, at: url)
        try Data("1".utf8).write(to: markerURL, options: .atomic)
    }

    private func buildDatabase(at path: URL, snapshot: AssetSnapshot) throws {
        try snapshot.validate()
        let db = try AssetDatabase(url: path, create: true)
        defer { try? db.close() }
        try db.execute("PRAGMA journal_mode=DELETE")
        try db.execute("PRAGMA synchronous=FULL")
        try db.transaction {
            try db.execute("PRAGMA application_id=\(applicationID)")
            try db.execute("PRAGMA user_version=1")
            try db.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try db.execute("INSERT INTO metadata VALUES('revision',?)", [.text(UUID().uuidString)])
            try db.execute("CREATE TABLE workspaces(id TEXT PRIMARY KEY,ordinal INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE sites(id TEXT PRIMARY KEY,workspace_id TEXT NOT NULL REFERENCES workspaces(id) DEFERRABLE INITIALLY DEFERRED,ordinal INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE subnets(id TEXT PRIMARY KEY,site_id TEXT NOT NULL REFERENCES sites(id) DEFERRABLE INITIALLY DEFERRED,ordinal INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE devices(id TEXT PRIMARY KEY,site_id TEXT NOT NULL REFERENCES sites(id) DEFERRABLE INITIALLY DEFERRED,subnet_id TEXT REFERENCES subnets(id) DEFERRABLE INITIALLY DEFERRED,ordinal INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE diagnostic_runs(id TEXT PRIMARY KEY,device_id TEXT REFERENCES devices(id) DEFERRABLE INITIALLY DEFERRED,started_at REAL NOT NULL,ordinal INTEGER NOT NULL,payload BLOB NOT NULL)")
            try db.execute("CREATE INDEX sites_workspace ON sites(workspace_id)")
            try db.execute("CREATE INDEX devices_site ON devices(site_id)")
            try db.execute("CREATE INDEX runs_date ON diagnostic_runs(started_at DESC,id ASC)")
            try db.execute("CREATE INDEX runs_device_date ON diagnostic_runs(device_id,started_at DESC,id ASC)")
            try writeDelta(snapshot, from: AssetSnapshot(), db: db)
        }
        guard try readSnapshot(db) == snapshot else { throw AssetRepositoryError.invalidDatabase }
        try db.close()
    }

    private func withDatabase<T>(_ body: (AssetDatabase) throws -> T) throws -> T {
        // A future schema must be rejected without opening a writable handle
        // that could recover a hot journal or checkpoint its WAL on close.
        do {
            let inspection = try AssetDatabase(url: url, create: false, readOnly: true)
            defer { try? inspection.close() }
            try validateSchema(inspection)
        }
        let db = try AssetDatabase(url: url, create: false)
        defer { try? db.close() }
        try validateSchema(db)
        // Only validated, supported databases may have their journal mode changed.
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=FULL")
        if !FileManager.default.fileExists(atPath: markerURL.path) {
            try Data("1".utf8).write(to: markerURL, options: .atomic)
        }
        return try body(db)
    }

    private func validateSchema(_ db: AssetDatabase) throws {
        guard try db.integer("PRAGMA application_id") == applicationID else { throw AssetRepositoryError.invalidDatabase }
        let version = try db.integer("PRAGMA user_version")
        guard version == 1 else { throw AssetRepositoryError.unsupportedSchema(version) }
    }

    private static func runColumns(_ run: DiagnosticRun) -> [SQLValue] {
        [run.deviceID.map { .text($0.uuidString) } ?? .null, .real(run.startedAt.timeIntervalSince1970)]
    }

    private func readSnapshot(_ db: AssetDatabase) throws -> AssetSnapshot {
        guard try db.string("PRAGMA quick_check") == "ok", try db.isEmpty("PRAGMA foreign_key_check") else {
            throw AssetRepositoryError.invalidDatabase
        }
        let snapshot = AssetSnapshot(
            workspaces: try db.records("SELECT id,payload FROM workspaces ORDER BY ordinal"),
            sites: try db.records("SELECT id,payload,workspace_id FROM sites ORDER BY ordinal", verifying: { [.text($0.workspaceID.uuidString)] }),
            subnets: try db.records("SELECT id,payload,site_id FROM subnets ORDER BY ordinal", verifying: { [.text($0.siteID.uuidString)] }),
            devices: try db.records("SELECT id,payload,site_id,subnet_id FROM devices ORDER BY ordinal", verifying: {
                [.text($0.siteID.uuidString), $0.subnetID.map { .text($0.uuidString) } ?? .null]
            }),
            diagnosticRuns: try db.records("SELECT id,payload,device_id,started_at FROM diagnostic_runs ORDER BY ordinal", verifying: Self.runColumns))
        try snapshot.validate()
        return snapshot
    }

    private func writeDelta(_ snapshot: AssetSnapshot, from old: AssetSnapshot, db: AssetDatabase) throws {
        func remove<T: Identifiable>(_ old: [T], _ new: [T], table: String) throws where T.ID == UUID {
            let retained = Set(new.map(\.id))
            for record in old where !retained.contains(record.id) {
                try db.execute("DELETE FROM \(table) WHERE id=?", [.text(record.id.uuidString)])
            }
        }
        // Deferred foreign keys allow moves and detachments within one commit.
        try remove(old.diagnosticRuns, snapshot.diagnosticRuns, table: "diagnostic_runs")
        try remove(old.devices, snapshot.devices, table: "devices")
        try remove(old.subnets, snapshot.subnets, table: "subnets")
        try remove(old.sites, snapshot.sites, table: "sites")
        try remove(old.workspaces, snapshot.workspaces, table: "workspaces")

        func upsert<T: Identifiable & Encodable & Equatable>(_ records: [T], old: [T], table: String,
                                                          columns: [String] = [], values: (T) -> [SQLValue]) throws where T.ID == UUID {
            let previous = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
            let fields = ["id", "ordinal", "payload"] + columns
            let sql = "INSERT INTO \(table)(\(fields.joined(separator: ","))) VALUES(\(fields.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(id) DO UPDATE SET " + fields.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
            let encoder = JSONEncoder()
            for (index, record) in records.enumerated() {
                if let previous = previous[record.id], previous.0 == index, previous.1 == record { continue }
                // Encoding occurs on the repository queue and only for changed rows.
                try db.execute(sql, [.text(record.id.uuidString), .integer(Int64(index)), .blob(try encoder.encode(record))] + values(record))
            }
        }
        try upsert(snapshot.workspaces, old: old.workspaces, table: "workspaces") { _ in [] }
        try upsert(snapshot.sites, old: old.sites, table: "sites", columns: ["workspace_id"]) { [.text($0.workspaceID.uuidString)] }
        try upsert(snapshot.subnets, old: old.subnets, table: "subnets", columns: ["site_id"]) { [.text($0.siteID.uuidString)] }
        try upsert(snapshot.devices, old: old.devices, table: "devices", columns: ["site_id", "subnet_id"]) {
            [.text($0.siteID.uuidString), $0.subnetID.map { .text($0.uuidString) } ?? .null]
        }
        try upsert(snapshot.diagnosticRuns, old: old.diagnosticRuns, table: "diagnostic_runs", columns: ["device_id", "started_at"]) {
            [$0.deviceID.map { .text($0.uuidString) } ?? .null, .real($0.startedAt.timeIntervalSince1970)]
        }
    }

    private func publish(_ temporary: URL, at destination: URL) throws {
        guard Darwin.link(temporary.path, destination.path) == 0 else { throw posixError() }
    }

    private func removeDatabaseFiles(_ path: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private enum SQLValue {
    case text(String), blob(Data), integer(Int64), real(Double), null
}

private final class AssetDatabase {
    private(set) var handle: OpaquePointer?

    init(url: URL, create: Bool, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let failure = error()
            sqlite3_close(handle)
            handle = nil
            throw failure
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    func close() throws {
        guard handle != nil else { return }
        guard sqlite3_close(handle) == SQLITE_OK else { throw error() }
        handle = nil
    }

    func error() -> AssetRepositoryError {
        .sqlite(sqlite3_extended_errcode(handle), String(cString: sqlite3_errmsg(handle)))
    }

    private func statement(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                let result: Int32
                switch value {
                case .text(let value): result = sqlite3_bind_text(statement, position, value, -1, transient)
                case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
                case .integer(let value): result = sqlite3_bind_int64(statement, position, value)
                case .real(let value): result = sqlite3_bind_double(statement, position, value)
                case .null: result = sqlite3_bind_null(statement, position)
                }
                guard result == SQLITE_OK else { throw error() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw error() }
    }

    func string(_ sql: String) throws -> String {
        let statement = try statement(sql, [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: value)
    }

    func integer(_ sql: String) throws -> Int { Int(try string(sql)) ?? -1 }

    func isEmpty(_ sql: String) throws -> Bool {
        let statement = try statement(sql, [])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error() }
        return result == SQLITE_DONE
    }

    func records<T: Decodable & Identifiable>(_ sql: String, _ values: [SQLValue] = [], verifying: ((T) -> [SQLValue])? = nil) throws -> [T] where T.ID == UUID {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var records: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 1), let id = sqlite3_column_text(statement, 0) else {
                throw AssetRepositoryError.invalidDatabase
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            let value = try JSONDecoder().decode(T.self, from: data)
            guard value.id.uuidString == String(cString: id) else { throw AssetRepositoryError.invalidDatabase }
            if let verifying {
                for (index, expected) in verifying(value).enumerated() {
                    let column = Int32(index + 2)
                    let matches: Bool
                    switch expected {
                    case .text(let text): matches = sqlite3_column_text(statement, column).map { String(cString: $0) == text } ?? false
                    case .null: matches = sqlite3_column_type(statement, column) == SQLITE_NULL
                    case .real(let number): matches = sqlite3_column_type(statement, column) != SQLITE_NULL && sqlite3_column_double(statement, column) == number
                    case .integer(let number): matches = sqlite3_column_type(statement, column) == SQLITE_INTEGER && sqlite3_column_int64(statement, column) == number
                    case .blob: matches = false
                    }
                    guard matches else { throw AssetRepositoryError.invalidDatabase }
                }
            }
            records.append(value)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return records
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
