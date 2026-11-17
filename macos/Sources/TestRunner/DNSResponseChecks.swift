import Foundation
@testable import NMCore

enum DNSResponseChecks {
    static func run() throws {
        for (type, data, expected) in cases {
            let response = message(type: type, answers: [rr(type, data)])
            let result = try parse(response, type: type)
            try check(result.records.count == 1, "DNS parser record count: \(type)")
            try check(result.records.first?.value == expected, "DNS parser value: \(type): \(result.records.first?.value ?? "nil")")
            try check(result.records.first?.ttl == 60, "DNS parser preserves authoritative record TTL")
            // Every strict prefix is incomplete, never a partial success.
            for length in 0..<response.count {
                try rejects(Data(response.prefix(length)), type: type, label: "truncated \(type) at \(length)")
            }
        }
        let compressed: [DNSRecordType] = [.cname, .ns, .ptr, .mx, .srv, .soa]
        for type in compressed {
            let prefix: [UInt8] = type == .mx ? [0, 10] : type == .srv ? [0, 1, 0, 2, 1, 187] : []
            let suffix: [UInt8] = type == .soa ? [0xC0, 0x0C] + Array(repeating: [0, 0, 0, 1], count: 5).flatMap { $0 } : []
            let result = try parse(message(type: type, answers: [rr(type, prefix + [0xC0, 0x0C] + suffix)]), type: type)
            try check(result.records.first?.value.contains("fixture.test") == true, "DNS compressed RDATA absolute offset: \(type)")
        }
        let selected = rr(.a, [127, 0, 0, 42])
        let result = try parse(message(answers: [rr(.cname, name("alias.test")), selected, rr(.a, [10, 0, 0, 1], recordClass: 3)],
                                       authority: [selected], additional: [selected]))
        try check(result.records.map(\.value) == ["127.0.0.42"], "DNS output includes only selected IN answer records")
        let empty = try parse(message(authority: [rr(.ns, name("ns.test"))], additional: [selected]))
        try check(empty.records.isEmpty && empty.responseCode == "NOERROR", "DNS no matching answer is a successful empty result")
        _ = try DNSResponseParser.parse(message(answers: [selected]), expectedID: 0x1234, name: "FiXtUrE.TeSt.", type: .a)
        _ = try DNSResponseParser.parse(message(questionName: "."), expectedID: 0x1234, name: ".", type: .a)
        for code in 1...5 {
            do {
                _ = try parse(message(flags: 0x8180 | UInt16(code)))
                throw CheckFailure(description: "DNS response code \(code) must fail")
            } catch DNSError.serverError { }
        }
        for response in [message(flags: 0x0180), message(flags: 0x8980), message(flags: 0x8380),
                         message(questionName: "other.test"), message(type: .aaaa),
                         message(answers: [selected]) + Data([0])] {
            try rejects(response, label: "invalid envelope or trailing data")
        }
        var wrongID = message(); wrongID[0] = 0
        try rejects(wrongID, label: "transaction mismatch")
        var wrongClass = message(); wrongClass[wrongClass.count - 1] = 3
        try rejects(wrongClass, label: "question class mismatch")
        var wrongCount = message(); wrongCount[5] = 2
        try rejects(wrongCount, label: "question count mismatch")
        for data: [UInt8] in [[0xC0], [0xC0, 0xFF], [0xC0, 0x0C, 0], [0x40, 0], [3, 97, 0], [0xC0, 0x00]] {
            try rejects(message(type: .cname, answers: [rr(.cname, data)]), type: .cname, label: "malformed compressed name")
        }
        // RDATA starts after the 30-byte question and 12-byte RR header.
        try rejects(message(type: .cname, answers: [rr(.cname, [0xC0, 0x2A])]), type: .cname, label: "self pointer")
        try rejects(message(type: .cname, answers: [rr(.cname, [0xC0, 0x2B, 0])]), type: .cname, label: "forward pointer")
        let invalidData: [(DNSRecordType, [UInt8])] = [(.a, [1, 2, 3]), (.aaaa, [1]), (.txt, [3, 97]), (.txt, []),
                                                      (.mx, [0]), (.srv, [0, 1]), (.soa, [0, 0]), (.caa, [0, 4, 97])]
        for (type, data) in invalidData {
            try rejects(message(type: type, answers: [rr(type, data)]), type: type, label: "invalid typed RDATA")
        }
        var truncatedAdditional = message(answers: [selected], additional: [selected])
        truncatedAdditional.removeLast()
        try rejects(truncatedAdditional, label: "partial answers cannot hide truncated additional section")
        let overlongName: [UInt8] = Array(repeating: [UInt8(63)] + Array(repeating: UInt8(97), count: 63), count: 4).flatMap { $0 } + [0]
        try rejects(message(type: .ns, answers: [rr(.ns, overlongName)]), type: .ns, label: "expanded name over 255 bytes")
        let truncated = try DNSResponseParser.validateEnvelope(message(flags: 0x8380), expectedID: 0x1234, name: "fixture.test", type: .a)
        try check(truncated, "validated TC envelope requests TCP fallback")
        print("NMTest: DNS parser records, compression, bounds, envelope and server errors passed")
    }

    private static var cases: [(DNSRecordType, [UInt8], String)] {
        [(.a, [127, 0, 0, 42], "127.0.0.42"),
         (.aaaa, [0x20, 1, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1], "2001:db8:0:0:0:0:0:1"),
         (.cname, name("alias.test"), "alias.test"), (.ns, name("ns.test"), "ns.test"),
         (.ptr, name("host.test"), "host.test"), (.mx, [0, 10] + name("mail.test"), "10 mail.test"),
         (.srv, [0, 1, 0, 2, 1, 187] + name("service.test"), "1 2 443 service.test"),
         (.soa, name("ns.test") + name("admin.test") + Array(repeating: [0, 0, 0, 1], count: 5).flatMap { $0 }, "ns.test admin.test 1 1 1 1 1"),
         (.txt, [3, 97, 98, 99, 0, 2, 100, 101], "abcde"),
         (.caa, [0, 5] + Array("issueca.test".utf8), "0 issue \"ca.test\"")]
    }

    static func name(_ value: String) -> [UInt8] {
        if value == "." { return [0] }
        return value.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    static func message(type: DNSRecordType = .a, questionName: String = "fixture.test", flags: UInt16 = 0x8180,
                        answers: [[UInt8]] = [], authority: [[UInt8]] = [], additional: [[UInt8]] = []) -> Data {
        var bytes = words([0x1234, flags, 1, UInt16(answers.count), UInt16(authority.count), UInt16(additional.count)])
        bytes += name(questionName) + words([type.rawValue, 1])
        bytes += (answers + authority + additional).flatMap { $0 }
        return Data(bytes)
    }

    static func rr(_ type: DNSRecordType, _ data: [UInt8], recordClass: UInt16 = 1) -> [UInt8] {
        [0xC0, 0x0C] + words([type.rawValue, recordClass, 0, 60, UInt16(data.count)]) + data
    }

    private static func words(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    private static func parse(_ data: Data, type: DNSRecordType = .a) throws -> DNSResponseParser.Response {
        try DNSResponseParser.parse(data, expectedID: 0x1234, name: "fixture.test", type: type)
    }

    private static func rejects(_ data: Data, type: DNSRecordType = .a, label: String) throws {
        do {
            _ = try parse(data, type: type)
            throw CheckFailure(description: "DNS parser accepted \(label)")
        } catch DNSError.malformed { }
    }
}
