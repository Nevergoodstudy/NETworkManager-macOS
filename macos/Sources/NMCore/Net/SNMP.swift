import Foundation

// MARK: - Minimal native SNMP v1/v2c

public enum SNMPVersion: Int, CaseIterable, Identifiable, Sendable {
    case v1 = 0
    case v2c = 1
    public var id: Int { rawValue }
    public var title: String { self == .v1 ? "SNMP v1" : "SNMP v2c" }
}

public enum SNMPValue: Sendable, Hashable {
    case null
    case integer(Int32)
    case unsigned(UInt32)
    case string(String)
    case octets(Data)
    case oid(String)
    case ipAddress(String)
    case counter64(UInt64)
    case exception(String)

    public var displayValue: String {
        switch self {
        case .null: return "NULL"
        case .integer(let value): return String(value)
        case .unsigned(let value): return String(value)
        case .string(let value): return value
        case .octets(let value): return value.map { String(format: "%02X", $0) }.joined(separator: ":")
        case .oid(let value): return value
        case .ipAddress(let value): return value
        case .counter64(let value): return String(value)
        case .exception(let value): return value
        }
    }
}

public struct SNMPVarBind: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let oid: String
    public let value: SNMPValue

    public init(oid: String, value: SNMPValue) { self.oid = oid; self.value = value }
}

public struct SNMPResponse: Sendable {
    public let requestID: Int32
    public let errorStatus: Int
    public let errorIndex: Int
    public let varBinds: [SNMPVarBind]
    public let elapsed: TimeInterval

    public init(requestID: Int32, errorStatus: Int, errorIndex: Int,
                varBinds: [SNMPVarBind], elapsed: TimeInterval) {
        self.requestID = requestID; self.errorStatus = errorStatus; self.errorIndex = errorIndex
        self.varBinds = varBinds; self.elapsed = elapsed
    }
}

public enum SNMPError: LocalizedError {
    case invalidOID
    case transport(String)
    case timeout
    case cancelled
    case malformed(String)
    case agent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOID: return t("Enter a valid numeric OID, for example 1.3.6.1.2.1.1.1.0.")
        case .transport(let value), .malformed(let value), .agent(let value): return value
        case .timeout: return t("The SNMP agent did not answer in time.")
        case .cancelled: return t("Diagnostic cancelled")
        }
    }
}

