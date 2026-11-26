import Foundation
@testable import NMCore

enum FieldCaseLibraryChecks {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func ticketTrace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMTicketTrace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = try fixture()
        let firstURL = directory.appendingPathComponent("first.nmfieldproject")
        let secondURL = directory.appendingPathComponent("second.nmfieldproject")
        try project.encoded().write(to: firstURL)
        try project.encoded().write(to: secondURL)
        let library = FieldCaseLibrary(url: directory.appendingPathComponent("library.sqlite"))
        _ = try library.importProject(project, from: firstURL, expectedRevision: nil, loadedAt: now)
        _ = try library.importProject(project, from: secondURL, expectedRevision: nil, loadedAt: now)

        let exact = try library.search(FieldIncidentQuery(ticketReference: "  TICKET-001  "))
        try check(exact.total == 2, "Ticket lookup trims surrounding whitespace and keeps copied cases")
        try check(try library.search(FieldIncidentQuery(ticketReference: "TICKET-00")).total == 0,
                  "Ticket lookup requires the complete identifier")
        try check(try library.search(FieldIncidentQuery(ticketReference: "ticket-001")).total == 0,
                  "Ticket lookup preserves case sensitivity")
        let excluded = FieldIncidentQuery(ticketReference: "TICKET-001", excludingCaseID: exact.results[0].id)
        let remaining = try library.search(excluded)
        try check(remaining.total == 1 && remaining.results[0].id != exact.results[0].id,
                  "Ticket lookup excludes only the selected source and incident identity")
        var catalog = FieldIncidentCatalog()
        for source in try library.sources() {
            try catalog.upsert(project: project, sourceID: source.id, label: source.label)
        }
        let sessionMatches = try catalog.search(excluded)
        try check(sessionMatches.total == remaining.total && sessionMatches.results.map(\.id) == remaining.results.map(\.id),
                  "Session and SQLite ticket lookup agree on composite Case exclusion")
        let firstPage = try library.search(FieldIncidentQuery(ticketReference: "TICKET-001"), limit: 1)
        let secondPage = try library.search(FieldIncidentQuery(ticketReference: "TICKET-001"), limit: 1, offset: 1)
        try check(firstPage.total == 2 && secondPage.total == 2 && firstPage.results[0].id != secondPage.results[0].id,
                  "Ticket totals remain stable across pages")

        let migratedURL = directory.appendingPathComponent("legacy.sqlite")
        let sourceID = directory.appendingPathComponent("legacy.nmfieldproject").absoluteString
        let legacy = try AssetDatabase(url: migratedURL, create: true)
        try legacy.execute("PRAGMA application_id=0x4e4d434c")
        try legacy.execute("PRAGMA user_version=1")
        try legacy.execute("CREATE TABLE sources(id TEXT PRIMARY KEY,label TEXT NOT NULL,loaded_at REAL NOT NULL,revision TEXT NOT NULL,project BLOB NOT NULL)")
        try legacy.execute("CREATE TABLE cases(source_id TEXT NOT NULL,id TEXT NOT NULL,status TEXT NOT NULL,device_key TEXT,device_id TEXT,created_at REAL NOT NULL,latest_at REAL NOT NULL,search_text TEXT NOT NULL,PRIMARY KEY(source_id,id))")
        try legacy.execute("CREATE TABLE observations(source_id TEXT NOT NULL,case_id TEXT NOT NULL,id TEXT NOT NULL,occurred_at REAL NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(source_id,case_id,id))")
        let incident = project.incidents[0]
        let revision = UUID()
        try legacy.execute("INSERT INTO sources VALUES(?,?,?,?,?)", [.text(sourceID), .text("legacy"), .real(now.timeIntervalSince1970), .text(revision.uuidString), .blob(try project.encoded())])
        try legacy.execute("INSERT INTO cases VALUES(?,?,?,?,?,?,?,?)", [.text(sourceID), .text(incident.id.uuidString), .text(incident.status.rawValue), .null, .null, .real(incident.createdAt.timeIntervalSince1970), .real(incident.createdAt.timeIntervalSince1970), .text(FieldIncidentQuery().searchText(for: incident))])
        for entry in incident.entries {
            try legacy.execute("INSERT INTO observations VALUES(?,?,?,?,?)", [.text(sourceID), .text(incident.id.uuidString), .text(entry.id.uuidString), .real(entry.occurredAt.timeIntervalSince1970), .blob(try JSONEncoder().encode(entry))])
        }
        try legacy.close()

