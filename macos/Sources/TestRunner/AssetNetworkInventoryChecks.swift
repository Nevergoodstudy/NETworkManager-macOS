import Foundation
@testable import NMCore
@testable import NMIntegrations

enum AssetNetworkInventoryChecks {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let interfaceJSON = """
    [{"id":11,"name":"uplink","device":{"id":77},"enabled":true,"mtu":1500,"vrf":null,
      "cable":{"id":38},"link_peers_type":"dcim.interface",
      "link_peers":[{"id":21,"name":"eth0","device":{"id":78,"name":"Upstream"}}]},
     {"id":12,"name":"tenant","device":{"id":77},"vrf":{"id":9,"name":"Tenant"},"cable":{"id":39},
      "link_peers_type":"dcim.rearport","link_peers":[{"id":21,"name":"rear1","device":{"id":79,"name":"Patch"}},
      {"id":22,"name":"rear2","device":{"id":79,"name":"Patch"}}]},
     {"id":13,"name":"unknown-domain","device":{"id":77}},
     {"id":14,"name":"wireless","device":{"id":77},"cable":null,"link_peers":[{"id":43}]},
     {"id":15,"name":"incomplete","device":{"id":77},"cable":{"id":40},"link_peers":[]},
     {"id":16,"name":"unsupported","device":{"id":77},"cable":{"id":41},
      "link_peers_type":"circuits.circuittermination","link_peers":[{"id":81}]}]
    """
    private static let addressJSON = """
    [{"id":101,"address":"192.0.2.10/24","assigned_object_type":"dcim.interface","assigned_object_id":11,"vrf":null},
     {"id":102,"address":"2001:db8::10/64","assigned_object_type":"dcim.interface","assigned_object_id":11,"vrf":null},
     {"id":103,"address":"192.0.2.10/24","assigned_object_type":"dcim.interface","assigned_object_id":12,"vrf":{"id":9,"name":"Tenant"}},
     {"id":104,"address":"192.0.2.10/24","assigned_object_type":"virtualization.vminterface","assigned_object_id":11,"vrf":null}]
    """
    private static var record: NetBoxDeviceRecord {
        NetBoxDeviceRecord(id: 77, name: "Synthetic router",
                          primaryIP4: NetBoxReference(id: 101, display: "Display label", address: "192.0.2.10/24"),
                          primaryIP6: NetBoxReference(id: 102, address: "2001:db8::10/64"))
    }

