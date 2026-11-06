import Foundation

public struct NetworkInterfaceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public let family: String
    public let netmask: String
    public let isUp: Bool
    public let isLoopback: Bool

    public init(id: String = UUID().uuidString, name: String, address: String,
                family: String, netmask: String, isUp: Bool, isLoopback: Bool) {
        self.id = id
        self.name = name
        self.address = address
        self.family = family
        self.netmask = netmask
        self.isUp = isUp
        self.isLoopback = isLoopback
    }
}

/// Enumerates interfaces through getifaddrs, avoiding a dependency on
/// platform-specific command output. It is safe to call from a background task.
public enum NetworkInterfaces {
    public static func list(includeLoopback: Bool = false) -> [NetworkInterfaceInfo] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var result: [NetworkInterfaceInfo] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let item = node.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: item.ifa_name)
            let flags = item.ifa_flags
            let loopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if loopback && !includeLoopback { continue }
            let addressText = numericAddress(address)
            let maskText = item.ifa_netmask.map(numericAddress) ?? ""
            guard !addressText.isEmpty else { continue }
            result.append(NetworkInterfaceInfo(
                name: name,
                address: addressText,
                family: family == UInt8(AF_INET) ? "IPv4" : "IPv6",
                netmask: maskText,
                isUp: (flags & UInt32(IFF_UP)) != 0,
                isLoopback: loopback
            ))
        }
        return result.sorted { ($0.name, $0.family, $0.address) < ($1.name, $1.family, $1.address) }
    }

    private static func numericAddress(_ pointer: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t = pointer.pointee.sa_family == sa_family_t(AF_INET)
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = getnameinfo(pointer, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? String(cString: host) : ""
    }
}