        let reopened = FieldCaseLibrary(url: migratedURL)
        let migrated = try reopened.search(FieldIncidentQuery(ticketReference: "TICKET-001"))
        try check(migrated.total == 1 && migrated.results.map(\.incident.id) == [incident.id],
                  "Schema 1 migration backfills the ticket key for the saved Case")
        try check(try reopened.observations(for: migrated.results[0].id) == incident.timeline,
                  "Schema 1 migration preserves the complete ordered timeline and retest link")
        let migratedDatabase = try AssetDatabase(url: migratedURL, create: false)
        try check(try migratedDatabase.integer("PRAGMA user_version") == 2, "Schema migration publishes version 2 after backfill")
        try check(try migratedDatabase.integer("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='case_ticket_date'") == 1,
                  "Schema 1 migration installs the ticket index")
        try migratedDatabase.close()
        print("Ticket trace: exact matching, copied-case exclusion, pagination and schema migration passed")
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMCaseLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cases.sqlite")
        let firstURL = directory.appendingPathComponent("one.nmfieldproject")
        let copyURL = directory.appendingPathComponent("copy.nmfieldproject")
        let project = try fixture()
        let bytes = try project.encoded()
        try bytes.write(to: firstURL)
        let library = FieldCaseLibrary(url: path)
        try check(try library.sources().isEmpty, "A new case library is empty")
        let revision = try library.importProject(project, from: firstURL, expectedRevision: nil, loadedAt: now)
        let copyRevision = try library.importProject(project, from: copyURL, expectedRevision: nil, loadedAt: now)
        try check(try Data(contentsOf: firstURL) == bytes, "Import leaves the saved project unchanged")
        try FileManager.default.removeItem(at: firstURL)
        let reopened = FieldCaseLibrary(url: path)
        let page = try reopened.search(FieldIncidentQuery())
        try check(page.total == 6 && Set(page.results.map(\.id)).count == 6,
                  "Reopen works without source files and retains independent copied case IDs")
        let saved = try reopened.search(FieldIncidentQuery(text: "TICKET-001")).results[0]
        try check(saved.source.project == project && saved.source.loadedAt == now &&
                  saved.source.project.retestRuns.count == 1 && saved.incident.baselineRevisionID != nil,
                  "The library restores project baselines, timestamps and saved retest evidence")
        try check(try reopened.observations(for: saved.id) == saved.incident.timeline,
                  "Normalized observation rows restore the exact ordered entries and retest link")
        let sources = try reopened.sources()
        try check(sources.count == 2 && sources.allSatisfy { $0.caseCount == 3 && $0.observationCount == 3 },
                  "Persistent source summaries count cases and observations independently")
        try queryChecks(library: reopened, project: project)

        var invalidJSON = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        invalidJSON["schemaVersion"] = 99
        let unchecked = try JSONDecoder().decode(FieldProject.self, from: JSONSerialization.data(withJSONObject: invalidJSON))
        try rejects { try reopened.importProject(unchecked, from: firstURL, expectedRevision: revision) }
        try check(try reopened.search(FieldIncidentQuery()).total == 6 && reopened.sources().first { $0.id == firstURL.absoluteString }?.revision == revision,
                  "Invalid imports preserve the old source revision and all rows")

