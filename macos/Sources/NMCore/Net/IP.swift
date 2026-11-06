import Foundation
import Darwin

// MARK: - IPv4

public struct IPv4: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        self.raw = value
    }

    public var octets: [UInt8] {
        [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
    }

    public var description: String {
        octets.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.raw < rhs.raw }

    public static func + (lhs: IPv4, rhs: Int) -> IPv4 { IPv4(raw: lhs.raw &+ UInt32(bitPattern: Int32(truncatingIfNeeded: rhs))) }

    public var isPrivate: Bool {
        let o = octets
        if o[0] == 10 { return true }
        if o[0] == 172, (16...31).contains(o[1]) { return true }
        if o[0] == 192, o[1] == 168 { return true }
        if o[0] == 127 { return true }
        if o[0] == 169, o[1] == 254 { return true }
        return false
    }
}

public struct IPv4Subnet: Hashable, CustomStringConvertible, Sendable {
    public let base: IPv4
    public let prefix: Int

    public init(base: IPv4, prefix: Int) {
        self.base = base
        self.prefix = min(32, max(0, prefix))
    }

    /// Parse `192.168.1.0/24` (prefix optional, defaults to /32).
    public init?(_ string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts.contains(where: { $0.isEmpty }) else { return nil }
        guard let addr = IPv4(String(parts[0])) else { return nil }
        if parts.count == 1 { self.init(base: addr, prefix: 32); return }
        guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        self.init(base: addr, prefix: prefix)
    }

    public var mask: UInt32 {
        prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
    }

    public var wildcard: UInt32 { ~mask }

    public var network: IPv4 { IPv4(raw: base.raw & mask) }

    public var broadcast: IPv4 { IPv4(raw: network.raw | wildcard) }

    public var firstHost: IPv4? {
        prefix >= 31 ? network : network + 1
    }

    public var lastHost: IPv4? {
        prefix >= 31 ? broadcast : broadcast + -1
    }

    public var usableHostCount: Int {
        switch prefix {
        case 32: return 1
        case 31: return 2
        default: return Int(pow(2, Double(32 - prefix))) - 2
        }
    }

    public var totalAddressCount: Int { Int(pow(2, Double(32 - prefix))) }

    public var maskDescription: String { IPv4(raw: mask).description }

    public var cidr: String { "\(network.description)/\(prefix)" }

    public var description: String { cidr }

    public func contains(_ ip: IPv4) -> Bool { ip.raw & mask == network.raw }

    /// Split into `2^bits` equally sized subnets.
    public func split(bits: Int) -> [IPv4Subnet] {
        let newPrefix = min(32, prefix + max(0, bits))
        let count = 1 << (newPrefix - prefix)
        guard count > 0, count <= 65_536 else { return [] }
        let step = UInt32(1) << UInt32(32 - newPrefix)
        return (0..<count).map { IPv4Subnet(base: IPv4(raw: network.raw &+ UInt32($0) &* step), prefix: newPrefix) }
    }

    public var ipClass: String {
        switch octetsFirst {
        case 0...127: return "A"
        case 128...191: return "B"
        case 192...223: return "C"
        case 224...239: return "D (Multicast)"
        default: return "E (Reserved)"
        }
    }

    private var octetsFirst: UInt8 { network.octets[0] }

    /// All host addresses (bounded to keep the UI responsive).
    public func hostList(limit: Int = 65_536) -> [IPv4] {
        guard let first = firstHost, let last = lastHost else { return [] }
        let count = Int(last.raw &- first.raw) + 1
        guard count > 0, count <= limit else { return [] }
        return (0..<count).map { IPv4(raw: first.raw &+ UInt32($0)) }
    }
}

// MARK: - IPv6

public struct IPv6Subnet: Hashable, CustomStringConvertible, Sendable {
    public let base: String
    public let prefix: Int

    public init?(_ string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts.contains(where: { $0.isEmpty }) else { return nil }

        let addressText = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in6_addr()
        guard addressText.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }

        let parsedPrefix = parts.count == 2 ? Int(parts[1]) : 128
        guard let parsedPrefix, (0...128).contains(parsedPrefix) else { return nil }

        var bytes = withUnsafeBytes(of: address) { Array($0.prefix(16)) }
        for index in bytes.indices {
            let remainingBits = parsedPrefix - index * 8
            if remainingBits >= 8 { continue }
            if remainingBits <= 0 {
                bytes[index] = 0
            } else {
                let mask = UInt8((0xFF << (8 - remainingBits)) & 0xFF)
                bytes[index] &= mask
            }
        }

        var networkAddress = in6_addr()
        withUnsafeMutableBytes(of: &networkAddress) { destination in
            for index in bytes.indices { destination[index] = bytes[index] }
        }
        var normalizedAddress = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let conversion = withUnsafePointer(to: &networkAddress) {
            inet_ntop(AF_INET6, $0, &normalizedAddress, socklen_t(normalizedAddress.count))
        }
        guard conversion != nil else { return nil }

