import Foundation
import Darwin
import dnssd

struct ResolvedSocketAddress: @unchecked Sendable {
    let family: Int32
    let length: socklen_t
    let numericAddress: String
    let storage: sockaddr_storage

    var bytes: [UInt8] {
        withUnsafeBytes(of: storage) { Array($0.prefix(Int(length))) }
    }

    func withSockAddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result) rethrows -> Result {
        var copy = storage
        return try withUnsafePointer(to: &copy) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }

    static func copy(from address: UnsafePointer<sockaddr>, port: UInt16,
                     interfaceIndex: UInt32 = 0) -> ResolvedSocketAddress? {
        let family = Int32(address.pointee.sa_family)
        let length: socklen_t
        switch family {
        case AF_INET: length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return nil
        }

        var storage = sockaddr_storage()
        _ = memset(&storage, 0, MemoryLayout<sockaddr_storage>.size)
        _ = memcpy(&storage, address, Int(length))
        withUnsafeMutablePointer(to: &storage) { pointer in
            if family == AF_INET {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_port = port.bigEndian
                }
            } else {
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_port = port.bigEndian
                    let first = $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0
                    let second = $0.pointee.sin6_addr.__u6_addr.__u6_addr8.1
                    let isLinkLocal = first == 0xfe && second & 0xc0 == 0x80
                    if isLinkLocal && $0.pointee.sin6_scope_id == 0 {
                        $0.pointee.sin6_scope_id = interfaceIndex
                    }
                }
            }
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return nil }
        return ResolvedSocketAddress(family: family, length: length,
                                     numericAddress: String(cString: hostBuffer), storage: storage)
    }
}

enum SocketAddressResolutionError: Error, LocalizedError, Equatable {
    case cancelled
    case timedOut
    case service(Int32)
    case noAddresses

    var errorDescription: String? {
        switch self {
        case .cancelled: return t("Diagnostic cancelled")
        case .timedOut: return t("Host address resolution timed out.")
        case .service(let code): return tf("Host address resolution failed (DNS-SD %@).", String(code))
        case .noAddresses: return t("The host did not resolve to an IP address.")
        }
    }
}

protocol AddressResolutionSession: AnyObject {
    var fileDescriptor: Int32 { get }
    var isFinished: Bool { get }
    var errorCode: Int32? { get }
    var addresses: [ResolvedSocketAddress] { get }
    func processPendingResults() -> Int32
    func cancel()
}

private final class DNSServiceAddressState {
    let port: UInt16
    var addresses: [String: ResolvedSocketAddress] = [:]
    var order: [String] = []
    var errorCode: Int32?
    var isFinished = false

    init(port: UInt16) { self.port = port }
}

private func dnsServiceAddressCallback(_ serviceRef: DNSServiceRef?,
                                       _ flags: DNSServiceFlags,
                                       _ interfaceIndex: UInt32,
                                       _ errorCode: Int32,
                                       _ hostname: UnsafePointer<CChar>?,
                                       _ address: UnsafePointer<sockaddr>?,
                                       _ ttl: UInt32,
                                       _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let state = Unmanaged<DNSServiceAddressState>.fromOpaque(context).takeUnretainedValue()
    if errorCode != Int32(kDNSServiceErr_NoError) {
        state.errorCode = errorCode
        state.isFinished = true
        return
    }

    if let address, let resolved = ResolvedSocketAddress.copy(from: address, port: state.port,
                                                               interfaceIndex: interfaceIndex) {
        let key = "\(resolved.family):\(resolved.numericAddress)"
        if flags & kDNSServiceFlagsAdd != 0 {
            if state.addresses[key] == nil { state.order.append(key) }
            state.addresses[key] = resolved
        } else {
            state.addresses.removeValue(forKey: key)
            state.order.removeAll { $0 == key }
        }
    }
    if flags & kDNSServiceFlagsMoreComing == 0 { state.isFinished = true }
}

private final class DNSServiceAddressSession: AddressResolutionSession {
    private var serviceRef: DNSServiceRef?
    private let state: DNSServiceAddressState
    let fileDescriptor: Int32

