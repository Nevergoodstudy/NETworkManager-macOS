import CSQLite
import Darwin
import Foundation

public struct FieldCaseSource: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let loadedAt: Date
    public let revision: UUID
    public let caseCount: Int
    public let observationCount: Int
}

/// A bounded local library of explicitly imported, validated project snapshots.
/// Cases and observations retain their source + incident + entry identities.
/// Refresh requires the source revision the caller last saw; nil means new source.
public final class FieldCaseLibrary: @unchecked Sendable {
    public static let maximumSources = 200
    private let url: URL
    private let queue = DispatchQueue(label: "NETworkManager.field-cases")
    private let applicationID = 0x4e4d434c // NMCL; independent of the assets database

    public init(url: URL = SettingsStore.supportDirectory.appendingPathComponent("field-cases.sqlite")) {
        self.url = url
    }

    public func sources() throws -> [FieldCaseSource] {
        try access { db in
            try db.rows("""
                SELECT s.id,s.label,s.loaded_at,s.revision,
                    (SELECT count(*) FROM cases c WHERE c.source_id=s.id),
                    (SELECT count(*) FROM observations o WHERE o.source_id=s.id)
                FROM sources s ORDER BY s.label,s.id
                """) { row in
                guard let revision = UUID(uuidString: try Self.text(row, 3)) else { throw FieldCaseLibraryError.invalidDatabase }
                return FieldCaseSource(id: try Self.text(row, 0), label: try Self.text(row, 1),
                                       loadedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)), revision: revision,
                                       caseCount: Int(sqlite3_column_int64(row, 4)), observationCount: Int(sqlite3_column_int64(row, 5)))
            }
        }
    }

    @discardableResult
    public func importProject(_ project: FieldProject, from sourceURL: URL, expectedRevision: UUID?,
                              loadedAt: Date = Date()) throws -> UUID {
        let source = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL, source.absoluteString.count <= 4096, source.lastPathComponent.count <= 512,
              loadedAt.timeIntervalSinceReferenceDate.isFinite else { throw FieldIncidentSearchError.invalidSource }
        let data = try project.encoded()
        // Run the complete document validator, including legacy/checklist fields.
        let validated = try FieldProject.decode(data)
        return try access(writing: true) { db in
            let revision = UUID()
            try db.transaction {
                let revisions = try db.rows("SELECT revision FROM sources WHERE id=?", [.text(source.absoluteString)]) { try Self.text($0, 0) }
                guard revisions.first == expectedRevision?.uuidString else { throw FieldCaseLibraryError.conflict }
                if revisions.isEmpty {
                    guard try db.integer("SELECT count(*) FROM sources") < Self.maximumSources else { throw FieldCaseLibraryError.sourceLimit }
                }
                try db.execute("DELETE FROM sources WHERE id=?", [.text(source.absoluteString)])
                try db.execute("INSERT INTO sources VALUES(?,?,?,?,?)", [
                    .text(source.absoluteString), .text(source.lastPathComponent), .real(loadedAt.timeIntervalSince1970),
                    .text(revision.uuidString), .blob(data)
                ])
                let query = FieldIncidentQuery()
                for incident in validated.incidents {
                    let key: [SQLValue] = [.text(source.absoluteString), .text(incident.id.uuidString)]
                    try db.execute("INSERT INTO cases(source_id,id,status,device_key,device_id,created_at,latest_at,search_text,ticket_key) VALUES(?,?,?,?,?,?,?,?,?)", key + [
                        .text(incident.status.rawValue), incident.asset.map { .text(Self.deviceKey($0)) } ?? .null,
                        incident.asset.map { .text($0.deviceID.uuidString) } ?? .null,
                        .real(incident.createdAt.timeIntervalSince1970),
                        .real((incident.entries.map(\.occurredAt).max() ?? incident.createdAt).timeIntervalSince1970),
                        .text(query.searchText(for: incident)), .text(FieldIncidentQuery.ticketKey(incident.ticketReference))
                    ])
                    for entry in incident.entries {
                        try db.execute("INSERT INTO observations VALUES(?,?,?,?,?)", key + [
                            .text(entry.id.uuidString), .real(entry.occurredAt.timeIntervalSince1970),
                            .blob(try JSONEncoder().encode(entry))
                        ])
                    }
                }
            }
            return revision
        }
    }

    public func search(_ query: FieldIncidentQuery, limit: Int = 25, offset: Int = 0) throws -> FieldIncidentSearchPage {
        try query.validate(limit: limit, offset: offset)
        return try access { db in
            let (predicate, values) = Self.predicate(query)
            let totals = try db.rows("SELECT count(*) FROM cases c WHERE \(predicate)", values) { Int(sqlite3_column_int64($0, 0)) }
            let keys = try db.rows("""
                SELECT c.source_id,c.id FROM cases c WHERE \(predicate)
                ORDER BY c.latest_at DESC,c.source_id,c.id LIMIT ? OFFSET ?
                """, values + [.integer(Int64(limit)), .integer(Int64(offset))]) { row in
                (try Self.text(row, 0), try Self.text(row, 1))
            }
            var snapshots: [String: FieldIncidentSource] = [:]
            var results: [FieldIncidentSearchResult] = []
            for (sourceID, incidentID) in keys {
                let source: FieldIncidentSource
                if let cached = snapshots[sourceID] { source = cached }
                else {
                    guard let saved = try db.rows("SELECT label,loaded_at,project FROM sources WHERE id=?", [.text(sourceID)], decode: { row in
                        FieldIncidentSource(id: sourceID, label: try Self.text(row, 0),
                                            loadedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 1)),
                                            project: try FieldProject.decode(Self.blob(row, 2)))
                    }).first else { throw FieldCaseLibraryError.invalidDatabase }
                    source = saved
                    snapshots[sourceID] = saved
                }
                guard let incident = source.project.incidents.first(where: { $0.id.uuidString == incidentID }),
                      query.matches(incident) else { throw FieldCaseLibraryError.invalidDatabase }
                results.append(FieldIncidentSearchResult(source: source, incident: incident))
            }
            return FieldIncidentSearchPage(results: results, total: totals.first ?? 0)
        }
    }

    /// Removes only the cached source and its dependent rows, never the document.
    public func removeSource(id: String, expectedRevision: UUID) throws {
        try access(writing: true) { db in
            try db.transaction {
                let revisions = try db.rows("SELECT revision FROM sources WHERE id=?", [.text(id)]) { try Self.text($0, 0) }
                guard revisions.first == expectedRevision.uuidString else { throw FieldCaseLibraryError.conflict }
                try db.execute("DELETE FROM sources WHERE id=?", [.text(id)])
            }
        }
    }

    /// Observation reads are scoped to the full composite case identity.
    public func observations(for caseID: FieldIncidentSearchResult.ID) throws -> [FieldIncidentEntry] {
        try access { db in
            try db.rows("""
                SELECT id,occurred_at,payload FROM observations WHERE source_id=? AND case_id=?
                ORDER BY occurred_at,id
                """, [.text(caseID.sourceID), .text(caseID.incidentID.uuidString)]) { row in
                let entry = try JSONDecoder().decode(FieldIncidentEntry.self, from: Self.blob(row, 2))
                guard entry.isValid, entry.id.uuidString == (try Self.text(row, 0)),
                      entry.occurredAt.timeIntervalSince1970 == sqlite3_column_double(row, 1) else {
                    throw FieldCaseLibraryError.invalidDatabase
                }
                return entry
            }.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    private static func deviceKey(_ asset: FieldIncidentAssetReference) -> String {
        guard let external = asset.externalIdentity else { return "local:\(asset.deviceID.uuidString)" }
        return "external:" + [external.instance, external.objectType, external.remoteID]
            .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
    }

    private static func predicate(_ query: FieldIncidentQuery) -> (String, [SQLValue]) {
        var clauses = ["1=1"]
        var values: [SQLValue] = []
        if let ticket = query.ticketReference {
            clauses.append("c.ticket_key=?")
            values.append(.text(FieldIncidentQuery.ticketKey(ticket)))
        }
        if let excluded = query.excludingCaseID {
            clauses.append("NOT (c.source_id=? AND c.id=?)")
            values += [.text(excluded.sourceID), .text(excluded.incidentID.uuidString)]
        }
        if let status = query.status { clauses.append("c.status=?"); values.append(.text(status.rawValue)) }
        if let asset = query.asset {
            clauses.append(asset.externalIdentity == nil ? "c.device_id=?" : "c.device_key=?")
            values.append(.text(asset.externalIdentity == nil ? asset.deviceID.uuidString : deviceKey(asset)))
        }
        for term in query.terms { clauses.append("instr(c.search_text,?)>0"); values.append(.text(term)) }
        if query.occurredFrom != nil || query.occurredThrough != nil {
            let lower = query.occurredFrom?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
            let upper = query.occurredThrough?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude
            clauses.append("""
                (EXISTS(SELECT 1 FROM observations o WHERE o.source_id=c.source_id AND o.case_id=c.id AND o.occurred_at>=? AND o.occurred_at<=?)
                OR (NOT EXISTS(SELECT 1 FROM observations o WHERE o.source_id=c.source_id AND o.case_id=c.id) AND c.created_at>=? AND c.created_at<=?))
                """)
            values += [.real(lower), .real(upper), .real(lower), .real(upper)]
        }
        return (clauses.joined(separator: " AND "), values)
    }

    private func access<T>(writing: Bool = false, _ body: (AssetDatabase) throws -> T) throws -> T {
        try queue.sync {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw FieldCaseLibraryError.lockUnavailable }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw FieldCaseLibraryError.lockUnavailable }
            defer { flock(descriptor, LOCK_UN) }
            do {
                let marker = url.appendingPathExtension("initialized")
                if !manager.fileExists(atPath: url.path) {
                    guard !manager.fileExists(atPath: marker.path) else { throw FieldCaseLibraryError.missingDatabase }
                    try bootstrap()
                }
                // Inspect before opening writable, so unsupported databases are untouched.
                let inspection = try AssetDatabase(url: url, create: false, readOnly: true)
                try validate(inspection)
                try inspection.close()
                let db = try AssetDatabase(url: url, create: false)
                defer { try? db.close() }
                try validate(db)
                try db.execute("PRAGMA journal_mode=WAL")
                try db.execute("PRAGMA synchronous=FULL")
                try migrate(db)
                if !manager.fileExists(atPath: marker.path) { try Data("1".utf8).write(to: marker, options: .atomic) }
                if writing { return try body(db) }
                // Count, page and evidence reads see the same SQLite snapshot.
                try db.execute("BEGIN")
                do {
                    let result = try body(db)
                    try db.execute("COMMIT")
                    return result
                } catch { try? db.execute("ROLLBACK"); throw error }
            } catch let error as AssetRepositoryError {
                if case .sqlite(let code, let message) = error { throw FieldCaseLibraryError.storage(code, message) }
                throw FieldCaseLibraryError.invalidDatabase
            }
        }
    }

    private func validate(_ db: AssetDatabase) throws {
        guard try db.integer("PRAGMA application_id") == applicationID else { throw FieldCaseLibraryError.invalidDatabase }
        let version = try db.integer("PRAGMA user_version")
        guard version == 1 || version == 2 else { throw FieldCaseLibraryError.unsupportedSchema(version) }
    }

    private func migrate(_ db: AssetDatabase) throws {
        guard try db.integer("PRAGMA user_version") == 1 else { return }
        try db.transaction {
            try db.execute("ALTER TABLE cases ADD COLUMN ticket_key TEXT NOT NULL DEFAULT ''")
            let sources = try db.rows("SELECT id,project FROM sources") {
                (try Self.text($0, 0), try FieldProject.decode(Self.blob($0, 1)))
            }
            for (sourceID, project) in sources {
                for incident in project.incidents {
                    try db.execute("UPDATE cases SET ticket_key=? WHERE source_id=? AND id=?", [
                        .text(FieldIncidentQuery.ticketKey(incident.ticketReference)),
                        .text(sourceID), .text(incident.id.uuidString)
                    ])
                }
            }
            try db.execute("CREATE INDEX case_ticket_date ON cases(ticket_key,latest_at DESC,source_id,id)")
            try db.execute("PRAGMA user_version=2")
        }
    }

    private func bootstrap() throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".field-cases-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        let db = try AssetDatabase(url: staging, create: true)
        defer { try? db.close() }
        try db.execute("PRAGMA synchronous=FULL")
        try db.transaction {
            try db.execute("PRAGMA application_id=\(applicationID)")
            try db.execute("PRAGMA user_version=2")
            try db.execute("CREATE TABLE sources(id TEXT PRIMARY KEY,label TEXT NOT NULL,loaded_at REAL NOT NULL,revision TEXT NOT NULL,project BLOB NOT NULL)")
            try db.execute("CREATE TABLE cases(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,id TEXT NOT NULL,status TEXT NOT NULL,device_key TEXT,device_id TEXT,created_at REAL NOT NULL,latest_at REAL NOT NULL,search_text TEXT NOT NULL,ticket_key TEXT NOT NULL,PRIMARY KEY(source_id,id))")
            try db.execute("CREATE TABLE observations(source_id TEXT NOT NULL,case_id TEXT NOT NULL,id TEXT NOT NULL,occurred_at REAL NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source_id,case_id,id),FOREIGN KEY(source_id,case_id) REFERENCES cases(source_id,id) ON DELETE CASCADE)")
            try db.execute("CREATE INDEX case_date ON cases(latest_at DESC,source_id,id)")
            try db.execute("CREATE INDEX case_status_date ON cases(status,latest_at DESC,source_id,id)")
            try db.execute("CREATE INDEX case_device_date ON cases(device_key,latest_at DESC,source_id,id)")
            try db.execute("CREATE INDEX case_local_device_date ON cases(device_id,latest_at DESC,source_id,id)")
            try db.execute("CREATE INDEX case_ticket_date ON cases(ticket_key,latest_at DESC,source_id,id)")
            try db.execute("CREATE INDEX observation_date ON observations(source_id,case_id,occurred_at)")
        }
        try db.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: url)
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(row, column) else { throw FieldCaseLibraryError.invalidDatabase }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { throw FieldCaseLibraryError.invalidDatabase }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}

public enum FieldCaseLibraryError: LocalizedError {
    case conflict, sourceLimit, invalidDatabase, missingDatabase, lockUnavailable
    case unsupportedSchema(Int), storage(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .conflict: return t("This source changed in another window. Reload the library, then choose the file again.")
        case .sourceLimit: return t("The local case library can contain up to 200 project sources.")
        case .invalidDatabase: return t("The local case library is damaged or belongs to another application.")
        case .missingDatabase: return t("The initialized case library is missing. Restore its backup before importing.")
        case .lockUnavailable: return t("The local case library could not be locked. Try again.")
        case .unsupportedSchema(let version): return tf("Unsupported case library schema: %d.", version)
        case .storage(let code, let message): return tf("Case library storage error %d: %@", code, message)
        }
    }
}
