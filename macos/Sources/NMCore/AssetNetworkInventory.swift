import Darwin
import Foundation

/// Configured source data, not an observation of this Mac's routes or link state.
public enum AssetRoutingDomain: Codable, Hashable, Sendable {
    case unknown
    case global
    case vrf(identity: ExternalAssetIdentity, name: String)

    public var title: String {
        switch self {
        case .unknown: return t("Routing domain not recorded")
        case .global: return t("Global routing table")
        case let .vrf(_, name): return "VRF · \(name)"
        }
    }

    fileprivate func isValid(instance: String) -> Bool {
        switch self {
        case .unknown, .global: return true
        case let .vrf(identity, name):
            return identity.isValid && identity.instance == instance && identity.objectType == "ipam.vrf" && name.count <= 200
        }
    }
}

public struct AssetIPAddress: Codable, Hashable, Sendable {
    public enum Family: String, Codable, Sendable { case ipv4, ipv6 }
    public var identity: ExternalAssetIdentity?
    public var cidr: String
    public var interfaceIdentity: ExternalAssetIdentity?
    public var routingDomain: AssetRoutingDomain
    public var isPrimary: Bool

    public init(identity: ExternalAssetIdentity? = nil, cidr: String,
                interfaceIdentity: ExternalAssetIdentity? = nil,
                routingDomain: AssetRoutingDomain = .unknown, isPrimary: Bool = false) {
        self.identity = identity
        self.cidr = cidr
        self.interfaceIdentity = interfaceIdentity
        self.routingDomain = routingDomain
        self.isPrimary = isPrimary
    }

    public var host: String { String(cidr.split(separator: "/", maxSplits: 1).first ?? "") }
    public var family: Family? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return .ipv4 }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return .ipv6 }
        return nil
    }

    public var isValid: Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), let family else { return false }
        return (0...(family == .ipv4 ? 32 : 128)).contains(prefix) && cidr.count <= 100 &&
            identity?.isValid != false && interfaceIdentity?.isValid != false
    }
}

public struct AssetCableEndpoint: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case interface = "dcim.interface"
        case frontPort = "dcim.frontport"
        case rearPort = "dcim.rearport"
    }

    public let kind: Kind
    public let deviceID: Int
    public let deviceName: String
    public let portID: Int
    public let portName: String
    public var id: String { "\(kind.rawValue):\(portID)" }

    public init(kind: Kind, deviceID: Int, deviceName: String, portID: Int, portName: String) {
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.portID = portID
        self.portName = portName
    }
}

public enum AssetConfiguredCable: Codable, Hashable, Sendable {
    public static let maximumPeers = 64

    case unassigned
    case assigned(id: Int, peers: [AssetCableEndpoint]?)

    fileprivate var isValid: Bool {
        guard case let .assigned(id, peers) = self else { return true }
        guard id > 0 else { return false }
        guard let peers else { return true }
        return peers.count <= Self.maximumPeers && Set(peers.map(\.id)).count == peers.count && peers.allSatisfy {
            $0.deviceID > 0 && $0.portID > 0 && !$0.portName.isEmpty && $0.portName.count <= 200 &&
                !$0.deviceName.isEmpty && $0.deviceName.count <= 200
        }
    }
}

public struct AssetNetworkInterface: Codable, Hashable, Identifiable, Sendable {
    public var identity: ExternalAssetIdentity
    public var name: String
    public var enabled: Bool?
    public var mtu: Int?
    public var macAddress: String?
    public var routingDomain: AssetRoutingDomain
    public var configuredCable: AssetConfiguredCable?
    public var id: ExternalAssetIdentity { identity }

    public init(identity: ExternalAssetIdentity, name: String, enabled: Bool? = nil,
                mtu: Int? = nil, macAddress: String? = nil, routingDomain: AssetRoutingDomain = .unknown,
                configuredCable: AssetConfiguredCable? = nil) {
        self.identity = identity
        self.name = name
        self.enabled = enabled
        self.mtu = mtu
        self.macAddress = macAddress
        self.routingDomain = routingDomain
        self.configuredCable = configuredCable
    }
}

/// An explicitly fetched, independently dated snapshot. Basic device refreshes
/// retain this value and its original timestamp rather than claiming it was re-read.
public struct AssetNetworkInventory: Codable, Hashable, Sendable {
    public static let maximumInterfaces = 512
    public static let maximumAddresses = 2048
    public var deviceIdentity: ExternalAssetIdentity
    public var fetchedAt: Date
    public var interfaces: [AssetNetworkInterface]
    public var addresses: [AssetIPAddress]

    public init(deviceIdentity: ExternalAssetIdentity, fetchedAt: Date,
                interfaces: [AssetNetworkInterface], addresses: [AssetIPAddress]) {
        self.deviceIdentity = deviceIdentity
        self.fetchedAt = fetchedAt
        self.interfaces = interfaces
        self.addresses = addresses
    }

    public var isValid: Bool {
        let instance = deviceIdentity.instance
        let interfaceIDs = Set(interfaces.map(\.identity))
        let addressIDs = addresses.compactMap(\.identity)
        guard deviceIdentity.isValid, deviceIdentity.objectType == "dcim.device",
              fetchedAt.timeIntervalSinceReferenceDate.isFinite,
              interfaces.count <= Self.maximumInterfaces, addresses.count <= Self.maximumAddresses,
              interfaceIDs.count == interfaces.count, Set(addressIDs).count == addresses.count else { return false }
        return interfaces.allSatisfy { interface in
            interface.identity.isValid && interface.identity.instance == instance &&
                interface.identity.objectType == "dcim.interface" && !interface.name.isEmpty && interface.name.count <= 200 &&
                interface.mtu.map { (1...1_000_000).contains($0) } != false &&
                (interface.macAddress?.count ?? 0) <= 100 && interface.routingDomain.isValid(instance: instance) &&
                interface.configuredCable?.isValid != false
        } && addresses.allSatisfy { address in
            address.isValid && address.identity?.instance == instance && address.identity?.objectType == "ipam.ipaddress" &&
                address.interfaceIdentity.map(interfaceIDs.contains) == true && address.routingDomain.isValid(instance: instance)
        }
    }
}
