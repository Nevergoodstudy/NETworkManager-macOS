import Foundation
import NMCore

struct NetBoxInterfaceRecord: Codable, Sendable {
    let id: Int
    let name: String
    let device: NetBoxReference
    let enabled: Bool?
    let mtu: Int?
    let macAddress: String?
    let vrf: NetBoxReference?
    let includesVRF: Bool
    private let cable: NetBoxReference?
    private let includesCable: Bool
    private let linkPeers: [NetBoxCableEndpoint]?
    private let linkPeersType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, device, enabled, mtu, macAddress = "mac_address", vrf, cable
        case linkPeers = "link_peers", linkPeersType = "link_peers_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        device = try c.decode(NetBoxReference.self, forKey: .device)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        vrf = try c.decodeIfPresent(NetBoxReference.self, forKey: .vrf)
        includesVRF = c.contains(.vrf)
        includesCable = c.contains(.cable)
        cable = try c.decodeIfPresent(NetBoxReference.self, forKey: .cable)
        linkPeersType = try c.decodeIfPresent(String.self, forKey: .linkPeersType)
        linkPeers = cable == nil ? nil : try c.decodeIfPresent([NetBoxCableEndpoint].self, forKey: .linkPeers)
    }

    var configuredCable: AssetConfiguredCable? {
        guard includesCable else { return nil }
        guard let cable else { return .unassigned }
        guard let cableID = cable.id else { return nil }
        guard let linkPeers else { return .assigned(id: cableID, peers: nil) }
        if linkPeers.isEmpty { return .assigned(id: cableID, peers: []) }
        guard let kind = linkPeersType.flatMap(AssetCableEndpoint.Kind.init(rawValue:)),
              linkPeers.count <= AssetConfiguredCable.maximumPeers else { return .assigned(id: cableID, peers: nil) }
        let endpoints = linkPeers.compactMap { endpoint -> AssetCableEndpoint? in
            guard let device = endpoint.device, let deviceID = device.id else { return nil }
            return AssetCableEndpoint(kind: kind, deviceID: deviceID, deviceName: device.label,
                                      portID: endpoint.id, portName: endpoint.name ?? String(endpoint.id))
        }
        return .assigned(id: cableID, peers: endpoints.count == linkPeers.count ? endpoints : nil)
    }

    private struct NetBoxCableEndpoint: Codable, Sendable {
        let id: Int
        let name: String?
        let device: NetBoxReference?
    }
}

struct NetBoxIPAddressRecord: Codable, Sendable {
    let id: Int
    let address: String
    let assignedObjectType: String?
    let assignedObjectID: Int?
    let vrf: NetBoxReference?
    let includesVRF: Bool

    enum CodingKeys: String, CodingKey {
        case id, address, assignedObjectType = "assigned_object_type", assignedObjectID = "assigned_object_id", vrf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        address = try c.decode(String.self, forKey: .address)
        assignedObjectType = try c.decodeIfPresent(String.self, forKey: .assignedObjectType)
        assignedObjectID = try c.decodeIfPresent(Int.self, forKey: .assignedObjectID)
        vrf = try c.decodeIfPresent(NetBoxReference.self, forKey: .vrf)
        includesVRF = c.contains(.vrf)
    }
}

extension NetBoxClient {
    /// Read just one device on explicit user request. This does not import or probe it.
    public func fetchNetworkInventory(for device: NetBoxDeviceRecord, maxPages: Int = 10) async throws -> AssetNetworkInventory {
        try await withThrowingTaskGroup(of: AssetNetworkInventory.self) { group in
            group.addTask { try await self.readNetworkInventory(for: device, maxPages: maxPages) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw NetBoxError.invalidResponse }
            return result
        }
    }

    private func readNetworkInventory(for device: NetBoxDeviceRecord, maxPages: Int) async throws -> AssetNetworkInventory {
        guard device.id > 0 else { throw NetBoxError.invalidResponse }
        let query = [URLQueryItem(name: "device_id", value: String(device.id))]
        let interfaces: ([NetBoxInterfaceRecord], pages: Int) = try await fetchPages(
            path: "api/dcim/interfaces/", query: query, maxPages: maxPages, recordLimit: AssetNetworkInventory.maximumInterfaces)
        try Task.checkCancellation()
        let addresses: ([NetBoxIPAddressRecord], pages: Int) = try await fetchPages(
            path: "api/ipam/ip-addresses/", query: query, maxPages: maxPages, recordLimit: AssetNetworkInventory.maximumAddresses)
        return try NetBoxNetworkInventoryMapper.map(device: device, interfaces: interfaces.0, addresses: addresses.0,
                                                   source: configuration.sourceInstance, fetchedAt: Date())
    }
}

enum NetBoxNetworkInventoryMapper {
    static func map(device: NetBoxDeviceRecord, interfaces: [NetBoxInterfaceRecord], addresses: [NetBoxIPAddressRecord],
                    source: String, fetchedAt: Date) throws -> AssetNetworkInventory {
        func identity(_ type: String, _ id: Int) -> ExternalAssetIdentity {
            ExternalAssetIdentity(instance: source, objectType: type, remoteID: String(id))
        }
        func domain(_ vrf: NetBoxReference?, included: Bool) throws -> AssetRoutingDomain {
            guard included else { return .unknown }
            guard let vrf else { return .global }
            guard let id = vrf.id, id > 0 else { throw NetBoxError.invalidResponse }
            return .vrf(identity: identity("ipam.vrf", id), name: vrf.label)
        }
        guard interfaces.count <= AssetNetworkInventory.maximumInterfaces,
              addresses.count <= AssetNetworkInventory.maximumAddresses,
              interfaces.allSatisfy({ $0.id > 0 && $0.device.id == device.id }) else { throw NetBoxError.invalidResponse }
        let mappedInterfaces = try interfaces.map { record in
            AssetNetworkInterface(identity: identity("dcim.interface", record.id), name: record.name,
                                  enabled: record.enabled, mtu: record.mtu, macAddress: record.macAddress,
                                  routingDomain: try domain(record.vrf, included: record.includesVRF),
                                  configuredCable: record.configuredCable)
        }
        let interfaceIDs = Set(interfaces.map(\.id))
        let primaryIDs = Set([device.primaryIP4?.id, device.primaryIP6?.id].compactMap { $0 })
        let mappedAddresses = try addresses.compactMap { record -> AssetIPAddress? in
            // A numeric ID alone is not a relation: VM/FHRP IDs can collide.
            guard record.assignedObjectType == "dcim.interface",
                  let interfaceID = record.assignedObjectID, interfaceIDs.contains(interfaceID) else { return nil }
            guard record.id > 0 else { throw NetBoxError.invalidResponse }
            return AssetIPAddress(identity: identity("ipam.ipaddress", record.id), cidr: record.address,
                                  interfaceIdentity: identity("dcim.interface", interfaceID),
                                  routingDomain: try domain(record.vrf, included: record.includesVRF),
                                  isPrimary: primaryIDs.contains(record.id))
        }
        let result = AssetNetworkInventory(deviceIdentity: identity("dcim.device", device.id), fetchedAt: fetchedAt,
                                           interfaces: mappedInterfaces, addresses: mappedAddresses)
        guard result.isValid else { throw NetBoxError.invalidResponse }
        return result
    }
}