        // A mid-write SQLite failure must restore the deleted source and its children.
        let database = try AssetDatabase(url: path, create: false)
        try database.execute("CREATE TRIGGER fixture_failure BEFORE INSERT ON observations BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        try database.close()
        try rejects { try reopened.importProject(project, from: firstURL, expectedRevision: revision) }
        let afterFailure = try reopened.search(FieldIncidentQuery(text: "TICKET-001"))
        try check(afterFailure.total == 2 && reopened.observations(for: saved.id) == saved.incident.timeline,
                  "A failed replacement transaction rolls back the source, cases and observations together")
        let cleanup = try AssetDatabase(url: path, create: false)
        try cleanup.execute("DROP TRIGGER fixture_failure")
        try cleanup.close()

        let newRevision = try reopened.importProject(FieldProject(), from: copyURL, expectedRevision: copyRevision)
        try check(try reopened.search(FieldIncidentQuery()).total == 3 && reopened.sources().first { $0.id == copyURL.absoluteString }?.observationCount == 0,
                  "Refreshing a source removes obsolete cases and observations atomically")
        try expectConflict { try library.importProject(project, from: copyURL, expectedRevision: copyRevision) }
        try expectConflict { try library.importProject(project, from: firstURL, expectedRevision: nil) }
        try check(try reopened.sources().first { $0.id == copyURL.absoluteString }?.revision == newRevision,
                  "A stale window cannot replace a newer saved source")
        try concurrentRefresh(path: path, source: firstURL, revision: revision, project: project)
        try reopened.removeSource(id: copyURL.absoluteString, expectedRevision: newRevision)
        try check(try reopened.sources().count == 1 && reopened.search(FieldIncidentQuery()).total == 3,
                  "Removing a cached source does not remove another copy of its incidents")
        try rejects { try reopened.removeSource(id: firstURL.absoluteString, expectedRevision: revision) }
        let current = try reopened.sources()[0]
        try bytes.write(to: firstURL)
        try reopened.removeSource(id: current.id, expectedRevision: current.revision)
        try check(try reopened.search(FieldIncidentQuery()).total == 0 && reopened.observations(for: saved.id).isEmpty && Data(contentsOf: firstURL) == bytes,
                  "Removal cascades to observations and preserves the original project file")
        try schemaAndLossChecks(in: directory)
        try capChecks(in: directory)
        print("Case library: persistence, query, refresh, rollback, conflict, schema and limits passed")
    }