public final class SNMPClient: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let community: String
    public let version: SNMPVersion
    public let timeout: TimeInterval
    public let retries: Int
    private var nextRequestID: Int32 = Int32.random(in: 1...Int32.max)

    public init(host: String, community: String = "public", version: SNMPVersion = .v2c,
                port: Int = 161, timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host; self.community = community; self.version = version
        self.port = max(1, min(port, 65535)); self.timeout = max(0.1, timeout); self.retries = max(0, retries)
    }

    public func get(_ oid: String, cancellation: DiagnosticCancellation? = nil) throws -> SNMPResponse {
        try request(pdu: .get, varBinds: [(oid, .null)], cancellation: cancellation)
    }

    public func set(_ oid: String, value: SNMPValue, cancellation: DiagnosticCancellation? = nil) throws -> SNMPResponse {
        try request(pdu: .set, varBinds: [(oid, value)], cancellation: cancellation)
    }

    /// Walk a subtree with GETNEXT. The returned list includes each object
    /// returned by the agent until it leaves the requested root.
    public func walk(_ rootOID: String, maxResults: Int = 500, cancellation: DiagnosticCancellation? = nil) throws -> [SNMPVarBind] {
        let root = try OID.parse(rootOID)
        var current = root
        var values: [SNMPVarBind] = []
        while values.count < maxResults {
            if cancellation?.isCancelled == true { throw SNMPError.cancelled }
            let response = try request(pdu: .getNext, varBinds: [(OID.format(current), .null)], cancellation: cancellation)
            guard let item = response.varBinds.first else { break }
            guard let oid = try? OID.parse(item.oid), oid.starts(with: root) else { break }
            values.append(item)
            if oid == current { break }
            current = oid
        }
        return values
    }

    private enum PDU { case get, getNext, set }

    private func request(pdu: PDU, varBinds: [(String, SNMPValue)], cancellation: DiagnosticCancellation?) throws -> SNMPResponse {
        let requestID = nextRequestID
        nextRequestID &+= 1
        let oids = try varBinds.map { oid, value -> Data in
            let parsed = try OID.parse(oid)
            return BER.sequence(BER.oid(parsed) + BER.value(value))
        }
        let varBindList = BER.sequence(oids.reduce(into: Data(), { $0.append($1) }))
        let pduTag: UInt8 = pdu == .get ? 0xA0 : (pdu == .getNext ? 0xA1 : 0xA3)
        let pduBody = BER.integer(requestID) + BER.integer(0) + BER.integer(0) + varBindList
        let packet = BER.sequence(
            BER.integer(Int32(version.rawValue)) + BER.octets(Data(community.utf8)) + BER.tlv(pduTag, pduBody)
        )
        let start = Date()
        var lastError: Error = SNMPError.timeout
        for _ in 0...retries {
            do {
                if cancellation?.isCancelled == true { throw SNMPError.cancelled }
                let data = try exchange(packet, cancellation: cancellation)
                let parsed = try parseResponse(data, expectedRequestID: requestID)
                return SNMPResponse(requestID: requestID, errorStatus: parsed.status,
                                    errorIndex: parsed.index, varBinds: parsed.binds,
                                    elapsed: Date().timeIntervalSince(start))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func exchange(_ packet: Data, cancellation: DiagnosticCancellation?) throws -> Data {
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(host, port: port, timeout: timeout,
                                                           cancellation: cancellation)
            guard !addresses.isEmpty else {
                throw SNMPError.transport(tf("Cannot resolve SNMP host %@.", host))
            }
        } catch SocketAddressResolutionError.cancelled {
            throw SNMPError.cancelled
        } catch SocketAddressResolutionError.timedOut {
            throw SNMPError.timeout
        } catch let error as SNMPError {
            throw error
        } catch {
            throw SNMPError.transport(tf("Cannot resolve SNMP host %@.", host))
        }
        if cancellation?.isCancelled == true { throw SNMPError.cancelled }
        for address in addresses {
            if cancellation?.isCancelled == true { throw SNMPError.cancelled }
            let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let sent = packet.withUnsafeBytes { raw in
                address.withSockAddr { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
            }
            guard sent == packet.count else { continue }
            guard waitForSocketReadiness(fd: fd, events: Int16(POLLIN), timeout: timeout, cancellation: cancellation) != nil else {
                if cancellation?.isCancelled == true { throw SNMPError.cancelled }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 65_535)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno != EAGAIN && errno != EWOULDBLOCK { throw SNMPError.transport(String(cString: strerror(errno))) }
        }
        throw SNMPError.timeout
    }

    private func parseResponse(_ data: Data, expectedRequestID: Int32) throws -> (status: Int, index: Int, binds: [SNMPVarBind]) {
        var reader = BER.Reader(data)
        let message = try reader.readConstructed(expectedTag: 0x30)
        var body = BER.Reader(message)
        _ = try body.readInteger() // version
        _ = try body.readOctets() // community
        let pdu = try body.readConstructed(anyOf: [0xA0, 0xA1, 0xA2, 0xA3])
        var pduReader = BER.Reader(pdu)
        let requestID = try pduReader.readInteger()
        guard requestID == expectedRequestID else { throw SNMPError.malformed(t("Unexpected SNMP request ID.")) }
        let status = Int(try pduReader.readInteger())
        let index = Int(try pduReader.readInteger())
        let list = try pduReader.readConstructed(expectedTag: 0x30)
        var listReader = BER.Reader(list)
        var binds: [SNMPVarBind] = []
        while !listReader.isAtEnd {
            let item = try listReader.readConstructed(expectedTag: 0x30)
            var itemReader = BER.Reader(item)
            let oid = try itemReader.readOID()
            let value = try itemReader.readValue()
            binds.append(SNMPVarBind(oid: oid, value: value))
        }
        if status != 0 { throw SNMPError.agent(tf("SNMP agent error %d at index %d.", status, index)) }
        return (status, index, binds)
    }
}

// MARK: - BER helpers

private enum BER {
    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag]); result.append(length(value.count)); result.append(value); return result
    }

    static func sequence(_ value: Data) -> Data { tlv(0x30, value) }
    static func octets(_ value: Data) -> Data { tlv(0x04, value) }
    static func value(_ value: SNMPValue) -> Data {
        switch value {
        case .null: return tlv(0x05, Data())
        case .integer(let value): return integer(value)
        case .unsigned(let value): return integer(Int32(bitPattern: value), tag: 0x42)
        case .string(let value): return octets(Data(value.utf8))
        case .octets(let value): return octets(value)
        case .oid(let value):
            guard let parsed = try? OID.parse(value) else { return tlv(0x05, Data()) }
            return oid(parsed)
        case .ipAddress(let value):
            let bytes = value.split(separator: ".").compactMap { UInt8($0) }
            return bytes.count == 4 ? tlv(0x40, Data(bytes)) : tlv(0x05, Data())
        case .counter64(let value): return integer64(value)
        case .exception: return tlv(0x80, Data())
        }
    }

    static func integer(_ value: Int32, tag: UInt8 = 0x02) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1 && ((bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0)) { bytes.removeFirst() }
        return tlv(tag, Data(bytes))
    }

    static func integer64(_ value: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes.first ?? 0 >= 0x80 { bytes.insert(0, at: 0) }
        return tlv(0x46, Data(bytes))
    }

    static func oid(_ oid: [UInt32]) -> Data {
        guard oid.count >= 2 else { return tlv(0x06, Data()) }
        var bytes = Data(); appendBase128(oid[0] * 40 + oid[1], to: &bytes)
        for component in oid.dropFirst(2) { appendBase128(component, to: &bytes) }
        return tlv(0x06, bytes)
    }

    private static func appendBase128(_ value: UInt32, to data: inout Data) {
        var chunks = [UInt8(value & 0x7F)]; var rest = value >> 7
        while rest > 0 { chunks.append(UInt8(rest & 0x7F) | 0x80); rest >>= 7 }
        data.append(contentsOf: chunks.reversed())
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count; var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var isAtEnd: Bool { offset >= bytes.count }

        mutating func readTLV() throws -> (UInt8, Data) {
            guard offset < bytes.count else { throw SNMPError.malformed(t("Unexpected end of SNMP response.")) }
            let tag = bytes[offset]; offset += 1
            guard offset < bytes.count else { throw SNMPError.malformed(t("Missing SNMP length.")) }
            let firstLength = bytes[offset]; offset += 1
            let length: Int
            if firstLength & 0x80 == 0 { length = Int(firstLength) }
            else {
                let count = Int(firstLength & 0x7F)
                guard count > 0, count <= 4, offset + count <= bytes.count else { throw SNMPError.malformed(t("Invalid SNMP length.")) }
                length = bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }; offset += count
            }
            guard length >= 0, offset + length <= bytes.count else { throw SNMPError.malformed(t("SNMP value exceeds response.")) }
            let value = Data(bytes[offset..<(offset + length)]); offset += length
            return (tag, value)
        }

        mutating func readConstructed(expectedTag: UInt8) throws -> Data {
            let item = try readTLV(); guard item.0 == expectedTag else { throw SNMPError.malformed(t("Unexpected SNMP tag.")) }; return item.1
        }
        mutating func readConstructed(anyOf tags: [UInt8]) throws -> Data {
            let item = try readTLV(); guard tags.contains(item.0) else { throw SNMPError.malformed(t("Unexpected SNMP PDU.")) }; return item.1
        }
        mutating func readInteger() throws -> Int32 {
            let item = try readTLV(); guard item.0 == 0x02, !item.1.isEmpty, item.1.count <= 4 else { throw SNMPError.malformed(t("Invalid SNMP integer.")) }
            var value: Int32 = item.1.first! & 0x80 == 0 ? 0 : -1
            for byte in item.1 { value = (value << 8) | Int32(byte) }
            return value
        }
        mutating func readOctets() throws -> Data {
            let item = try readTLV(); guard item.0 == 0x04 else { throw SNMPError.malformed(t("Invalid SNMP community.")) }; return item.1
        }
        mutating func readOID() throws -> String {
            let item = try readTLV(); guard item.0 == 0x06, !item.1.isEmpty else { throw SNMPError.malformed(t("Invalid SNMP OID.")) }
            let bytes = Array(item.1); var values: [UInt32] = []
            var accumulator: UInt32 = 0
            for byte in bytes {
                accumulator = (accumulator << 7) | UInt32(byte & 0x7F)
                if byte & 0x80 == 0 { values.append(accumulator); accumulator = 0 }
            }
            guard values.count >= 1 else { throw SNMPError.malformed(t("Invalid SNMP OID.")) }
            let first = min(values[0] / 40, 2); let second = values[0] - first * 40
            return ([first, second] + values.dropFirst()).map(String.init).joined(separator: ".")
        }
        mutating func readValue() throws -> SNMPValue {
            let item = try readTLV()
            switch item.0 {
            case 0x02:
                guard !item.1.isEmpty else { throw SNMPError.malformed(t("Invalid SNMP value.")) }
                var value: Int32 = item.1.first! & 0x80 == 0 ? 0 : -1; for byte in item.1 { value = (value << 8) | Int32(byte) }; return .integer(value)
            case 0x04: return .string(String(decoding: item.1, as: UTF8.self))
            case 0x05: return .null
            case 0x06:
                var nested = Reader(Data([item.0, UInt8(item.1.count)]) + item.1); return .oid(try nested.readOID())
            case 0x40: return .ipAddress(item.1.map(String.init).joined(separator: "."))
            case 0x41, 0x42, 0x43:
                return .unsigned(item.1.reduce(0) { ($0 << 8) | UInt32($1) })
            case 0x46: return .counter64(item.1.reduce(0) { ($0 << 8) | UInt64($1) })
            case 0x80: return .exception("noSuchObject")
            case 0x81: return .exception("noSuchInstance")
            case 0x82: return .exception("endOfMibView")
            default: return .octets(item.1)
            }
        }
    }
}

private enum OID {
    static func parse(_ string: String) throws -> [UInt32] {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2, let values = Optional(parts.compactMap { UInt64($0) }), values.count == parts.count,
              values[0] <= 2, values[1] < 40 || values[0] == 2,
              values.allSatisfy({ $0 <= UInt64(UInt32.max) }) else { throw SNMPError.invalidOID }
        return values.map(UInt32.init)
    }
    static func format(_ oid: [UInt32]) -> String { oid.map(String.init).joined(separator: ".") }
}

private extension Array where Element == UInt32 {
    func starts(with prefix: [UInt32]) -> Bool {
        guard count >= prefix.count else { return false }
        for index in prefix.indices where self[index] != prefix[index] { return false }
        return true
    }
}

