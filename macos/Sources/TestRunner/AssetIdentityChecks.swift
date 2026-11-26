import Foundation
@testable import NMCore
import NMIntegrations

/// Synthetic records only: no Keychain access, remote requests or probes.
enum AssetIdentityChecks {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NMAssetIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try mappingChecks()
        try refreshChecks(in: directory)
        try validationChecks()
        try legacyChecks(in: directory)
    }

    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    private static func identity(_ id: String = "77", instance: String = "https://netbox.example/ops",
                                 type: String = "dcim.device") -> ExternalAssetIdentity {
        ExternalAssetIdentity(instance: instance, objectType: type, remoteID: id)
    }

    private static func snapshot(_ id: ExternalAssetIdentity? = identity(), address: String = "192.0.2.10",
                                 offset: TimeInterval = 0, site: String = "Lab") -> ExternalAssetSnapshot {
        ExternalAssetSnapshot(source: "https://netbox.example/ops", fetchedAt: date.addingTimeInterval(offset),
                              siteName: site, deviceName: "Source name", address: address,
                              externalIdentity: id)
    }

    private static func mappingChecks() throws {
        let first = NetBoxConfiguration(baseURL: URL(string: "https://NETBOX.example:443/ops/")!, tokenReference: "old-key")
        let rotated = NetBoxConfiguration(baseURL: URL(string: "https://netbox.example/ops")!, tokenReference: "new-key")
        try check(first.sourceInstance == rotated.sourceInstance, "Instance identity survives credential rotation and URL spelling")
        let record = NetBoxDeviceRecord(id: 77, name: "edge", primaryIP4: NetBoxReference(display: "192.0.2.10/24"))
        let mapped = NetBoxAssetMapper.snapshot(from: record, source: first.sourceInstance, fetchedAt: date)
        try check(mapped?.externalIdentity == identity() && mapped?.address == "192.0.2.10",
                  "NetBox mapper retains the device primary key with its instance and object type")
        let result = NetBoxSyncResult(devices: [record], sites: [], fetchedAt: date, devicePages: 1,
                                     sitePages: 1, source: rotated.sourceInstance)
        try check(NetBoxAssetMapper.snapshots(from: result).first?.externalIdentity == mapped?.externalIdentity,
                  "Single and bulk NetBox mappings use the same stable identity")
        let decoded = try JSONDecoder().decode(ExternalAssetIdentity.self, from: Data("""
        {"instance":"https://user:secret@NETBOX.example:443/ops/?token=secret#fragment","objectType":" dcim.device ","remoteID":"77"}
        """.utf8))
        try check(decoded == identity(), "Decoded identities normalize URLs and omit credential fields")
    }

    private static func refreshChecks(in directory: URL) throws {
        let url = directory.appendingPathComponent("assets.sqlite")
        let store = AssetStore(storageURL: url)
        try check(store.mergeExternalAssets([snapshot()]) == 1, "First stable device import adds one record")
        guard var device = store.devices.first(where: { $0.externalIdentity == identity() }) else {
            throw CheckFailure(description: "Stable import must produce a local device")
        }
        device.name = "Local alias"
        device.notes = "Engineer notes"
        device.credentialRefID = UUID()
        store.upsert(device)
        let editedAt = store.devices.first(where: { $0.id == device.id })!.updatedAt
        let runID = store.beginDiagnostic(deviceID: device.id, kind: .tcp, target: device.address)
        store.finishDiagnostic(id: runID, status: .succeeded, summary: "Synthetic history")
        let moved = snapshot(address: "2001:db8::10", offset: 10, site: "Renamed upstream site")
        try check(store.containsExternalAsset(moved), "Preview recognizes a remote object after IP and site label change")
        try check(store.mergeExternalAssets([moved]) == 0, "IP change refreshes rather than duplicating the device")
        guard var refreshed = store.devices.first(where: { $0.id == device.id }) else {
            throw CheckFailure(description: "Refresh must retain the local UUID")
        }
        try check(refreshed.address == moved.address && refreshed.sourceAddress == moved.address,
                  "An unmodified source address follows upstream changes across address families")
        try check(refreshed.name == device.name && refreshed.notes == device.notes &&
                  refreshed.credentialRefID == device.credentialRefID && refreshed.updatedAt == editedAt &&
                  refreshed.siteID == device.siteID,
                  "Refresh preserves local metadata, site association and user edit time")
        store.mergeExternalAssets([snapshot(address: "192.0.2.99", offset: 5)])
        store.mergeExternalAssets([snapshot(address: "192.0.2.98", offset: 10)])
        try check(store.devices.first(where: { $0.id == device.id })?.address == moved.address,
                  "Out-of-order and same-time snapshots cannot roll the source address back")
        refreshed.address = "192.0.2.55"
        store.upsert(refreshed)
        store.mergeExternalAssets([snapshot(address: "2001:db8::20", offset: 20)])
        let overridden = store.devices.first(where: { $0.id == device.id })
        try check(overridden?.address == "192.0.2.55" && overridden?.sourceAddress == "2001:db8::20",
                  "Manual address overrides survive while source address freshness advances")

        let sameIP = "192.0.2.55"
        let additional = [snapshot(identity("78"), address: sameIP),
                          snapshot(identity(instance: "https://other.example/ops"), address: sameIP),
                          snapshot(identity(instance: "https://netbox.example/other"), address: sameIP),
                          snapshot(identity(type: "virtualization.virtualmachine"), address: sameIP)]
        try check(store.mergeExternalAssets(additional) == additional.count,
                  "Same IP does not merge different remote IDs, instances, base paths or object types")
        let reloaded = AssetStore(storageURL: url)
        let persisted = reloaded.devices.first(where: { $0.id == device.id })
        try check(reloaded.recoveryError == nil && reloaded.persistenceError == nil && store.persistenceError == nil,
                  "Stable asset snapshots pass the SQLite repository validation")
        try check(persisted?.externalIdentity == identity() && persisted?.address == "192.0.2.55" &&
                  persisted?.sourceAddress == "2001:db8::20", "SQLite reopen retains identity and the separate source address")
        let page = try reloaded.diagnosticPage(DiagnosticPageQuery(scope: .device(device.id)))
        try check(page.count == 1 && page[0].id == runID && page[0].target == "192.0.2.10",
                  "IP refresh preserves historical device linkage and the original observation target")
    }

    private static func validationChecks() throws {
        let workspace = OperationsWorkspace()
        let site = AssetSite(workspaceID: workspace.id, name: "One")
        let otherSite = AssetSite(workspaceID: workspace.id, name: "Two")
        let device = AssetDevice(siteID: site.id, name: "One", address: "192.0.2.1", externalIdentity: identity())
        let duplicate = AssetDevice(siteID: otherSite.id, name: "Two", address: "192.0.2.2", externalIdentity: identity())
        var value = AssetSnapshot(workspaces: [workspace], sites: [site, otherSite], devices: [device, duplicate])
        do {
            try value.validate()
            throw CheckFailure(description: "A duplicate identity in one workspace must be rejected")
        } catch AssetRepositoryError.invalidRelationships {}
        let second = OperationsWorkspace()
        value.workspaces.append(second)
        value.sites[1].workspaceID = second.id
        try value.validate()
        value.devices[0].externalIdentity = identity("")
        do {
            try value.validate()
            throw CheckFailure(description: "An invalid remote identity must be rejected")
        } catch AssetRepositoryError.invalidRelationships {}
    }

    private static func legacyChecks(in directory: URL) throws {
        let store = AssetStore(storageURL: directory.appendingPathComponent("legacy.json"))
        let legacy = snapshot(nil)
        try check(store.mergeExternalAssets([legacy]) == 1, "Legacy source-site-address import remains available")
        var renamedLegacy = legacy
        renamedLegacy.deviceName = "Upstream rename"
        renamedLegacy.fetchedAt = date.addingTimeInterval(10)
        try check(store.containsExternalAsset(renamedLegacy) && store.mergeExternalAssets([renamedLegacy]) == 0,
                  "Legacy snapshots still refresh using their original identity")
        try check(store.mergeExternalAssets([snapshot()]) == 1,
                  "A legacy same-IP asset is never silently claimed by a new remote primary key")
        let legacyDevice = store.devices.first(where: { $0.source == legacy.source && $0.externalIdentity == nil })!
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(legacyDevice)) as! [String: Any]
        object.removeValue(forKey: "sourceFetchedAt")
        object.removeValue(forKey: "externalIdentity")
        object.removeValue(forKey: "sourceAddress")
        let decoded = try JSONDecoder().decode(AssetDevice.self, from: JSONSerialization.data(withJSONObject: object))
        try check(decoded.externalIdentity == nil && decoded.sourceAddress == nil && decoded.sourceFetchedAt == nil,
                  "Old saved devices decode without any new source metadata")
    }
}