    static func run() async throws {
        let source = "https://netbox.example/ops"
        let interfaces = try JSONDecoder().decode([NetBoxInterfaceRecord].self, from: Data(interfaceJSON.utf8))
        let addresses = try JSONDecoder().decode([NetBoxIPAddressRecord].self, from: Data(addressJSON.utf8))
        let inventory = try NetBoxNetworkInventoryMapper.map(device: record, interfaces: interfaces, addresses: addresses,
                                                            source: source, fetchedAt: now)
        try check(inventory.isValid && inventory.interfaces.count == 6 && inventory.addresses.count == 3,
                  "Device inventory keeps actual interface assignments and excludes colliding VM object IDs")
        let uplink = AssetCableEndpoint(kind: .interface, deviceID: 78, deviceName: "Upstream", portID: 21, portName: "eth0")
        let panel = [
            AssetCableEndpoint(kind: .rearPort, deviceID: 79, deviceName: "Patch", portID: 21, portName: "rear1"),
            AssetCableEndpoint(kind: .rearPort, deviceID: 79, deviceName: "Patch", portID: 22, portName: "rear2"),
        ]
        try check(inventory.interfaces.map(\.configuredCable) == [
            .assigned(id: 38, peers: [uplink]), .assigned(id: 39, peers: panel), nil,
            .unassigned, .assigned(id: 40, peers: []), .assigned(id: 41, peers: nil),
        ], "NetBox cables retain endpoint kinds and distinguish old, uncabled, open and unsupported topology")
        try check(inventory.interfaces[0].routingDomain == .global && inventory.interfaces[2].routingDomain == .unknown,
                  "Explicit null VRF means global while an omitted field remains unknown")
        try check(inventory.addresses[0].cidr == inventory.addresses[2].cidr &&
                  inventory.addresses[0].routingDomain != inventory.addresses[2].routingDomain,
                  "Duplicate IPs in different routing domains remain independent records")
        try check(inventory.addresses[1].host == "2001:db8::10" && inventory.addresses[1].family == .ipv6,
                  "IPv6 host bits are preserved rather than converted to a network prefix")
        let mapped = NetBoxAssetMapper.snapshot(from: record, source: source, fetchedAt: now, networkInventory: inventory)!
        try check(mapped.sourcePrimaryAddresses?.count == 2 && mapped.address == "192.0.2.10" &&
                  mapped.sourcePrimaryAddresses?[1].cidr == "2001:db8::10/64", "Both source primary address families are retained")
        try check(!AssetIPAddress(cidr: "192.0.2.1/33").isValid && !AssetIPAddress(cidr: "2001:db8::1/129").isValid,
                  "CIDR validation rejects invalid family prefixes")
        var invalid = inventory
        invalid.addresses[0].interfaceIdentity = ExternalAssetIdentity(instance: source, objectType: "dcim.interface", remoteID: "999")
        try check(!invalid.isValid, "Dangling interface references are invalid")
        invalid = inventory
        invalid.addresses.append(invalid.addresses[0])
        try check(!invalid.isValid, "Duplicate address object identities are invalid")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NMNetworkInventory-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("assets.sqlite")
        let store = AssetStore(storageURL: url)
        store.mergeExternalAssets([mapped])
        let deviceID = store.devices.first(where: { $0.externalIdentity == mapped.externalIdentity })!.id
        var basic = mapped
        basic.networkInventory = nil
        basic.fetchedAt = now.addingTimeInterval(10)
        store.mergeExternalAssets([basic])
        try check(store.devices.first(where: { $0.id == deviceID })?.networkInventory == inventory, "Basic refresh retains inventory and its original timestamp")
        var expanded = basic
        var newer = inventory
        newer.fetchedAt = now.addingTimeInterval(20)
        newer.addresses.removeLast()
        newer.interfaces[0].configuredCable = .unassigned
        expanded.networkInventory = newer
        store.mergeExternalAssets([expanded])
        try check(store.devices.first(where: { $0.id == deviceID })?.networkInventory == newer, "Same device preview date can import a newer independent inventory")
        store.mergeExternalAssets([mapped])
        let reloaded = AssetStore(storageURL: url)
        try check(reloaded.devices.contains(where: { $0.id == deviceID && $0.networkInventory == newer }) &&
                  reloaded.persistenceError == nil && reloaded.recoveryError == nil,
                  "SQLite reopen retains dual-stack inventory and cable removal, and rejects rollback by older snapshots")
        var corrupt = mapped
        corrupt.networkInventory = invalid
        let before = store.devices
        store.mergeExternalAssets([corrupt])
        try check(store.devices == before, "Invalid expanded inventory cannot partially update local assets")
        try await loopbackChecks()
    }

