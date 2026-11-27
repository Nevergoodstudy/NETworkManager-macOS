import Foundation
import Darwin
@testable import NMCore

/// File-backed checks for the storage boundary. Fixtures never use the user's
/// Application Support directory or Keychain.
enum AssetRepositoryChecks {
    static func run(includeWorkspaceOwnership: Bool = true) throws {
        try AssetWorkspaceOwnershipChecks.runChildIfRequested()
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
        guard includeWorkspaceOwnership else {
            print("Storage: skipped multi-instance workspace ownership checks")
            return
        }
        print("Storage: workspaceOwnershipChecks")
        try AssetWorkspaceOwnershipChecks.run(in: directory)
    }

    @MainActor
    static func historyPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assets.sqlite")
        let repository = SQLiteAssetRepository(url: url)
        var snapshot = fixture()
        let device = snapshot.devices[1]
        let now = Date()
        snapshot.diagnosticRuns = (1...52).reversed().map { index in
            DiagnosticRun(id: id(index + 100), deviceID: index == 52 ? nil : device.id, kind: .ping,
                          status: .succeeded, startedAt: now, parameters: index == 51 ? ["eventID": "9001"] : [:],
                          summary: "Fixture \(index)", source: "Zabbix", target: device.address)
        }
        snapshot.diagnosticRuns.append(DiagnosticRun(id: id(153), deviceID: device.id, kind: .tcp,
                                                    status: .succeeded, startedAt: now.addingTimeInterval(-8 * 86_400)))
        try repository.save(snapshot)
        let store = AssetStore(repository: repository)
        let unfiltered = DiagnosticHistorySearch.Filter(workspaceID: nil, kind: nil, days: nil, text: "")
        let first = try await store.diagnosticHistoryPage(unfiltered, offset: 0)
        let last = try await store.diagnosticHistoryPage(unfiltered, offset: 50)
        let beyond = try await store.diagnosticHistoryPage(unfiltered, offset: 100)
        try check(first.count == 51 && last.map(\.id) == [id(151), id(152), id(153)] && beyond.isEmpty &&
                  (first.prefix(50).map(\.id) + last.map(\.id)) == (101...153).map(id),
                  "History uses a lookahead without duplicating tied rows across page boundaries; standalone evidence stays visible")

        let workspaceID = snapshot.workspaces[0].id
        let filtered = DiagnosticHistorySearch.Filter(workspaceID: workspaceID, kind: .ping, days: 1, text: "gAtEwAy")
        let filteredFirst = try await store.diagnosticHistoryPage(filtered, offset: 0)
        let filteredLast = try await store.diagnosticHistoryPage(filtered, offset: 50)
        try check(filteredFirst.count == 51 && filteredLast.map(\.id) == [id(151)],
                  "Workspace, check, age and case-insensitive text are applied before paging")
        let event = DiagnosticHistorySearch.Filter(workspaceID: nil, kind: nil, days: nil, text: "9001")
        let evidence = try await store.diagnosticHistoryPage(event, offset: 0)
        try check(evidence.map(\.id) == [id(151)], "An event ID finds evidence whose position is beyond the first page")