    private static func queryChecks(library: FieldCaseLibrary, project: FieldProject) throws {
        var memory = FieldIncidentCatalog()
        let sources = try library.sources()
        for source in sources { try memory.upsert(project: project, sourceID: source.id, label: source.label) }
        let asset = project.incidents[0].asset!
        var localDevice = AssetDevice(siteID: UUID(), name: "Local", address: "192.0.2.1")
        localDevice.id = asset.deviceID
        let local = FieldIncidentAssetReference(device: localDevice)
        let queries = [
            FieldIncidentQuery(), FieldIncidentQuery(text: "TICKET-001 operator"),
            FieldIncidentQuery(text: "äTHER straSSE 中文"), FieldIncidentQuery(text: "% _ ' OR 1=1 --"),
            FieldIncidentQuery(text: "A\0B"), FieldIncidentQuery(text: "Café"), FieldIncidentQuery(text: "Cafe\u{301}"),
            FieldIncidentQuery(status: .resolved), FieldIncidentQuery(asset: asset), FieldIncidentQuery(asset: local),
            FieldIncidentQuery(text: "flap", status: .resolved),
            FieldIncidentQuery(occurredFrom: now, occurredThrough: now),
            FieldIncidentQuery(occurredFrom: now.addingTimeInterval(100), occurredThrough: now.addingTimeInterval(101))
        ]
        for query in queries {
            let expected = try memory.search(query)
            let actual = try library.search(query)
            try check(expected.results.map(\.id) == actual.results.map(\.id) && expected.total == actual.total,
                      "SQLite and session search agree for text, Unicode, device, status and occurrence predicates")
        }
        try check(try library.search(FieldIncidentQuery(text: "äTHER straSSE 中文")).total == 2,
                  "Unicode folding matches across case and multiple fields")
        try check(try library.search(FieldIncidentQuery(asset: asset)).total == 4,
                  "External identities follow an IPv4 to IPv6 change without merging another device with the same IP")
        try check(try library.search(FieldIncidentQuery(asset: local)).total == 4,
                  "An older local device reference also finds later external-identity snapshots with the same UUID")
        let first = try library.search(FieldIncidentQuery(), limit: 2)
        let second = try library.search(FieldIncidentQuery(), limit: 2, offset: 2)
        try check(first.total == 6 && Set(first.results.map(\.id)).isDisjoint(with: Set(second.results.map(\.id))),
                  "Bounded pages have stable ordering and no repeated tied results")
        try check(try library.search(FieldIncidentQuery(), offset: 100).results.isEmpty, "Out-of-range pages are empty")
        try rejects { _ = try library.search(FieldIncidentQuery(), limit: 101) }
        try rejects { _ = try library.search(FieldIncidentQuery(), offset: -1) }
        try rejects { _ = try library.search(FieldIncidentQuery(text: String(repeating: "x", count: 2001))) }
        try rejects { _ = try library.search(FieldIncidentQuery(text: (0...100).map { "t\($0)" }.joined(separator: " "))) }
        try rejects { _ = try library.search(FieldIncidentQuery(occurredFrom: now, occurredThrough: now.addingTimeInterval(-1))) }
    }

