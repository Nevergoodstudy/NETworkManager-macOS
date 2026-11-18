import Foundation
import Darwin
@testable import NMCore

/// Uses fresh NMTest processes and isolated support folders. The explicit-path
/// repository checks keep their existing optimistic-revision contract.
enum AssetWorkspaceOwnershipChecks {
    private static let childFlag = "--asset-workspace-owner-child"

    static func runChildIfRequested() throws {
        guard CommandLine.arguments.contains(childFlag) else { return }
        guard let directoryPath = ProcessInfo.processInfo.environment["NETWORKMANAGER_SUPPORT_DIRECTORY"] else {
            throw CheckFailure(description: "Ownership child requires an isolated support directory")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let store = AssetStore()
        try check(store.canEditWorkspace && store.persistenceError == nil && store.primaryWorkspace != nil,
                  "Ownership child opens and seeds its default workspace")
        let runID = store.beginDiagnostic(kind: .ping, target: "127.0.0.1")
        store.load()
        try check(store.diagnosticRuns.first { $0.id == runID }?.status == .running,
                  "Reloading the owner's store does not interrupt its own active diagnostic")
        try Data(runID.uuidString.utf8).write(to: directory.appendingPathComponent("owner.ready"), options: .atomic)

        // A bounded handshake also releases the owner if a regression makes
        // the contender block instead of rejecting access immediately.
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(15)
        while true {
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1_000))
            let result = Darwin.poll(&input, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, let command = readLine() else {
                throw CheckFailure(description: "Ownership child did not receive its parent command")
            }
            if command == "spawn" {
                let pid = try spawnDescriptorInheritanceProbe()
                try Data(String(pid).utf8).write(to: directory.appendingPathComponent("descendant.pid"), options: .atomic)
            } else {
                try check(command == "finish", "Ownership child accepts a known command")
                store.finishDiagnostic(id: runID, status: .succeeded, summary: "Owner finished after contention", source: "Ownership regression")
                try check(store.persistenceError == nil, "The active owner saves its diagnostic after contender rejection")
                withExtendedLifetime(store) { Darwin.exit(0) }
            }
        }
    }

    static func run(in directory: URL) throws {
        try startupAndMigration(in: directory)
        try contentionAndNormalExit(in: directory.appendingPathComponent("ownership-normal", isDirectory: true))
        try killedOwnerRecovery(in: directory.appendingPathComponent("ownership-killed", isDirectory: true))
        try blockedRetryIntoRecovery(in: directory.appendingPathComponent("ownership-retry-recovery", isDirectory: true))
        try importedRecoveryKeepsActiveRun(in: directory.appendingPathComponent("ownership-import-recovery", isDirectory: true))
        try descriptorInheritance(in: directory.appendingPathComponent("ownership-exec", isDirectory: true))
        try unavailableAccess(in: directory)
    }