        let json = try await store.exportDiagnosticHistory(filtered, markdown: false)
        let markdown = try await store.exportDiagnosticHistory(filtered, markdown: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([DiagnosticEvidenceItem].self, from: json)
        try check(Set(items.map(\.id)) == Set((101...151).map(id)) &&
                  String(decoding: markdown, as: UTF8.self).contains("Fixture 51"),
                  "Both export formats include matching rows beyond the first 50")

        let revision = store.diagnosticHistoryRevision
        let runID = store.beginDiagnostic(kind: .ping, target: "192.0.2.5")
        store.finishDiagnostic(id: runID, status: .succeeded, summary: "New history row")
        let refreshed = try await store.diagnosticHistoryPage(unfiltered, offset: 0)
        try check(store.diagnosticHistoryRevision > revision && refreshed.first?.id == runID &&
                  refreshed.first?.summary == "New history row", "Committed diagnostics invalidate and refresh the indexed history")

        try sqlite(url, "CREATE TRIGGER fail_history BEFORE INSERT ON diagnostic_runs BEGIN SELECT RAISE(ABORT,'injected write failure'); END;")
        let beforeFailure = store.diagnosticHistoryRevision
        let unsavedID = store.beginDiagnostic(deviceID: device.id, kind: .ping, target: device.address)
        store.finishDiagnostic(id: unsavedID, status: .succeeded, summary: "Unsaved diagnostic")
        let durable = try repository.diagnosticPage(DiagnosticPageQuery(limit: 1))
        try check(store.persistenceError != nil && durable.first?.id == runID,
                  "A failed diagnostic insert leaves the previous SQLite history intact")

        let live = try await store.diagnosticHistoryPage(unfiltered, offset: 0)
        let workspaceOnly = DiagnosticHistorySearch.Filter(workspaceID: workspaceID, kind: nil, days: nil, text: "")
        let scoped = try await store.diagnosticHistoryPage(workspaceOnly, offset: 0)
        let exported = try await store.exportDiagnosticHistory(workspaceOnly, markdown: false)
        let exportedItems = try decoder.decode([DiagnosticEvidenceItem].self, from: exported)
        try check(store.diagnosticHistoryRevision > beforeFailure && live.first?.id == unsavedID &&
                  scoped.first?.summary == "Unsaved diagnostic" && exportedItems.contains { $0.id == unsavedID },
                  "Write failure refreshes history from the same live snapshot used for export")

        try sqlite(url, "DROP TRIGGER fail_history;")
        store.save()
        let persisted = try repository.diagnosticPage(DiagnosticPageQuery(limit: 1))
        let indexed = try await store.diagnosticHistoryPage(unfiltered, offset: 0)
        try check(store.persistenceError == nil && persisted.first?.id == unsavedID && indexed.first?.id == unsavedID,
                  "A successful retry clears the save error and returns to indexed history")
    }

    @MainActor
    static func backgroundRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = AssetStore(storageURL: directory.appendingPathComponent("source.sqlite"))
        let backup = try await source.exportBackupInBackground()
        let backupURL = directory.appendingPathComponent("backup.json")
        try backup.write(to: backupURL)

        let url = directory.appendingPathComponent("target.sqlite")
        let repository = SQLiteAssetRepository(url: url)
        let original = fixture()
        try repository.save(original)
        let store = AssetStore(repository: repository)
        let runID = store.beginDiagnostic(kind: .ping, target: "192.0.2.1")
        try sqlite(url, "CREATE TRIGGER fail_restore BEFORE INSERT ON workspaces BEGIN SELECT RAISE(ABORT,'injected restore failure'); END;")

        let descriptor = open(url.path + ".lock", O_RDWR | O_CLOEXEC)
        try check(descriptor >= 0, "Open the repository lock for the restore fixture")
        defer { close(descriptor) }
        try check(flock(descriptor, LOCK_EX) == 0, "Hold restoration at the repository lock")
        let restore = Task { try await store.importBackupInBackground(from: backupURL) }
        let timeout = ContinuousClock.now + .seconds(5)
        while !store.isRestoringBackup && ContinuousClock.now < timeout { await Task.yield() }
        try check(store.isRestoringBackup, "Restoration enters the busy state before waiting on SQLite")

        let editingBlocked = !store.canEditWorkspace
        store.removeWorkspace(id: original.workspaces[0].id)
        store.load()
        let overlappingRestore = try expectFailure("A synchronous import cannot overlap background restore") {
            try store.importBackup(backup)
        }
        store.finishDiagnostic(id: runID, status: .succeeded, summary: "Finished while restore was pending")
        let filter = DiagnosticHistorySearch.Filter(workspaceID: nil, kind: nil, days: nil, text: "")
        let pendingPage = try await store.diagnosticHistoryPage(filter, offset: 0)
        try check(flock(descriptor, LOCK_UN) == 0, "Release the repository lock")
        let result = await restore.result

        guard case .restoreInProgress = overlappingRestore as? AssetBackupError else {
            throw CheckFailure(description: "An overlapping import should be rejected as busy")
        }
        try check(editingBlocked && pendingPage.first(where: { $0.id == runID })?.status == .running,
                  "The main actor remains responsive while the restore excludes writes and reads history from the snapshot")
        guard case .failure(let error) = result, case .sqlite(_, let message) = error as? AssetRepositoryError,
              message.contains("injected restore failure") else {
            throw CheckFailure(description: "The restore should fail inside a real SQLite transaction")
        }
        let reopened = AssetStore(storageURL: url)
        try check(!store.isRestoringBackup && store.canEditWorkspace && store.workspaces == original.workspaces &&
                  reopened.workspaces == original.workspaces && reopened.devices == original.devices &&
                  reopened.diagnosticRuns.first(where: { $0.id == runID })?.status == .succeeded,
                  "A failed restore preserves the original workspace and persists a deferred diagnostic completion")