    private static func concurrentRefresh(path: URL, source: URL, revision: UUID, project: FieldProject) throws {
        final class Outcomes: @unchecked Sendable {
            let lock = NSLock()
            var successes = 0
            var conflicts = 0
            var errors: [Error] = []
        }
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                try FieldCaseLibrary(url: path).importProject(project, from: source, expectedRevision: revision)
                outcomes.lock.lock(); outcomes.successes += 1; outcomes.lock.unlock()
            } catch {
                outcomes.lock.lock()
                if case FieldCaseLibraryError.conflict = error { outcomes.conflicts += 1 }
                else { outcomes.errors.append(error) }
                outcomes.lock.unlock()
            }
        }
        try check(outcomes.successes == 1 && outcomes.conflicts == 1 && outcomes.errors.isEmpty,
                  "Concurrent writers publish exactly one replacement and reject the stale revision")
    }

    private static func schemaAndLossChecks(in directory: URL) throws {
        let futureURL = directory.appendingPathComponent("future.sqlite")
        _ = try FieldCaseLibrary(url: futureURL).sources()
        let future = try AssetDatabase(url: futureURL, create: false)
        try future.execute("PRAGMA user_version=99")
        try future.close()
        let before = try Data(contentsOf: futureURL)
        try rejects { _ = try FieldCaseLibrary(url: futureURL).sources() }
        try check(try Data(contentsOf: futureURL) == before, "Unsupported schemas are rejected without changing the database")
        let damagedURL = directory.appendingPathComponent("damaged.sqlite")
        try Data("damaged fixture".utf8).write(to: damagedURL)
        try rejects { _ = try FieldCaseLibrary(url: damagedURL).sources() }
        try check(try Data(contentsOf: damagedURL) == Data("damaged fixture".utf8), "A damaged library is never silently replaced")
        let missingURL = directory.appendingPathComponent("missing.sqlite")
        let missing = FieldCaseLibrary(url: missingURL)
        _ = try missing.sources()
        try FileManager.default.removeItem(at: missingURL)
        try rejects { _ = try missing.sources() }
        try check(!FileManager.default.fileExists(atPath: missingURL.path), "A missing initialized library is not silently recreated")
    }

    private static func capChecks(in directory: URL) throws {
        let library = FieldCaseLibrary(url: directory.appendingPathComponent("cap.sqlite"))
        for i in 0..<FieldCaseLibrary.maximumSources {
            try library.importProject(FieldProject(), from: directory.appendingPathComponent("source-\(i).nmfieldproject"), expectedRevision: nil)
        }
        try rejects { try library.importProject(FieldProject(), from: directory.appendingPathComponent("excess.nmfieldproject"), expectedRevision: nil) }
        try check(try library.sources().count == FieldCaseLibrary.maximumSources, "The persistent library enforces its source cap")
    }

    private static func fixture() throws -> FieldProject {
        var project = FieldProject()
        project.site = "Synthetic 中文 site"
        var draft = project.acceptanceDraft
        draft.planVersion = "Fixture v1"
        draft.items = [FieldAcceptanceItem(kind: .acceptance)]
        project.acceptanceDraft = draft
        try project.createAcceptanceRevision()
        let baseline = project.acceptanceRevisions[0].id
        let request = FieldRetestRequest(baselineRevisionID: baseline, target: "service.example", method: .systemDNS,
            authorization: FieldRetestAuthorization(reference: "CHG-fixture", confirmedBy: "Fixture", confirmedAt: now,
                windowStart: now.addingTimeInterval(-60), windowEnd: now.addingTimeInterval(60), confirmed: true), networkContext: "Synthetic")
        let run = FieldRetestRecord(request: request, status: .succeeded, startedAt: now, finishedAt: now.addingTimeInterval(0.2),
                                    actualTarget: "127.0.0.1", addressFamily: .ipv4, dnsMode: .system, summary: "Fixture", executedLayers: [.dns])
        guard project.attachRetestRun(run) == .attached else { throw CheckFailure(description: "Fixture retest attachment failed") }
        let external = ExternalAssetIdentity(instance: "https://inventory.example", objectType: "dcim.device", remoteID: "77")
        var device = AssetDevice(siteID: UUID(), name: "Äther", address: "192.0.2.10", externalIdentity: external)
        try project.saveIncident(FieldIncident(title: "Straße interruption", owner: "Owner", ticketReference: "TICKET-001", createdAt: now,
            baselineRevisionID: baseline, asset: FieldIncidentAssetReference(device: device), entries: [
                FieldIncidentEntry(kind: .reported, occurredAt: now, recordedAt: now, author: "Operator", detail: "uplink flap 中文 Café A\0B"),
                FieldIncidentEntry(kind: .retested, occurredAt: now, recordedAt: now.addingTimeInterval(1), author: "Operator", detail: "Saved result", retestRunID: run.id)
            ]))
        device.address = "2001:db8::10"
        try project.saveIncident(FieldIncident(title: "Follow-up", owner: "Other", status: .resolved, createdAt: now.addingTimeInterval(100),
            asset: FieldIncidentAssetReference(device: device)))
        device.id = UUID()
        device.externalIdentity = ExternalAssetIdentity(instance: external.instance, objectType: external.objectType, remoteID: "88")
        device.address = "192.0.2.10"
        try project.saveIncident(FieldIncident(title: "Unrelated", owner: "Owner", createdAt: now,
            asset: FieldIncidentAssetReference(device: device), entries: [
                FieldIncidentEntry(kind: .note, occurredAt: now.addingTimeInterval(-100), author: "Operator", detail: "Different device")
            ]))
        return project
    }

    private static func expectConflict(_ work: () throws -> UUID) throws {
        do { _ = try work() }
        catch FieldCaseLibraryError.conflict { return }
        throw CheckFailure(description: "A stale library source revision must report a conflict")
    }

    private static func rejects<T>(_ work: () throws -> T) throws {
        do { _ = try work() }
        catch { return }
        throw CheckFailure(description: "Invalid case library input must be rejected")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(description: message) }
    }
}