    private static func startupAndMigration(in root: URL) throws {
        for migrate in [false, true] {
            let directory = root.appendingPathComponent(migrate ? "ownership-before-migration" : "ownership-before-creation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = directory.appendingPathComponent("assets.sqlite")
            let legacy = directory.appendingPathComponent("assets.json")
            let legacyWorkspace = OperationsWorkspace(name: "Legacy workspace must survive contention")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let original = try encoder.encode(AssetSnapshot(workspaces: [legacyWorkspace]))
            if migrate { try original.write(to: legacy) }

            let descriptor = Darwin.open(database.path + ".owner.lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CheckFailure(description: "The startup fixture cannot create its ownership lock") }
            defer { Darwin.close(descriptor) }
            try check(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "The startup fixture owns the unopened workspace")
            let inode = try lockInode(at: database)
            try withSupportDirectory(directory) {
                let blocked = AssetStore()
                try check(blocked.workspaceAccessError != nil && blocked.recoveryError == nil && blocked.workspaces.isEmpty &&
                          !FileManager.default.fileExists(atPath: database.path) &&
                          !FileManager.default.fileExists(atPath: database.path + ".initialized"),
                          "Ownership contention blocks initial creation and migration before touching the database")
                try check(flock(descriptor, LOCK_UN) == 0, "The startup fixture releases ownership")
                blocked.retryWorkspaceAccess()
                try check(blocked.canEditWorkspace && blocked.workspaceAccessError == nil && blocked.persistenceError == nil &&
                          FileManager.default.fileExists(atPath: database.path),
                          "A first-open retry can safely create or migrate the workspace")
                if migrate {
                    let retained = try Data(contentsOf: legacy)
                    try check(blocked.workspaces.map(\.id) == [legacyWorkspace.id] && retained == original,
                              "Retry migrates the exact legacy workspace and preserves its JSON bytes")
                } else {
                    try check(blocked.primaryWorkspace != nil && !blocked.sites.isEmpty && !blocked.devices.isEmpty,
                              "Retrying an empty first-open workspace seeds the local workspace exactly once")
                    let count = blocked.workspaces.count
                    blocked.retryWorkspaceAccess()
                    try check(blocked.workspaces.count == count, "A successful first-open retry does not seed duplicate workspaces")
                }
                let after = try lockInode(at: database)
                try check(after == inode, "First-open retry retains the same stable owner-lock inode")
            }
        }

        let database = root.appendingPathComponent("ownership-repository-lifetime.sqlite")
        var owner: SQLiteAssetRepository? = SQLiteAssetRepository(url: database, requiresExclusiveOwnership: true)
        _ = try owner!.load()
        let replacement = SQLiteAssetRepository(url: database, requiresExclusiveOwnership: true)
        try expectInUse { _ = try replacement.load() }
        owner = nil
        _ = try replacement.load()
        try check(FileManager.default.fileExists(atPath: database.path),
                  "Destroying the owner repository releases access before process exit")
    }

    private static func contentionAndNormalExit(in directory: URL) throws {
        let owner = try OwnerProcess(directory: directory)
        defer { owner.stop() }
        let url = directory.appendingPathComponent("assets.sqlite")
        let observer = SQLiteAssetRepository(url: url)
        let before = try requireSnapshot(observer.load())
        let revision = try readRevision(at: url)
        let inode = try lockInode(at: url)
        let runID = try owner.runID()
        try check(before.diagnosticRuns.first { $0.id == runID }?.status == .running,
                  "The independent owner persists a real running diagnostic before contention")

        let repository = SQLiteAssetRepository(url: url, requiresExclusiveOwnership: true)
        let started = Date()
        try expectInUse { _ = try repository.load() }
        try expectInUse { try repository.save(before) }
        try expectInUse { _ = try repository.diagnosticPage(DiagnosticPageQuery()) }
        let backup = directory.appendingPathComponent("blocked-backup.sqlite")
        try expectInUse { try repository.createBackup(at: backup) }
        try expectInUse { _ = try repository.restore(before, preservingDamaged: false) }
        try expectInUse { _ = try repository.restore(before, preservingDamaged: true) }
        try check(Date().timeIntervalSince(started) < 2,
                  "Every competing repository operation rejects ownership promptly")
        try check(!FileManager.default.fileExists(atPath: backup.path),
                  "A blocked backup never creates a misleading output file")

        try withSupportDirectory(directory) {
            let blocked = AssetStore()
            try check(blocked.workspaceAccessError != nil && blocked.recoveryError == nil && !blocked.canEditWorkspace,
                      "A second default store reports workspace access separately from damaged-data recovery")
            try check(blocked.workspaces.isEmpty && blocked.devices.isEmpty && blocked.diagnosticRuns.isEmpty,
                      "A blocked default store does not seed a replacement workspace")
            let document = AssetStore.BackupDocument(formatVersion: 1, exportedAt: Date(), workspaces: before.workspaces,
                sites: before.sites, subnets: before.subnets, devices: before.devices, diagnosticRuns: before.diagnosticRuns)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let validBackup = try encoder.encode(document)
            try expectInUse { _ = try blocked.exportBackup() }
            try expectInUse { try blocked.importBackup(validBackup) }
            try expectInUse { try blocked.importBackup(Data("{}".utf8)) }
            try expectInUse { _ = try blocked.diagnosticPage() }

            let workspace = OperationsWorkspace(name: "Must never be seeded")
            let site = AssetSite(workspaceID: workspace.id, name: "Blocked")
            blocked.upsert(workspace)
            blocked.upsert(site)
            blocked.upsert(AssetSubnet(siteID: site.id, name: "Blocked", cidr: "192.0.2.0/24"))
            blocked.upsert(AssetDevice(siteID: site.id, name: "Blocked", address: "192.0.2.1"))
            let changed = blocked.mergeExternalAssets([ExternalAssetSnapshot(source: "ownership-test", fetchedAt: Date(),
                siteName: "Blocked", deviceName: "Blocked", address: "192.0.2.2")])
            blocked.removeWorkspace(id: before.workspaces[0].id)
            for site in before.sites { blocked.removeSite(id: site.id) }
            for subnet in before.subnets { blocked.removeSubnet(id: subnet.id) }
            for device in before.devices { blocked.removeDevice(id: device.id) }
            _ = blocked.beginDiagnostic(kind: .dns, target: "blocked.invalid")
            blocked.finishDiagnostic(id: runID, status: .failed, summary: "Must not affect owner")
            blocked.save()
            blocked.retryWorkspaceAccess()
            try check(changed == 0 && blocked.workspaces.isEmpty && blocked.sites.isEmpty && blocked.subnets.isEmpty &&
                      blocked.devices.isEmpty && blocked.diagnosticRuns.isEmpty && blocked.workspaceAccessError != nil &&
                      blocked.recoveryError == nil && blocked.persistenceError == nil,
                      "All blocked store mutation paths preserve an empty unavailable facade")
            let during = try requireSnapshot(observer.load())
            let duringRevision = try readRevision(at: url)
            try check(during == before && duringRevision == revision,
                      "Contender load, retry, writes, imports and recovery preserve every owner record and revision")

            try owner.send("finish")
            try owner.waitForExit()
            blocked.retryWorkspaceAccess()
            try check(blocked.canEditWorkspace && blocked.workspaceAccessError == nil && blocked.recoveryError == nil &&
                      blocked.persistenceError == nil && blocked.devices == before.devices &&
                      blocked.diagnosticRuns.first { $0.id == runID }?.status == .succeeded,
                      "A blocked store retries after normal owner exit and loads the owner's completed diagnostic")
            let retryInode = try lockInode(at: url)
            try check(retryInode == inode,
                      "Normal owner exit and retry retain the same stable owner-lock inode")
            blocked.upsert(OperationsWorkspace(name: "New owner can write"))
            try check(blocked.persistenceError == nil && blocked.workspaces.count == before.workspaces.count + 1,
                      "The successful retry can save using its fresh revision baseline")
        }
    }

    private static func killedOwnerRecovery(in directory: URL) throws {
        let owner = try OwnerProcess(directory: directory)
        defer { owner.stop() }
        let url = directory.appendingPathComponent("assets.sqlite")
        let runID = try owner.runID()
        let inode = try lockInode(at: url)
        owner.kill()
        try owner.waitForExit(expectedSignal: SIGKILL)
        try withSupportDirectory(directory) {
            let replacement = AssetStore()
            let recovered = replacement.diagnosticRuns.first { $0.id == runID }
            try check(replacement.canEditWorkspace && replacement.persistenceError == nil &&
                      recovered?.status == .interrupted && recovered?.finishedAt != nil,
                      "SIGKILL releases ownership and the next default store durably recovers the unfinished diagnostic")
            let persisted = try SQLiteAssetRepository(url: url).load()
            try check(persisted?.diagnosticRuns.first { $0.id == runID }?.status == .interrupted,
                      "Crash recovery commits interruption to the persistent database")
            let recoveredInode = try lockInode(at: url)
            try check(recoveredInode == inode,
                      "Crash recovery reacquires the existing owner-lock inode")
        }
    }

    private static func descriptorInheritance(in directory: URL) throws {
        let owner = try OwnerProcess(directory: directory)
        defer { owner.stop() }
        try owner.send("spawn")
        let marker = directory.appendingPathComponent("descendant.pid")
        try owner.waitForFile(marker)
        guard let pid = Int32(try String(contentsOf: marker, encoding: .utf8)) else {
            throw CheckFailure(description: "Descriptor probe did not publish a valid process ID")
        }
        defer { Darwin.kill(pid, SIGKILL) }
        try owner.send("finish")
        try owner.waitForExit()
        try check(Darwin.kill(pid, 0) == 0,
                  "The external exec descendant remains alive after its owner exits")
        try withSupportDirectory(directory) {
            let replacement = AssetStore()
            try check(replacement.canEditWorkspace && replacement.workspaceAccessError == nil,
                      "An exec descendant cannot retain the exited owner's lock descriptor")
        }
    }

    private static func blockedRetryIntoRecovery(in directory: URL) throws {
        let owner = try OwnerProcess(directory: directory)
        defer { owner.stop() }
        let database = directory.appendingPathComponent("assets.sqlite")
        let workspace = OperationsWorkspace(name: "Recovered after ownership contention")
        let backup = try recoveryBackup(workspace: workspace)
        let damagedBytes = Data("Corrupted after the previous owner exited".utf8)
        try withSupportDirectory(directory) {
            let blocked = AssetStore()
            try check(blocked.workspaceAccessError != nil && blocked.recoveryError == nil,
                      "The recovery-transition fixture starts blocked by a live owner")
            try owner.send("finish")
            try owner.waitForExit()
            try damagedBytes.write(to: database, options: .atomic)
            blocked.retryWorkspaceAccess()
            try check(blocked.workspaceAccessError == nil && blocked.recoveryError != nil && !blocked.canEditWorkspace && blocked.workspaces.isEmpty,
                      "A retry that acquires ownership but encounters corruption clears stale access failure and enters recovery")
            try blocked.importBackup(backup)
            guard let preserved = blocked.preservedCorruptFileURL else {
                throw CheckFailure(description: "Recovery after contention must preserve the damaged database")
            }
            let retained = try Data(contentsOf: preserved)
            let persisted = try SQLiteAssetRepository(url: database).load()
            try check(retained == damagedBytes && blocked.workspaceAccessError == nil && blocked.recoveryError == nil &&
                      blocked.canEditWorkspace && blocked.workspaces.map(\.id) == [workspace.id] &&
                      persisted?.workspaces.map(\.id) == [workspace.id],
                      "A valid backup restores the retried workspace while retaining the exact damaged original bytes")
        }
    }

    private static func importedRecoveryKeepsActiveRun(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("assets.sqlite")
        let damagedBytes = Data("Initially damaged workspace".utf8)
        try damagedBytes.write(to: database)
        let workspace = OperationsWorkspace(name: "Recovered initial workspace")
        let backup = try recoveryBackup(workspace: workspace)
        try withSupportDirectory(directory) {
            let store = AssetStore()
            try check(store.workspaceAccessError == nil && store.recoveryError != nil && store.workspaces.isEmpty,
                      "The import-recovery fixture first fails to load its damaged database")
            try store.importBackup(backup)
            let runID = store.beginDiagnostic(kind: .tcp, target: "127.0.0.1", parameters: ["port": "443"])
            store.load()
            let run = store.diagnosticRuns.first { $0.id == runID }
            let persisted = try SQLiteAssetRepository(url: database).load()
            try check(store.canEditWorkspace && store.persistenceError == nil && run?.status == .running &&
                      run?.finishedAt == nil && persisted?.diagnosticRuns.first { $0.id == runID }?.status == .running,
                      "Importing recovery establishes a loaded workspace so later reload cannot interrupt a newly started diagnostic")
            guard let preserved = store.preservedCorruptFileURL else {
                throw CheckFailure(description: "Initial import recovery must expose its preserved damaged original")
            }
            let retained = try Data(contentsOf: preserved)
            try check(retained == damagedBytes, "Initial backup recovery preserves the exact damaged database bytes")
            store.finishDiagnostic(id: runID, status: .succeeded, summary: "Recovered owner finished normally")
            try check(store.persistenceError == nil && store.diagnosticRuns.first { $0.id == runID }?.status == .succeeded,
                      "The recovered owner can finish and save its new diagnostic after reload")
        }
    }

    private static func recoveryBackup(workspace: OperationsWorkspace) throws -> Data {
        let document = AssetStore.BackupDocument(formatVersion: 1, exportedAt: Date(), workspaces: [workspace],
            sites: [], subnets: [], devices: [], diagnosticRuns: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    private static func unavailableAccess(in directory: URL) throws {
        let obstacle = directory.appendingPathComponent("workspace-folder-is-a-file")
        let original = Data("Preserve the inaccessible workspace obstacle".utf8)
        try original.write(to: obstacle)
        let repository = SQLiteAssetRepository(url: obstacle.appendingPathComponent("assets.sqlite"), requiresExclusiveOwnership: true)
        try expectUnavailable { _ = try repository.load() }
        try withSupportDirectory(obstacle) {
            let store = AssetStore()
            try check(store.workspaceAccessError != nil && store.recoveryError == nil && !store.canEditWorkspace && store.workspaces.isEmpty,
                      "A folder-access failure is unavailable access and never damaged-data recovery")
            try expectUnavailable { try store.importBackup(Data("{}".utf8)) }
            try expectUnavailable { _ = try store.exportBackup() }
            try expectUnavailable { _ = try store.diagnosticPage() }
        }
        let retained = try Data(contentsOf: obstacle)
        try check(retained == original, "An inaccessible workspace leaves the obstacle's exact bytes untouched")

        let symlinkDirectory = directory.appendingPathComponent("symlink-owner-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let database = symlinkDirectory.appendingPathComponent("assets.sqlite")
        try FileManager.default.createSymbolicLink(at: database.appendingPathExtension("owner.lock"), withDestinationURL: obstacle)
        let symlinked = SQLiteAssetRepository(url: database, requiresExclusiveOwnership: true)
        try expectUnavailable { _ = try symlinked.load() }
        try check(!FileManager.default.fileExists(atPath: database.path),
                  "A symlinked owner lock is rejected before creating or migrating a database")
    }

    private static func expectInUse(_ body: () throws -> Void) throws {
        do { try body() } catch AssetWorkspaceAccessError.inUse { return }
        catch { throw CheckFailure(description: "Expected workspace in-use error, got \(error)") }
        throw CheckFailure(description: "An operation bypassed a live workspace owner's lock")
    }

    private static func expectUnavailable(_ body: () throws -> Void) throws {
        do { try body() } catch AssetWorkspaceAccessError.unavailable { return }
        catch { throw CheckFailure(description: "Expected workspace unavailable error, got \(error)") }
        throw CheckFailure(description: "An inaccessible workspace was accepted")
    }

    private static func withSupportDirectory<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let key = "NETWORKMANAGER_SUPPORT_DIRECTORY"
        let previous = getenv(key).map { String(cString: $0) }
        try check(setenv(key, directory.path, 1) == 0, "The storage fixture installs its support-directory override")
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        try check(SettingsStore.resolvedSupportDirectory().standardizedFileURL.path == directory.standardizedFileURL.path,
                  "Default storage resolves exclusively to the fixture's isolated support directory")
        return try body()
    }

    private static func requireSnapshot(_ snapshot: AssetSnapshot?) throws -> AssetSnapshot {
        guard let snapshot else { throw CheckFailure(description: "The owner did not publish its workspace snapshot") }
        return snapshot
    }

    private static func lockInode(at database: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: database.path + ".owner.lock")
        guard let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CheckFailure(description: "The ownership lock has no inode")
        }
        return inode.uint64Value
    }

    private static func readRevision(at database: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database.path, "SELECT value FROM metadata WHERE key='revision';"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "The ownership fixture reads the persistent revision")
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Foundation Process may close unrelated descriptors itself. A plain
    /// posix_spawn with default attributes makes O_CLOEXEC the tested boundary.
    private static func spawnDescriptorInheritanceProbe() throws -> pid_t {
        let strings: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "30"].map { value in
            value.withCString { strdup($0) }
        }
        defer { strings.forEach { free($0) } }
        var arguments = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions) == 0,
                  "The descriptor probe initializes its explicit standard streams")
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let flags = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            try check(posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", flags, 0) == 0,
                      "The descriptor probe detaches inherited fixture pipes")
        }
        var pid: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, "/bin/sleep", &actions, nil, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        try check(result == 0, "The descriptor-inheritance probe starts its external executable")
        return pid
    }

    private final class OwnerProcess {
        let directory: URL
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--storage-only", childFlag]
            var environment = ProcessInfo.processInfo.environment
            environment["NETWORKMANAGER_SUPPORT_DIRECTORY"] = directory.path
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                try waitForFile(directory.appendingPathComponent("owner.ready"))
            } catch {
                stop()
                throw error
            }
        }

        func runID() throws -> UUID {
            let value = try String(contentsOf: directory.appendingPathComponent("owner.ready"), encoding: .utf8)
            guard let id = UUID(uuidString: value) else { throw CheckFailure(description: "The owner did not publish its diagnostic ID") }
            return id
        }

        func send(_ command: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        }

        func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

        func waitForFile(_ url: URL) throws {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: url.path) {
                guard process.isRunning, Date() < deadline else {
                    stop()
                    let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    throw CheckFailure(description: "Owner fixture did not publish \(url.lastPathComponent): \(details)")
                }
                usleep(10_000)
            }
        }

        func waitForExit(expectedSignal: Int32? = nil) throws {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            guard !process.isRunning else { stop(); throw CheckFailure(description: "The ownership fixture did not exit promptly") }
            process.waitUntilExit()
            let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let expectedSignal {
                try check(process.terminationReason == .uncaughtSignal && process.terminationStatus == expectedSignal,
                          "The owner was terminated by the requested signal: \(details)")
            } else {
                try check(process.terminationReason == .exit && process.terminationStatus == 0,
                          "The owner completed and exited normally: \(details)")
            }
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            kill()
            if process.processIdentifier > 0 { process.waitUntilExit() }
        }
    }
}