        try sqlite(url, "DROP TRIGGER fail_restore;")
        try await store.importBackupInBackground(from: backupURL)
        let restored = AssetStore(storageURL: url)
        try check(!store.isRestoringBackup && store.canEditWorkspace && store.workspaces.map(\.id) == source.workspaces.map(\.id) &&
                  restored.workspaces == store.workspaces && restored.diagnosticRuns.isEmpty,
                  "A successful retry publishes the backup and a fresh store reads it from SQLite")

        let damagedURL = directory.appendingPathComponent("damaged.sqlite")
        let damagedBytes = Data("original damaged database".utf8)
        try damagedBytes.write(to: damagedURL)
        let damaged = AssetStore(storageURL: damagedURL)
        let invalidBackupURL = directory.appendingPathComponent("invalid-backup.json")
        try Data("{}".utf8).write(to: invalidBackupURL)
        do {
            try await damaged.importBackupInBackground(from: invalidBackupURL)
            throw CheckFailure(description: "A damaged workspace must reject an invalid backup")
        } catch is DecodingError {}
        let unchangedBytes = try Data(contentsOf: damagedURL)
        try check(damaged.recoveryError != nil && !damaged.isRestoringBackup && unchangedBytes == damagedBytes,
                  "Invalid input keeps the original damaged database and leaves recovery available")
        try await damaged.importBackupInBackground(from: backupURL)
        guard let preserved = damaged.preservedCorruptFileURL else {
            throw CheckFailure(description: "The repaired workspace must expose its preserved original")
        }
        let preservedBytes = try Data(contentsOf: preserved)
        let repaired = AssetStore(storageURL: damagedURL)
        try check(damaged.canEditWorkspace && preservedBytes == damagedBytes && repaired.workspaces == restored.workspaces,
                  "Background recovery preserves the damaged bytes and publishes a database that reopens")
    }

    @MainActor
    static func backgroundMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("assets.json")
        let url = directory.appendingPathComponent("assets.sqlite")
        var snapshot = fixture()
        let run = DiagnosticRun(kind: .ping, status: .running, target: "192.0.2.1")
        snapshot.diagnosticRuns.append(run)
        let original = try JSONEncoder().encode(snapshot)
        try original.write(to: legacyURL)

        let owner = open(url.appendingPathExtension("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try check(owner >= 0, "Open the workspace ownership lock")
        defer { close(owner) }
        try check(flock(owner, LOCK_EX) == 0, "Hold workspace ownership before its first background open")
        let repository = SQLiteAssetRepository(url: url, legacyURL: legacyURL, requiresExclusiveOwnership: true)
        let store = AssetStore(openingInBackground: repository)
        try check(store.isLoadingWorkspace && !store.canEditWorkspace, "First open starts in a non-editable loading state")
        var deadline = ContinuousClock.now + .seconds(5)
        while store.isLoadingWorkspace && ContinuousClock.now < deadline { await Task.yield() }
        try check(store.workspaceAccessError != nil && store.recoveryError == nil && !FileManager.default.fileExists(atPath: url.path),
                  "A blocked background open does not migrate or offer to replace the workspace")

        let operation = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try check(operation >= 0, "Open the repository operation lock")
        defer { close(operation) }
        try check(flock(operation, LOCK_EX) == 0 && flock(owner, LOCK_UN) == 0, "Delay migration after workspace ownership is available")
        let retry = Task { await store.retryWorkspaceAccessInBackground() }
        deadline = ContinuousClock.now + .seconds(5)
        while !store.isLoadingWorkspace && ContinuousClock.now < deadline { await Task.yield() }
        try check(store.isLoadingWorkspace && !store.canEditWorkspace, "The main actor remains responsive while retry waits on SQLite")
        store.upsert(OperationsWorkspace(name: "Must not be saved during startup"))
        let busy = try expectFailure("History cannot query SQLite while the workspace is opening") { _ = try store.diagnosticPage() }
        try check(busy.localizedDescription == t("Loading…") && store.workspaces.isEmpty,
                  "History and workspace edits observe the loading state")
        try check(flock(operation, LOCK_UN) == 0, "Allow migration to finish")
        await retry.value

        let reopened = try SQLiteAssetRepository(url: url).load()
        let preserved = try Data(contentsOf: legacyURL)
        try check(store.canEditWorkspace && store.persistenceError == nil && store.workspaces == snapshot.workspaces &&
                  reopened?.devices == snapshot.devices && preserved == original &&
                  reopened?.diagnosticRuns.first(where: { $0.id == run.id })?.status == .interrupted,
                  "Retry migrates the original bytes, publishes the workspace and persists interruption recovery")
    }

    @MainActor
    static func backgroundSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assets.sqlite")
        let repository = SQLiteAssetRepository(url: url)
        try repository.save(fixture())
        let store = AssetStore(openingInBackground: repository)
        await store.waitForWorkspaceWrites()
        let backupURL = directory.appendingPathComponent("backup.json")
        try await store.exportBackupInBackground().write(to: backupURL)

        let descriptor = open(url.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
        try check(descriptor >= 0, "Open the repository operation lock")
        defer { close(descriptor) }
        try check(flock(descriptor, LOCK_EX) == 0, "Pause the first save")
        let runID = store.beginDiagnostic(kind: .ping, target: "192.0.2.1")
        var drained = false
        let exitWait = Task {
            await store.waitForWorkspaceWrites()
            drained = true
        }
        await Task.yield()
        store.finishDiagnostic(id: runID, status: .succeeded, summary: "Coalesced terminal result")
        let filter = DiagnosticHistorySearch.Filter(workspaceID: nil, kind: nil, days: nil, text: "")
        let pendingPage = try await store.diagnosticHistoryPage(filter, offset: 0)
        try check(store.isSavingWorkspace && !drained && pendingPage.first?.status == .succeeded,
                  "While the save is blocked, exit waits and History sees the latest terminal result")
        try check(flock(descriptor, LOCK_UN) == 0, "Allow queued saves to finish")
        await exitWait.value
        let committed = try repository.diagnosticPage(DiagnosticPageQuery(limit: 1))
        try check(drained && committed.first?.id == runID && committed.first?.status == .succeeded,
                  "The wait drains all queued edits before reporting completion")

        try sqlite(url, "CREATE TRIGGER fail_save BEFORE INSERT ON diagnostic_runs BEGIN SELECT RAISE(ABORT,'injected save failure'); END;")
        let unsaved = store.beginDiagnostic(kind: .tcp, target: "192.0.2.2")
        await store.waitForWorkspaceWrites()
        let failedPage = try await store.diagnosticHistoryPage(filter, offset: 0)
        let durablePage = try repository.diagnosticPage(DiagnosticPageQuery(limit: 1))
        try check(store.persistenceError != nil && failedPage.first?.id == unsaved && durablePage.first?.id == runID,
                  "Failed saves preserve SQLite and keep the latest snapshot available for retry")
        try sqlite(url, "DROP TRIGGER fail_save;")
        store.save()
        await store.waitForWorkspaceWrites()
        let retried = try repository.diagnosticPage(DiagnosticPageQuery(limit: 1))
        try check(store.persistenceError == nil && retried.first?.id == unsaved, "Retry commits the latest live snapshot")

        try check(flock(descriptor, LOCK_EX) == 0, "Pause a save before backup restore")
        store.upsert(OperationsWorkspace(name: "Queued before restore"))
        let restore = Task { try await store.importBackupInBackground(from: backupURL) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !store.isRestoringBackup && ContinuousClock.now < deadline { await Task.yield() }
        try check(store.isRestoringBackup && store.isSavingWorkspace && !store.canEditWorkspace,
                  "Restore prevents new writes while waiting for the queued save")
        try check(flock(descriptor, LOCK_UN) == 0, "Let save commit before restore runs")
        try await restore.value
        let reopened = try SQLiteAssetRepository(url: url).load()
        try check(reopened?.workspaces == store.workspaces && store.workspaces.count == 2 &&
                  !(reopened?.diagnosticRuns.contains { $0.id == unsaved } ?? true),
                  "The backup is durable and no previously queued write can overwrite it")
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
        guard let backup = try SQLiteAssetRepository(url: backupURL).load() else {
            throw CheckFailure(description: "The standalone WAL backup must contain a snapshot")
        }
        try check(backup == snapshot, "Online SQLite backup includes the latest committed WAL pages while an older reader remains open")
        let restoreURL = directory.appendingPathComponent("wal-restored.sqlite")
        let damaged = Data("damaged database before WAL restore".utf8)
        try damaged.write(to: restoreURL)
        let target = SQLiteAssetRepository(url: restoreURL)
        guard let preserved = try target.restore(backup, preservingDamaged: true) else {
            throw CheckFailure(description: "WAL backup restoration must preserve the damaged destination")
        }
        let restored = try SQLiteAssetRepository(url: restoreURL).load()
        let preservedBytes = try Data(contentsOf: preserved)
        try check(restored == snapshot && preservedBytes == damaged,
                  "Restoring the WAL backup retains the latest committed data and preserves the damaged original")
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
