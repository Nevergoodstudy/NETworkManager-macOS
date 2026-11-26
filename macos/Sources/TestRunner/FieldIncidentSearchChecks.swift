import Foundation
import NMCore
@testable import NMAssets

enum FieldIncidentSearchChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let remote = ExternalAssetIdentity(instance: "https://inventory.example", objectType: "dcim.device", remoteID: "77")
        var device = AssetDevice(siteID: UUID(), name: "Edge", address: "192.0.2.10", externalIdentity: remote)
        let originalReference = FieldIncidentAssetReference(device: device)
        let first = FieldIncident(title: "Office interruption", owner: "Engineer A", ticketReference: "TICKET-001",
                                  createdAt: now, asset: originalReference,
                                  entries: [FieldIncidentEntry(kind: .reported, occurredAt: now, author: "Operator", detail: "uplink flap")])
        device.address = "2001:db8::10"
        let movedReference = FieldIncidentAssetReference(device: device)
        let second = FieldIncident(title: "Maintenance follow-up", owner: "Engineer B", status: .resolved,
                                   createdAt: now.addingTimeInterval(100), asset: movedReference)
        device.id = UUID()
        device.externalIdentity = ExternalAssetIdentity(instance: remote.instance, objectType: remote.objectType, remoteID: "88")
        device.address = originalReference.address
        let unrelated = FieldIncident(title: "Other device", owner: "Engineer A", createdAt: now,
                                      asset: FieldIncidentAssetReference(device: device))
        var project = FieldProject()
        try project.saveIncident(first)
        try project.saveIncident(second)
        try project.saveIncident(unrelated)
        var catalog = FieldIncidentCatalog()
        try catalog.upsert(project: project, sourceID: "file:///one.nmfieldproject", label: "one", loadedAt: now)
        try catalog.upsert(project: project, sourceID: "file:///copy.nmfieldproject", label: "copy", loadedAt: now)
        try check(try catalog.search(FieldIncidentQuery()).total == 6,
                  "Copied files retain distinct source and incident result identities")
        let stable = try catalog.search(FieldIncidentQuery(asset: originalReference))
        try check(stable.total == 4 && stable.results.allSatisfy { $0.incident.id != unrelated.id },
                  "Stable asset queries cross address changes and do not associate devices by equal IP")
        try check(try catalog.search(FieldIncidentQuery(text: "ticket-001 operator")).total == 2,
                  "Case-insensitive multi-term search includes ticket references and timeline authors")
        try check(try catalog.search(FieldIncidentQuery(text: "flap", status: .resolved)).total == 0,
                  "Status and text filters are combined")
        let range = FieldIncidentQuery(occurredFrom: now.addingTimeInterval(-1), occurredThrough: now.addingTimeInterval(1))
        try check(try catalog.search(range).total == 4, "Occurrence filtering uses timeline dates and creation for empty timelines")
        let page1 = try catalog.search(FieldIncidentQuery(), limit: 2)
        let page2 = try catalog.search(FieldIncidentQuery(), limit: 2, offset: 2)
        try check(Set(page1.results.map(\.id)).isDisjoint(with: Set(page2.results.map(\.id))) &&
                  page1.results.allSatisfy { $0.incident.id == second.id }, "Stable ordering and pagination do not overlap tied source results")
        try catalog.upsert(project: FieldProject(), sourceID: "file:///copy.nmfieldproject", label: "copy", loadedAt: now)
        try check(try catalog.search(FieldIncidentQuery()).total == 3 && catalog.sources.count == 2,
                  "Refresh replaces a selected file snapshot without appending stale incidents")
        try rejects { _ = try catalog.search(FieldIncidentQuery(), limit: 0) }
        try rejects { _ = try catalog.search(FieldIncidentQuery(occurredFrom: now, occurredThrough: now.addingTimeInterval(-1))) }
        try rejects { _ = try catalog.search(FieldIncidentQuery(text: String(repeating: "x", count: 2001))) }
        for i in 2..<FieldIncidentCatalog.maximumSources {
            try catalog.upsert(project: FieldProject(), sourceID: "file:///\(i).nmfieldproject", label: String(i))
        }
        try rejects { try catalog.upsert(project: FieldProject(), sourceID: "file:///excess", label: "excess") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMIncidentSearch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.nmfieldproject")
        let bad = directory.appendingPathComponent("bad.nmfieldproject")
        let oversized = directory.appendingPathComponent("oversized.nmfieldproject")
        let original = try project.encoded()
        try original.write(to: good)
        try Data("invalid".utf8).write(to: bad)
        try Data(repeating: 32, count: FieldProject.fileSizeLimit + 1).write(to: oversized)
        let reads = FieldIncidentFileLoader.read([good, bad, oversized])
        try check(reads[0].project == project && reads[1].error != nil && reads[2].error != nil && reads[2].project == nil,
                  "Selected-file reading isolates damaged and oversized files")
        try check(try Data(contentsOf: good) == original, "Read-only search leaves source documents unchanged")
    }

    private static func rejects(_ work: () throws -> Void) throws {
        do { try work() }
        catch { return }
        throw CheckFailure(description: "Invalid incident search input must be rejected")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(description: message) }
    }
}