        base = String(cString: normalizedAddress)
        prefix = parsedPrefix
    }

    public var description: String { "\(base)/\(prefix)" }

    public var isLinkLocal: Bool {
        base.lowercased().hasPrefix("fe80")
    }

    public var isUniqueLocal: Bool {
        let lower = base.lowercased()
        return lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}

// MARK: - Host ranges

public enum HostRangeError: LocalizedError {
    case empty
    case invalid(String)
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .empty: return t("Enter a host range, for example 192.168.1.0/24 or 192.168.1.1-192.168.1.50")
        case .invalid(let input): return tf("Invalid host range: %@", input)
        case .tooLarge(let count): return tf("The range contains %d addresses, which is too many (max 65536).", count)
        }
    }
}

public struct HostRangePreview: Sendable, Equatable {
    public let count: Int
    public let firstTarget: String
    public let lastTarget: String

    public init(count: Int, firstTarget: String, lastTarget: String) {
        self.count = count
        self.firstTarget = firstTarget
        self.lastTarget = lastTarget
    }
}

public enum HostRangeParser {
    public static let maximumHosts = 65_536
    public static let largeScanConfirmationThreshold = 256

    private enum Segment {
        case ipv4(first: UInt32, count: Int)
        case literal(String)

        var count: Int {
            switch self {
            case .ipv4(_, let count): return count
            case .literal: return 1
            }
        }

        var firstTarget: String { target(at: 0) }
        var lastTarget: String { target(at: count - 1) }

        func target(at index: Int) -> String {
            switch self {
            case .ipv4(let first, _): return IPv4(raw: first &+ UInt32(index)).description
            case .literal(let value): return value
            }
        }
    }

    /// Parse a NETworkManager style host range expression.
    ///
    /// Supported forms:
    ///  * `192.168.1.1`
    ///  * `192.168.1.0/24`
    ///  * `192.168.1.1-192.168.1.50`
    ///  * `192.168.1.*`
    ///  * `host-01.example.com - host-02.example.com` (fallback: literal list)
    ///  * comma / semicolon separated combinations
    public static func parse(_ input: String) throws -> [String] {
        let segments = try parseSegments(input)
        let count = segments.reduce(0) { $0 + $1.count }
        guard count <= maximumHosts else { throw HostRangeError.tooLarge(count) }

        var result: [String] = []
        result.reserveCapacity(count)
        for segment in segments {
            for index in 0..<segment.count {
                result.append(segment.target(at: index))
            }
        }
        return result
    }

    /// Evaluate a range without allocating one string per target.
    public static func preview(_ input: String) throws -> HostRangePreview {
        let segments = try parseSegments(input)
        let first = segments[0].firstTarget
        let last = segments[segments.count - 1].lastTarget
        return HostRangePreview(count: segments.reduce(0) { $0 + $1.count },
                                firstTarget: first, lastTarget: last)
    }

    private static func parseSegments(_ input: String) throws -> [Segment] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HostRangeError.empty }

        var segments: [Segment] = []

        for chunk in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let token = chunk.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }

            // CIDR
            if token.contains("/"), let subnet = IPv4Subnet(token) {
                guard let first = subnet.firstHost, let last = subnet.lastHost else {
                    throw HostRangeError.tooLarge(subnet.totalAddressCount)
                }
                segments.append(.ipv4(first: first.raw, count: Int(last.raw - first.raw) + 1))
                continue
            }

            // Wildcard style: 192.168.1.* or 192.168.1.1-255
            if token.contains("*") {
                let start = token.replacingOccurrences(of: "*", with: "0")
                let end = token.replacingOccurrences(of: "*", with: "255")
                guard let first = IPv4(start), let last = IPv4(end), first.raw <= last.raw else {
                    throw HostRangeError.invalid(token)
                }
                let count = Int(last.raw - first.raw) + 1
                segments.append(.ipv4(first: first.raw, count: count))
                continue
            }

            // Range: 192.168.1.1-192.168.1.50 or 192.168.1.1-50
            if token.contains("-") {
                let parts = token.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    if let first = IPv4(parts[0]), let last = IPv4(parts[1]), first.raw <= last.raw {
                        let count = Int(last.raw - first.raw) + 1
                        segments.append(.ipv4(first: first.raw, count: count))
                        continue
                    }
                    // Short form 192.168.1.1-50
                    if let first = IPv4(parts[0]), let lastOctet = UInt8(parts[1]) {
                        let octets = first.octets
                        guard lastOctet >= octets[3] else { throw HostRangeError.invalid(token) }
                        let count = Int(lastOctet) - Int(octets[3]) + 1
                        let base = first.raw - UInt32(octets[3])
                        segments.append(.ipv4(first: base + UInt32(octets[3]), count: count))
                        continue
                    }
                }
                throw HostRangeError.invalid(token)
            }

            // Plain host / IP
            segments.append(.literal(token))
        }

        guard !segments.isEmpty else { throw HostRangeError.empty }
        return segments
    }
}