    var isFinished: Bool { state.isFinished }
    var errorCode: Int32? { state.errorCode }
    var addresses: [ResolvedSocketAddress] { state.order.compactMap { state.addresses[$0] } }

    init(host: String, port: UInt16) throws {
        state = DNSServiceAddressState(port: port)
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(state).toOpaque()
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let status = host.withCString {
            DNSServiceGetAddrInfo(&ref, 0, 0, protocols, $0, dnsServiceAddressCallback, context)
        }
        guard status == kDNSServiceErr_NoError, let ref else {
            if let ref { DNSServiceRefDeallocate(ref) }
            throw SocketAddressResolutionError.service(Int32(status))
        }
        serviceRef = ref
        fileDescriptor = DNSServiceRefSockFD(ref)
        guard fileDescriptor >= 0 else {
            cancel()
            throw SocketAddressResolutionError.service(Int32(kDNSServiceErr_BadParam))
        }
    }

    func processPendingResults() -> Int32 {
        guard let serviceRef else { return Int32(kDNSServiceErr_BadReference) }
        return Int32(DNSServiceProcessResult(serviceRef))
    }

    func cancel() {
        guard let serviceRef else { return }
        DNSServiceRefDeallocate(serviceRef)
        self.serviceRef = nil
    }
}

enum SocketAddressResolver {
    static func resolve(_ host: String,
                        port: Int? = nil,
                        timeout: TimeInterval = 5,
                        cancellation: DiagnosticCancellation? = nil) throws -> [ResolvedSocketAddress] {
        guard cancellation?.isCancelled != true else { throw SocketAddressResolutionError.cancelled }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { throw SocketAddressResolutionError.noAddresses }
        if let port, !(1...65_535).contains(port) { throw SocketAddressResolutionError.noAddresses }

        let numeric = numericAddresses(normalizedHost, port: port)
        if !numeric.isEmpty { return numeric }

        let session = try DNSServiceAddressSession(host: normalizedHost, port: UInt16(port ?? 0))
        return try collectAddresses(from: session, timeout: timeout, cancellation: cancellation)
    }

    private static func numericAddresses(_ host: String, port: Int?) -> [ResolvedSocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST
        var list: UnsafeMutablePointer<addrinfo>?
        let service = port.map(String.init)
        let status = host.withCString { node in
            if let service { return service.withCString { getaddrinfo(node, $0, &hints, &list) } }
            return getaddrinfo(node, nil, &hints, &list)
        }
        guard status == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [ResolvedSocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr,
               let copied = ResolvedSocketAddress.copy(from: address, port: UInt16(port ?? 0)) {
                addresses.append(copied)
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }

    static func collectAddresses(from session: AddressResolutionSession,
                                 timeout: TimeInterval,
                                 cancellation: DiagnosticCancellation?) throws -> [ResolvedSocketAddress] {
        defer { session.cancel() }
        guard session.fileDescriptor >= 0 else { throw SocketAddressResolutionError.service(Int32(kDNSServiceErr_BadReference)) }
        let deadline = Date().addingTimeInterval(max(0.05, timeout))

        while !session.isFinished {
            if cancellation?.isCancelled == true { throw SocketAddressResolutionError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketAddressResolutionError.timedOut }

            let events = waitForSocketReadiness(fd: session.fileDescriptor,
                                                events: Int16(POLLIN),
                                                timeout: min(remaining, 0.1),
                                                cancellation: cancellation)
            if cancellation?.isCancelled == true { throw SocketAddressResolutionError.cancelled }
            guard events != nil else {
                if Date() >= deadline { throw SocketAddressResolutionError.timedOut }
                continue
            }
            let status = session.processPendingResults()
            guard status == Int32(kDNSServiceErr_NoError) else { throw SocketAddressResolutionError.service(status) }
        }

        if let errorCode = session.errorCode { throw SocketAddressResolutionError.service(errorCode) }
        guard !session.addresses.isEmpty else { throw SocketAddressResolutionError.noAddresses }
        return session.addresses
    }
}
