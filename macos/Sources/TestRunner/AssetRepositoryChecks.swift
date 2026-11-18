import Foundation
import Darwin
@testable import NMCore

/// File-backed checks for the storage boundary. Fixtures never use the user's
/// Application Support directory or Keychain.
enum AssetRepositoryChecks {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NMAssetRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        print("Storage: migrationChecks")
        try migrationChecks(in: directory)
        print("Storage: transactionAndPageChecks")
        try transactionAndPageChecks(in: directory)
        print("Storage: walBackupChecks")
        try walBackupChecks(in: directory)
        print("Storage: recoveryChecks")
        try recoveryChecks(in: directory)
        print("Storage: storeChecks")
        try storeChecks(in: directory)
    }

    private static func fixture() -> AssetSnapshot {
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        let first = OperationsWorkspace(id: id(2), name: "Primary 中文", notes: "First by insertion", createdAt: date, updatedAt: date)
        let second = OperationsWorkspace(id: id(1), name: "Secondary", createdAt: date, updatedAt: date)
        let site = AssetSite(id: id(10), workspaceID: first.id, name: "Lab", location: "Local", notes: "Site notes")
        let otherSite = AssetSite(id: id(11), workspaceID: second.id, name: "Remote")
        let subnet = AssetSubnet(id: id(20), siteID: site.id, name: "LAN", cidr: "192.0.2.0/24", purpose: "Storage fixture", notes: "Subnet notes")
        let device = AssetDevice(id: id(30), siteID: site.id, subnetID: subnet.id, name: "Gateway", address: "192.0.2.1", kind: .router,
                                 vendor: "Example", role: "Edge", notes: "User-authored", credentialRefID: id(99),
                                 source: "https://netbox.example", sourceFetchedAt: date,
                                 createdAt: date, updatedAt: date)
        let otherDevice = AssetDevice(id: id(31), siteID: otherSite.id, name: "Other", address: "2001:db8::1", kind: .server,
                                      createdAt: date, updatedAt: date)
        let evidence = DiagnosticRuntimeEvidence(tcpFailure: TCPProbeFailure(code: .refused, stage: .socketError,
                                                                            message: "Connection refused", soError: ECONNREFUSED))
        let runs = [
            DiagnosticRun(id: id(104), deviceID: device.id, kind: .tcp, status: .failed,
                          startedAt: date, finishedAt: date.addingTimeInterval(1), parameters: ["port": "443"],
                          summary: "Refused", detail: "Fixture detail 中文", latency: 0.012, source: "TCP", target: device.address, evidence: evidence),
            DiagnosticRun(id: id(102), deviceID: otherDevice.id, kind: .dns, status: .succeeded,
                          startedAt: date, finishedAt: date.addingTimeInterval(2), summary: "Other workspace", target: "example.test"),
            DiagnosticRun(id: id(105), kind: .whois, status: .succeeded,
                          startedAt: date.addingTimeInterval(5), summary: "Standalone", target: "example.test"),
            DiagnosticRun(id: id(103), deviceID: device.id, kind: .ping, status: .succeeded,
                          startedAt: date, finishedAt: date.addingTimeInterval(1), summary: "Reachable", latency: 0.001),
            DiagnosticRun(id: id(101), deviceID: device.id, kind: .traceroute, status: .cancelled,
                          startedAt: date.addingTimeInterval(-5), summary: "Cancelled", detail: "Partial evidence")
        ]
        return AssetSnapshot(workspaces: [first, second], sites: [otherSite, site], subnets: [subnet],
                             devices: [otherDevice, device], diagnosticRuns: runs)
    }

    private static func migrationChecks(in directory: URL) throws {
        let original = fixture()
        for iso8601 in [true, false] {
            let suffix = iso8601 ? "iso" : "numeric"
            let jsonURL = directory.appendingPathComponent("legacy-\(suffix).json")
            let sqliteURL = directory.appendingPathComponent("migrated-\(suffix).sqlite")
            var expected = original
            if !iso8601 {
                // Numeric legacy encoding must retain subsecond timestamps.
                expected.devices[0].updatedAt = expected.devices[0].updatedAt.addingTimeInterval(0.125)
                expected.diagnosticRuns[0].startedAt = expected.diagnosticRuns[0].startedAt.addingTimeInterval(0.25)
            }
            let encoder = JSONEncoder()
            if iso8601 { encoder.dateEncodingStrategy = .iso8601 }
            let source = try encoder.encode(expected)
            try source.write(to: jsonURL)
            let staged = sqliteURL.appendingPathExtension("migration-interrupted-fixture")
            try Data("incomplete migration".utf8).write(to: staged)
            let repository = SQLiteAssetRepository(url: sqliteURL, legacyURL: jsonURL)
            let migrated = try repository.load()
            let retained = try Data(contentsOf: jsonURL)
            try check(migrated == expected, "\(suffix) migration preserves every record, field, relationship and array order")
            try check(retained == source, "\(suffix) migration preserves the exact legacy JSON bytes")
            let loadedAgain = try SQLiteAssetRepository(url: sqliteURL, legacyURL: jsonURL).load()
            try check(loadedAgain == expected, "\(suffix) migration publishes an independently readable database")
            try Data("old JSON later damaged".utf8).write(to: jsonURL)
            let authoritative = try repository.load()
            try check(authoritative == expected, "An existing SQLite database remains authoritative over stale or damaged JSON")
        }

        let badJSON = directory.appendingPathComponent("bad-legacy.json")
        let badSQLite = directory.appendingPathComponent("bad-migration.sqlite")
        let badBytes = Data("{ damaged source".utf8)
        try badBytes.write(to: badJSON)
        _ = try expectFailure("A damaged migration source must be rejected") {
            _ = try SQLiteAssetRepository(url: badSQLite, legacyURL: badJSON).load()
        }
        let stillBad = try Data(contentsOf: badJSON)
        try check(stillBad == badBytes && !FileManager.default.fileExists(atPath: badSQLite.path),
                  "Failed migration keeps original bytes and does not publish a replacement database")
    }

    private static func transactionAndPageChecks(in directory: URL) throws {
        let url = directory.appendingPathComponent("transactions.sqlite")
        let repository = SQLiteAssetRepository(url: url)
        var snapshot = fixture()
        _ = try repository.load()
        try repository.save(snapshot)
        let initialReload = try SQLiteAssetRepository(url: url).load()
        try check(initialReload == snapshot, "A successful SQLite save is immediately durable and preserves insertion order")

        snapshot.workspaces[0].name = "Renamed parent"
        try repository.save(snapshot)
        let parentReload = try SQLiteAssetRepository(url: url).load()
        try check(parentReload == snapshot, "Updating a parent retains all sites, subnets, devices and diagnostic evidence")

        let sorted = snapshot.diagnosticRuns.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        let first = try repository.diagnosticPage(DiagnosticPageQuery(limit: 2))
        let second = try repository.diagnosticPage(DiagnosticPageQuery(limit: 2, offset: 2))
        let last = try repository.diagnosticPage(DiagnosticPageQuery(limit: 2, offset: 4))
        try check((first + second + last).map(\.id) == sorted.map(\.id),
                  "History pages use a stable date/ID order with no duplicates or missing rows at ties")
        let device = snapshot.devices.first { $0.id == id(30) }!
        let devicePage = try repository.diagnosticPage(DiagnosticPageQuery(scope: .device(device.id)))
        let workspacePage = try repository.diagnosticPage(DiagnosticPageQuery(scope: .workspace(id(2))))
        let expectedDevice = sorted.filter { $0.deviceID == device.id }
        try check(devicePage == expectedDevice && workspacePage == expectedDevice,
                  "Device/workspace pages isolate evidence and exclude standalone runs from workspace association")
        let empty = try repository.diagnosticPage(DiagnosticPageQuery(offset: 500))
        try check(empty.isEmpty, "A page beyond the end returns no history")
        for query in [DiagnosticPageQuery(limit: 0), DiagnosticPageQuery(limit: 501), DiagnosticPageQuery(offset: -1)] {
            _ = try expectFailure("Invalid page bounds must be rejected") { _ = try repository.diagnosticPage(query) }
        }

        var duplicate = snapshot
        duplicate.devices.append(duplicate.devices[0])
        var orphan = snapshot
        orphan.sites[0].workspaceID = UUID()
        var wrongSubnetSite = snapshot
        wrongSubnetSite.devices[0].subnetID = snapshot.subnets[0].id
        for invalid in [duplicate, orphan, wrongSubnetSite] {
            _ = try expectFailure("Invalid IDs/relationships must be rejected before commit") { try repository.save(invalid) }
            let afterInvalid = try SQLiteAssetRepository(url: url).load()
            try check(afterInvalid == snapshot, "Rejected relationship changes leave the last durable snapshot untouched")
        }

        // Fail after the workspace update, while writing a device. A later-table
        // failure must roll back earlier table writes and keep the revision valid.
        try sqlite(url, "CREATE TRIGGER fail_device BEFORE UPDATE ON devices BEGIN SELECT RAISE(ABORT,'injected write failure'); END;")
        var failed = snapshot
        failed.workspaces[0].notes = "Must roll back"
        failed.devices[0].notes = "Trigger failure"
        _ = try expectFailure("Injected SQLite write failure must abort the transaction") { try repository.save(failed) }
        let afterFailure = try SQLiteAssetRepository(url: url).load()
        try check(afterFailure == snapshot, "A mid-transaction write error rolls back every table and revision")
        try sqlite(url, "DROP TRIGGER fail_device;")
        try repository.save(failed)
        snapshot = failed
        let retried = try SQLiteAssetRepository(url: url).load()
        try check(retried == snapshot, "A failed transaction can be retried without poisoning the repository baseline")

        try sqlite(url, "CREATE TRIGGER unchanged_workspace BEFORE UPDATE ON workspaces BEGIN SELECT RAISE(ABORT,'unchanged workspace rewritten'); END;")
        snapshot.diagnosticRuns[0].summary = "Only this diagnostic changed"
        try repository.save(snapshot)
        try sqlite(url, "DROP TRIGGER unchanged_workspace;")
        let incremental = try SQLiteAssetRepository(url: url).load()
        try check(incremental == snapshot, "Changing a diagnostic does not rewrite unrelated parent records")

        let stale = SQLiteAssetRepository(url: url)
        let staleSnapshot = try stale.load()!
        snapshot.workspaces[0].notes = "Newer commit"
        try repository.save(snapshot)
        let conflict = try expectFailure("A stale instance must not overwrite another writer") { try stale.save(staleSnapshot) }
        guard case AssetRepositoryError.conflict = conflict else {
            throw CheckFailure(description: "A stale write should report the explicit conflict error, got \(conflict)")
        }
        let afterConflict = try SQLiteAssetRepository(url: url).load()
        try check(afterConflict == snapshot, "Conflict rejection preserves the newer durable commit")
        _ = try stale.load()
        try stale.save(snapshot)

        let backupURL = directory.appendingPathComponent("online-backup.sqlite")
        print("Storage: creating backup \(backupURL.lastPathComponent)")
        try repository.createBackup(at: backupURL)
        print("Storage: loading backup \(backupURL.lastPathComponent)")
        let backup = try SQLiteAssetRepository(url: backupURL).load()
        try check(backup == snapshot, "The SQLite backup API creates an independent complete database")
        let backupBytes = try Data(contentsOf: backupURL)
        _ = try expectFailure("Backup must not overwrite an existing destination") { try repository.createBackup(at: backupURL) }
        let preservedBackup = try Data(contentsOf: backupURL)
        try check(preservedBackup == backupBytes, "A backup destination collision preserves the existing backup bytes")
    }

    private static func recoveryChecks(in directory: URL) throws {
        let url = directory.appendingPathComponent("corrupt.sqlite")
        let legacyURL = directory.appendingPathComponent("valid-but-stale.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixture()).write(to: legacyURL)
        let damagedBytes = Data("This is not a SQLite database.".utf8)
        try damagedBytes.write(to: url)
        let damaged = SQLiteAssetRepository(url: url, legacyURL: legacyURL)
        _ = try expectFailure("A damaged database cannot silently fall back to old JSON") { _ = try damaged.load() }
        let afterLoad = try Data(contentsOf: url)
        try check(afterLoad == damagedBytes, "Opening a damaged database preserves the original bytes")
        let preserved = try damaged.restore(fixture(), preservingDamaged: true)
        guard let preserved else { throw CheckFailure(description: "Database recovery must return the original-file copy") }
        let original = try Data(contentsOf: preserved)
        let restored = try damaged.load()
        try check(original == damagedBytes && restored == fixture(),
                  "Recovery retains the damaged original and activates the verified replacement")

        let futureURL = directory.appendingPathComponent("future.sqlite")
        let future = SQLiteAssetRepository(url: futureURL, legacyURL: legacyURL)
        _ = try future.load()
        try future.save(fixture())
        try sqlite(futureURL, "PRAGMA user_version=99;")
        let futureBytes = try Data(contentsOf: futureURL)
        let unsupported = try expectFailure("A future schema version must enter recovery") { _ = try future.load() }
        guard case AssetRepositoryError.unsupportedSchema(99) = unsupported else {
            throw CheckFailure(description: "Future schema rejection should name version 99, got \(unsupported)")
        }
        let futureAfter = try Data(contentsOf: futureURL)
        try check(futureAfter == futureBytes, "Future-schema rejection does not alter the database or remigrate stale JSON")

        for (name, change) in [
            ("device", "UPDATE diagnostic_runs SET device_id=NULL WHERE device_id IS NOT NULL;"),
            ("date", "UPDATE diagnostic_runs SET started_at=started_at+1;"),
            ("site", "UPDATE devices SET site_id='\(id(11).uuidString)' WHERE id='\(id(30).uuidString)';")
        ] {
            let alteredURL = directory.appendingPathComponent("altered-\(name).sqlite")
            let altered = SQLiteAssetRepository(url: alteredURL)
            try altered.save(fixture())
            try sqlite(alteredURL, change)
            _ = try expectFailure("Relational query columns must match the complete record payload") { _ = try altered.load() }
        }

        let missingURL = directory.appendingPathComponent("removed-initialized.sqlite")
        let missing = SQLiteAssetRepository(url: missingURL, legacyURL: legacyURL)
        _ = try missing.load()
        try FileManager.default.removeItem(at: missingURL)
        _ = try expectFailure("A deleted initialized database cannot be silently recreated from old JSON") { _ = try missing.load() }
        try check(!FileManager.default.fileExists(atPath: missingURL.path),
                  "Missing initialized database remains recoverable without publishing stale data")

        let pendingURL = directory.appendingPathComponent("pending-restore.sqlite")
        let pending = SQLiteAssetRepository(url: pendingURL)
        _ = try pending.load()
        try pending.save(fixture())
        try Data("interrupted restore fixture".utf8).write(to: pendingURL.appendingPathExtension("restore-pending"))
        _ = try expectFailure("Interrupted database replacement must block normal startup") { _ = try pending.load() }
        _ = try pending.restore(fixture(), preservingDamaged: true)
        let afterPending = try pending.load()
        try check(afterPending == fixture(), "Explicit backup recovery can complete after an interrupted replacement")
    }

    private static func walBackupChecks(in directory: URL) throws {
        let url = directory.appendingPathComponent("wal-source.sqlite")
        let repository = SQLiteAssetRepository(url: url)
        var snapshot = fixture()
        _ = try repository.load()
        try repository.save(snapshot)

        // A separate SQLite reader keeps its old read transaction open. New
        // committed pages must stay in WAL rather than checkpointing into main.
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        reader.arguments = ["-batch", url.path]
        let input = Pipe()
        let output = Pipe()
        reader.standardInput = input
        reader.standardOutput = output
        reader.standardError = output
        try reader.run()
        defer {
            try? input.fileHandleForWriting.close()
            if reader.isRunning { reader.terminate() }
            reader.waitUntilExit()
        }
        try input.fileHandleForWriting.write(contentsOf: Data("PRAGMA journal_mode=WAL; BEGIN; SELECT count(*) FROM workspaces; SELECT 'NM_READY';\n".utf8))
        var ready = Data()
        let deadline = Date().addingTimeInterval(5)
        while !String(decoding: ready, as: UTF8.self).contains("NM_READY") {
            guard Date() < deadline else { throw CheckFailure(description: "WAL fixture reader did not become ready") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 100)
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                throw CheckFailure(description: "WAL fixture reader exited before its transaction was ready")
            }
            ready.append(byte)
        }

        snapshot.diagnosticRuns[0].summary = "Committed only in the live WAL"
        try repository.save(snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        try check(((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0,
                  "The online-backup fixture has real uncheckpointed WAL pages")
        let backupURL = directory.appendingPathComponent("wal-backup.sqlite")
        print("Storage: creating backup \(backupURL.lastPathComponent)")
        try repository.createBackup(at: backupURL)
        print("Storage: loading backup \(backupURL.lastPathComponent)")
        let backup = try SQLiteAssetRepository(url: backupURL).load()
        try check(backup == snapshot, "Online SQLite backup includes the latest committed WAL pages while an older reader remains open")
    }

    private static func storeChecks(in directory: URL) throws {
        let url = directory.appendingPathComponent("store.sqlite")
        let store = AssetStore(storageURL: url)
        guard let workspace = store.primaryWorkspace else {
            throw CheckFailure(description: "A new SQLite-backed store must seed its local workspace")
        }
        let site = AssetSite(workspaceID: workspace.id, name: "Store regression")
        let subnet = AssetSubnet(siteID: site.id, name: "Store subnet", cidr: "192.0.2.0/24")
        let device = AssetDevice(siteID: site.id, subnetID: subnet.id, name: "Store target", address: "192.0.2.1", credentialRefID: id(98))
        store.upsert(site)
        store.upsert(subnet)
        store.upsert(device)
        let evidence = DiagnosticRuntimeEvidence(tcpFailure: TCPProbeFailure(code: .refused, stage: .socketError, message: "Refused"))
        let finishedID = store.beginDiagnostic(deviceID: device.id, kind: .tcp, target: device.address)
        store.finishDiagnostic(id: finishedID, status: .failed, summary: "Refused", evidence: evidence)
        let unfinishedID = store.beginDiagnostic(deviceID: device.id, kind: .ping, target: device.address)
        try check(store.recoveryError == nil && store.persistenceError == nil, "SQLite-backed AssetStore completes normal mutations")
        let reloaded = AssetStore(storageURL: url)
        let recovered = reloaded.diagnosticRuns.first { $0.id == unfinishedID }
        try check(recovered?.status == .interrupted && recovered?.finishedAt != nil,
                  "SQLite store reload durably marks unfinished diagnostics interrupted")
        try check(reloaded.diagnosticRuns.first { $0.id == finishedID }?.evidence == evidence,
                  "SQLite store reload retains structured diagnostic evidence")
        let again = AssetStore(storageURL: url)
        try check(again.diagnosticRuns.first { $0.id == unfinishedID }?.status == .interrupted,
                  "Interrupted-run recovery survives a second reload")

        let exported = try reloaded.exportBackup()
        let importedURL = directory.appendingPathComponent("imported-store.sqlite")
        let imported = AssetStore(storageURL: importedURL)
        try imported.importBackup(exported)
        try check(imported.devices.contains { $0.id == device.id && $0.credentialRefID == id(98) } &&
                  imported.diagnosticRuns.first { $0.id == finishedID }?.evidence == evidence,
                  "Existing JSON backup format round-trips through a SQLite-backed store")
        imported.removeSubnet(id: subnet.id)
        let detached = AssetStore(storageURL: importedURL)
        try check(detached.devices.first { $0.id == device.id }?.subnetID == nil &&
                  detached.diagnosticRuns.contains { $0.id == finishedID },
                  "SQLite subnet deletion detaches the device and retains its evidence")
        imported.removeSite(id: site.id)
        let removed = AssetStore(storageURL: importedURL)
        try check(!removed.devices.contains { $0.id == device.id } &&
                  !removed.diagnosticRuns.contains { $0.id == finishedID },
                  "SQLite site deletion preserves the existing cascade contract")

        let damagedURL = directory.appendingPathComponent("damaged-store.sqlite")
        let damagedBytes = Data("damaged SQLite fixture".utf8)
        try damagedBytes.write(to: damagedURL)
        let damaged = AssetStore(storageURL: damagedURL)
        try check(damaged.recoveryError != nil && damaged.workspaces.isEmpty,
                  "A damaged SQLite-backed store enters recovery without seeding data")
        damaged.save()
        _ = try expectFailure("Invalid backup must be rejected in recovery") { try damaged.importBackup(Data("{}".utf8)) }
        let stillDamaged = try Data(contentsOf: damagedURL)
        try check(stillDamaged == damagedBytes && damaged.recoveryError != nil,
                  "Ordinary save and invalid import preserve the damaged database")
        try damaged.importBackup(exported)
        guard let preserved = damaged.preservedCorruptFileURL else {
            throw CheckFailure(description: "Store recovery must expose the preserved original URL")
        }
        let original = try Data(contentsOf: preserved)
        let restoredStore = AssetStore(storageURL: damagedURL)
        try check(original == damagedBytes && damaged.recoveryError == nil && restoredStore.devices.contains { $0.id == device.id },
                  "Store backup recovery preserves damaged bytes and commits a reloadable workspace")
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    @discardableResult
    private static func expectFailure(_ message: String, _ body: () throws -> Void) throws -> Error {
        do { try body() } catch { return error }
        throw CheckFailure(description: message)
    }

    private static func sqlite(_ url: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try check(process.terminationStatus == 0,
                  "SQLite fixture command failed: \(String(decoding: data, as: UTF8.self))")
    }
}
