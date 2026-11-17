import Foundation

/// Parses a single response to our IN question. Offsets always refer to the
/// complete message, including when a name starts inside a record's RDATA.
enum DNSResponseParser {
    struct Response {
        let records: [DNSRecord]
        let responseCode: String
        let authoritative: Bool
    }

    private struct Envelope {
        let flags: UInt16
        let counts: [Int]
        let questionEnd: Int
    }

    static func validateEnvelope(_ data: Data, expectedID: UInt16, name: String,
                                 type: DNSRecordType) throws -> Bool {
        try envelope(Array(data), expectedID: expectedID, name: name, type: type).flags & 0x0200 != 0
    }

    static func parse(_ data: Data, expectedID: UInt16, name: String,
                      type: DNSRecordType) throws -> Response {
        let bytes = Array(data)
        let header = try envelope(bytes, expectedID: expectedID, name: name, type: type)
        guard header.flags & 0x0200 == 0 else { throw malformed() }
        var offset = header.questionEnd
        var records: [DNSRecord] = []
        for (section, count) in header.counts.enumerated() {
            for _ in 0..<count {
                let labels = try readName(bytes, offset: &offset, limit: bytes.count)
                guard offset + 10 <= bytes.count else { throw malformed() }
                let rawType = word(bytes, offset)
                let recordClass = word(bytes, offset + 2)
                let ttl = dword(bytes, offset + 4)
                let length = Int(word(bytes, offset + 8))
                offset += 10
                let end = offset + length
                guard end <= bytes.count else { throw malformed() }
                if recordClass == 1, let recordType = DNSRecordType(rawValue: rawType) {
                    // Validate even unselected records: a truncated declared
                    // section must never turn into a partial successful result.
                    let value = try describe(recordType, bytes: bytes, start: offset, end: end)
                    if section == 0, recordType == type {
                        records.append(DNSRecord(name: display(labels), type: recordType, ttl: ttl, value: value))
                    }
                }
                offset = end
            }
        }
        guard offset == bytes.count else { throw malformed() }
        let code = Int(header.flags & 0x000F)
        let codes = ["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"]
        let codeName = code < codes.count ? codes[code] : "RCODE\(code)"
        guard code == 0 else { throw DNSError.serverError(tf("DNS server returned %@.", codeName)) }
        return Response(records: records, responseCode: codeName, authoritative: header.flags & 0x0400 != 0)
    }

    private static func envelope(_ bytes: [UInt8], expectedID: UInt16, name: String,
                                 type: DNSRecordType) throws -> Envelope {
        guard bytes.count >= 12 else { throw malformed() }
        guard word(bytes, 0) == expectedID else { throw DNSError.malformed(t("unexpected transaction id")) }
        let flags = word(bytes, 2)
        // A standard response must echo exactly our question (RFC 1035).
        guard flags & 0x8000 != 0, flags & 0x7800 == 0, word(bytes, 4) == 1 else { throw malformed() }
        var offset = 12
        let labels = try readName(bytes, offset: &offset, limit: bytes.count)
        let normalized = name.hasSuffix(".") ? String(name.dropLast()) : name
        let expected = normalized.isEmpty ? [] : normalized.split(separator: ".", omittingEmptySubsequences: false).map { Array($0.utf8) }
        guard labels.map(foldCase) == expected.map(foldCase), offset + 4 <= bytes.count,
              word(bytes, offset) == type.rawValue, word(bytes, offset + 2) == 1 else { throw malformed() }
        return Envelope(flags: flags, counts: [6, 8, 10].map { Int(word(bytes, $0)) }, questionEnd: offset + 4)
    }

    private static func describe(_ type: DNSRecordType, bytes: [UInt8], start: Int, end: Int) throws -> String {
        var cursor = start
        func require(_ count: Int) throws { guard cursor + count <= end else { throw malformed() } }
        func name() throws -> String { display(try readName(bytes, offset: &cursor, limit: end)) }
        func short() throws -> UInt16 {
            try require(2)
            defer { cursor += 2 }
            return word(bytes, cursor)
        }
        let result: String
        switch type {
        case .a:
            try require(4)
            result = bytes[cursor..<(cursor + 4)].map(String.init).joined(separator: ".")
            cursor += 4
        case .aaaa:
            try require(16)
            result = stride(from: cursor, to: cursor + 16, by: 2).map { String(word(bytes, $0), radix: 16) }.joined(separator: ":")
            cursor += 16
        case .cname, .ns, .ptr:
            result = try name()
        case .mx:
            let preference = try short()
            result = "\(preference) \(try name())"
        case .srv:
            let priority = try short(), weight = try short(), port = try short()
            result = "\(priority) \(weight) \(port) \(try name())"
        case .soa:
            let primary = try name(), mailbox = try name()
            try require(20)
            let numbers = stride(from: cursor, to: cursor + 20, by: 4).map { String(dword(bytes, $0)) }
            cursor += 20
            result = ([primary, mailbox] + numbers).joined(separator: " ")
        case .txt:
            guard cursor < end else { throw malformed() }
            var parts: [String] = []
            while cursor < end {
                let length = Int(bytes[cursor])
                cursor += 1
                try require(length)
                parts.append(String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self))
                cursor += length
            }
            result = parts.joined()
        case .caa:
            try require(2)
            let flags = bytes[cursor], tagLength = Int(bytes[cursor + 1])
            cursor += 2
            guard tagLength > 0 else { throw malformed() }
            try require(tagLength)
            let tag = String(decoding: bytes[cursor..<(cursor + tagLength)], as: UTF8.self)
            cursor += tagLength
            let value = String(decoding: bytes[cursor..<end], as: UTF8.self)
            cursor = end
            result = "\(flags) \(tag) \"\(value)\""
        }
        guard cursor == end else { throw malformed() }
        return result
    }

    private static func readName(_ bytes: [UInt8], offset: inout Int, limit: Int) throws -> [[UInt8]] {
        var cursor = offset
        var jumped = false
        var visited: Set<Int> = []
        var labels: [[UInt8]] = []
        var wireLength = 1 // root terminator
        while true {
            let bound = jumped ? bytes.count : limit
            guard cursor < bound, visited.insert(cursor).inserted else { throw malformed() }
            let length = Int(bytes[cursor])
            if length == 0 {
                if !jumped { offset = cursor + 1 }
                return labels
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bound else { throw malformed() }
                let target = (length & 0x3F) << 8 | Int(bytes[cursor + 1])
                // Compression refers to an earlier name occurrence. Requiring
                // a backward pointer also bounds chains and rejects cycles.
                guard target >= 12, target < cursor else { throw malformed() }
                if !jumped { offset = cursor + 2 }
                jumped = true
                cursor = target
            } else {
                guard length <= 63, cursor + 1 + length <= bound else { throw malformed() }
                wireLength += length + 1
                guard wireLength <= 255 else { throw malformed() }
                labels.append(Array(bytes[(cursor + 1)..<(cursor + 1 + length)]))
                cursor += length + 1
            }
        }
    }

    private static func display(_ labels: [[UInt8]]) -> String {
        labels.isEmpty ? "." : labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".")
    }

    private static func foldCase(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func dword(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(word(bytes, offset)) << 16 | UInt32(word(bytes, offset + 2))
    }

    private static func malformed() -> DNSError {
        .malformed(t("invalid or truncated DNS message"))
    }
}