    static func libreNMSLinks() async throws {
        let links = """
        {"status":"ok","count":2,"links":[
          {"id":1,"local_device_id":77,"local_port_id":100,"remote_device_id":78,"remote_port_id":200,
           "remote_hostname":"Changed peer","remote_port":"eth0","protocol":"lldp","active":1},
          {"id":2,"local_device_id":77,"local_port_id":101,"remote_device_id":79,"remote_port_id":201,"active":0}
        ]}
        """
        let fixture = try NetBoxFixtureServer { request, _ in
            switch request.path {
            case "/ops/api/v0/devices/77/links": return NetBoxFixtureResponse(body: links)
            case "/ops/api/v0/devices/77/ports":
                return NetBoxFixtureResponse(body: """
                {"status":"ok","count":2,"ports":[{"port_id":"100","ifName":"uplink"},{"port_id":101,"ifName":"reflected-fixture-token"}]}
                """)
            case "/ops/api/v0/devices/78/links":
                return NetBoxFixtureResponse(status: 404, body: #"{"status":"error","message":"Links do not exist"}"#)
            case "/ops/api/v0/devices/79/links":
                return NetBoxFixtureResponse(status: 404, body: #"{"status":"error","message":"Device 79 not found"}"#)
            default: return NetBoxFixtureResponse(status: 403, body: "{}")
            }
        }
        defer { fixture.stop() }
        let source = "https://netbox.example/ops"
        let interfaces = try JSONDecoder().decode([NetBoxInterfaceRecord].self, from: Data(interfaceJSON.utf8))
        let inventory = try NetBoxNetworkInventoryMapper.map(device: record, interfaces: interfaces, addresses: [],
                                                            source: source, fetchedAt: now)
        let snapshot = try await LibreNMS.readLinks(baseURL: fixture.baseURL.absoluteString, deviceID: 77, token: "fixture-token")
        try check(snapshot.links.map(\.localPort) == ["uplink", nil] &&
                  snapshot.links.first?.conflicts(with: inventory) == true &&
                  snapshot.links.last?.conflicts(with: inventory) == false &&
                  snapshot.links.last?.remoteLabel == "#79 / #201", "Only comparable, active endpoints can have a conflict")
        let encoded = try JSONEncoder().encode(snapshot)
        try check(!String(decoding: encoded, as: UTF8.self).contains("fixture-token"),
                  "A reflected token is omitted before the snapshot can be saved")
        try check(!snapshot.isStale(at: snapshot.fetchedAt.addingTimeInterval(86_399)) &&
                  snapshot.isStale(at: snapshot.fetchedAt.addingTimeInterval(86_400)),
                  "Staleness is based on the LibreNMS read time")
        try check(fixture.requests.count == 2 && fixture.requests.allSatisfy {
            $0.method == "GET" && $0.headers["x-auth-token"] == "fixture-token"
        }, "Links and port names are read using device-scoped GETs")

        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assets.sqlite")
        let store = AssetStore(storageURL: url)
        let mapped = NetBoxAssetMapper.snapshot(from: record, source: source, fetchedAt: now, networkInventory: inventory)!
        store.mergeExternalAssets([mapped])
        guard let deviceID = store.devices.first(where: { $0.externalIdentity == mapped.externalIdentity })?.id else {
            throw CheckFailure(description: "NetBox fixture device was not imported")
        }
        try check(store.applyLibreNMSLinks(snapshot, to: deviceID), "Persist a LibreNMS snapshot for the selected asset")
        store.mergeExternalAssets([mapped])
        let reopened = AssetStore(storageURL: url)
        let device = reopened.devices.first { $0.id == deviceID }
        try check(device?.networkInventory == inventory && device?.libreNMSLinks == snapshot,
                  "Reopen retains both sources and a NetBox refresh preserves the observed links")

        for (id, message) in [(78, t("LibreNMS returned no visible links for this device.")),
                              (79, tf("LibreNMS returned HTTP %d.", 404))] {
            do {
                let unavailable = try await LibreNMS.readLinks(baseURL: fixture.baseURL.absoluteString,
                                                               deviceID: id, token: "fixture-token")
                store.applyLibreNMSLinks(unavailable, to: deviceID)
                throw CheckFailure(description: "A 404 refreshed the saved link snapshot")
            } catch {
                try check(error.localizedDescription == message, "No visible links and an unknown device have different outcomes")
            }
        }
        try check(store.devices.first(where: { $0.id == deviceID })?.libreNMSLinks == snapshot,
                  "An unavailable response preserves the original snapshot and timestamp")
    }

    private static func loopbackChecks() async throws {
        let interfaces = interfaceJSON
        let addresses = addressJSON
        let server = try NetBoxFixtureServer { request, _ in
            let body: String
            if request.path.hasSuffix("dcim/interfaces") { body = interfaces }
            else if request.path.hasSuffix("ipam/ip-addresses") { body = addresses }
            else { return NetBoxFixtureResponse(status: 404, body: "{}") }
            return NetBoxFixtureResponse(body: "{\"count\":3,\"next\":null,\"previous\":null,\"results\":\(body)}")
        }
        defer { server.stop() }
        let client = NetBoxClient(configuration: NetBoxConfiguration(baseURL: server.baseURL), token: "fixture-token")
        let inventory = try await client.fetchNetworkInventory(for: record)
        try check(inventory.addresses.count == 3 && inventory.interfaces[0].configuredCable != nil &&
                  server.requests.count == 2 && server.requests.allSatisfy {
            $0.method == "GET" && $0.target.contains("device_id=77") && $0.headers["authorization"] == "Token fixture-token"
        }, "Explicit inventory reads use scoped GETs and the existing read-only authorization path")
        let denied = try NetBoxFixtureServer { request, _ in
            if request.path.hasSuffix("dcim/interfaces") {
                return NetBoxFixtureResponse(body: "{\"count\":3,\"next\":null,\"previous\":null,\"results\":\(interfaces)}")
            }
            return NetBoxFixtureResponse(status: 403, body: "{\"detail\":\"Not permitted\"}")
        }
        defer { denied.stop() }
        do {
            _ = try await NetBoxClient(configuration: NetBoxConfiguration(baseURL: denied.baseURL), token: "fixture-token")
                .fetchNetworkInventory(for: record)
            throw CheckFailure(description: "Partial inventory must not be returned after an IP permission failure")
        } catch NetBoxError.httpStatus(403, _) {}
    }

    @MainActor
    static func refreshIdentityOverHTTP() async throws {
        let server = try NetBoxFixtureServer { request, _ in
            guard request.method == "GET" else { return NetBoxFixtureResponse(status: 405, body: "{}") }
            let firstRead = request.headers["authorization"] == "Token old-fixture-token"
            guard firstRead || request.headers["authorization"] == "Token new-fixture-token" else {
                return NetBoxFixtureResponse(status: 403, body: "{}")
            }
            switch request.path {
            case "/ops/api/dcim/devices":
                let primary = firstRead ? "\"primary_ip4\":{\"id\":101,\"address\":\"192.0.2.10/24\"}" :
                    "\"primary_ip6\":{\"id\":102,\"address\":\"2001:db8::10/64\"}"
                return NetBoxFixtureResponse(body: """
                {"count":1,"next":null,"results":[{"id":77,"name":"Edge-77","site":{"id":1,"name":"Lab"},\(primary)}]}
                """)
            case "/ops/api/dcim/sites":
                return NetBoxFixtureResponse(body: "{\"count\":1,\"next\":null,\"results\":[{\"id\":1,\"name\":\"Lab\"}]}")
            default:
                return NetBoxFixtureResponse(status: 404, body: "{}")
            }
        }
        defer { server.stop() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMNetBoxIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assets.sqlite")
        let store = AssetStore(storageURL: url)
        let initial = NetBoxClient(configuration: .init(baseURL: server.baseURL, tokenReference: "old-reference"), token: "old-fixture-token")
        let first = NetBoxAssetMapper.snapshots(from: try await initial.sync())
        try check(store.mergeExternalAssets(first) == 1, "The first NetBox sync adds one stable device")
        guard var device = store.devices.first(where: { $0.externalIdentity?.remoteID == "77" }) else {
            throw CheckFailure(description: "The NetBox device was persisted with its remote ID")
        }
        device.notes = "Local maintenance note"
        store.upsert(device)
        let runID = store.beginDiagnostic(deviceID: device.id, kind: .tcp, target: device.address)
        store.finishDiagnostic(id: runID, status: .failed, summary: "Historical observation")

        let rotated = NetBoxClient(configuration: .init(baseURL: server.baseURL, tokenReference: "new-reference"), token: "new-fixture-token")
        let refreshed = NetBoxAssetMapper.snapshots(from: try await rotated.sync())
        try check(refreshed.count == 1 && refreshed.first?.externalIdentity == device.externalIdentity &&
                  store.mergeExternalAssets(refreshed) == 0,
                  "The HTTP sync refreshes the same remote ID after an address and credential change")

        let reopened = AssetStore(storageURL: url)
        let matching = reopened.devices.filter { $0.externalIdentity == device.externalIdentity }
        try check(matching.count == 1 && matching.first?.id == device.id && matching.first?.address == "2001:db8::10" &&
                  matching.first?.notes == device.notes, "SQLite preserves the local UUID and notes and reopens the new IPv6 address")
        let history = try reopened.diagnosticPage(DiagnosticPageQuery(scope: .device(device.id)))
        try check(history.count == 1 && history.first?.id == runID && history.first?.target == "192.0.2.10",
                  "The linked history reopens with its original IPv4 observation target")
    }
}
