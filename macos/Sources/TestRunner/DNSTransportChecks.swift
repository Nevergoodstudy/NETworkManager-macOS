import Foundation
@testable import NMCore

enum DNSTransportChecks {
    static func run() async throws {
        for ipv6 in [false, true] {
            for mode in [DNSTransportFixture.Mode.datagram, .segmented] {
                let fixture = try DNSTransportFixture(mode: mode, ipv6: ipv6)
                defer { fixture.stop() }
                let response = try DNSClient.query(name: "fixture.test", type: .a, server: fixture.host, serverPort: fixture.port, timeout: 2)
                try check(response.records.map(\.value) == ["127.0.0.42"], "DNS IPv\(ipv6 ? 6 : 4) UDP/TCP framing")
            }
        }
        let slow = try DNSTransportFixture(mode: .slow, udpDelay: 0.18)
        defer { slow.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try DNSClient.query(name: "fixture.test", type: .a, server: slow.host, serverPort: slow.port, timeout: 0.38)
            throw CheckFailure(description: "DNS slow TCP must exhaust total query budget")
        } catch DNSError.timeout { }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try check(elapsed >= 0.32 && elapsed < 0.65, "DNS UDP plus TCP drip reads share one deadline: \(elapsed)")
        let closed = try DNSTransportFixture(mode: .earlyEOF)
        defer { closed.stop() }
        do {
            _ = try DNSClient.query(name: "fixture.test", type: .a, server: closed.host, serverPort: closed.port, timeout: 2)
            throw CheckFailure(description: "DNS partial TCP frame must fail")
        } catch DNSError.malformed { }
        let silent = try DNSTransportFixture(mode: .silentTCP)
        defer { silent.stop() }
        let cancellation = DiagnosticCancellation()
        let finished = DispatchSemaphore(value: 0)
        let status = DiagnosticStatusBox()
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try DNSClient.query(name: "fixture.test", type: .a, server: silent.host, serverPort: silent.port, timeout: 5, cancellation: cancellation)
                status.set(.succeeded)
            } catch DNSError.cancelled { status.set(.cancelled) }
            catch { status.set(.failed) }
        }
        try check(silent.waitForTCPQuery(), "DNS cancellation reaches TCP fallback")
        cancellation.cancel()
        try check(finished.wait(timeout: .now() + 0.5) == .success && status.get() == .cancelled, "DNS cancellation interrupts TCP frame wait")
        let errorFixture = try DNSFixtureServer { query in
            var response = query; response[2] = 0x81; response[3] = 0x82
            return response
        }
        defer { errorFixture.stop() }
        let failed = await DiagnosticService.runDNS(host: "fixture.test", server: "127.0.0.1", serverPort: errorFixture.port)
        try check(failed.status == .failed && failed.summary.contains("SERVFAIL"), "DNS service reports server RCODE as failure")
        let emptyFixture = try DNSFixtureServer { query in
            var response = query; response[2] = 0x81; response[3] = 0x80
            return response
        }
        defer { emptyFixture.stop() }
        let empty = await DiagnosticService.runDNS(host: "fixture.test", server: "127.0.0.1", serverPort: emptyFixture.port)
        try check(empty.status == .succeeded && empty.dnsRecords.isEmpty, "DNS service preserves successful no-data state")
        for name in ["", "bad..test", "bad.test..", String(repeating: "a", count: 64) + ".test"] {
            do {
                _ = try DNSClient.query(name: name, type: .a, server: "127.0.0.1")
                throw CheckFailure(description: "DNS accepts invalid label layout")
            } catch DNSError.invalidName { }
        }
        for timeout in [TimeInterval.nan, .infinity, 0, -1] {
            do {
                _ = try DNSClient.query(name: "fixture.test", type: .a, server: "127.0.0.1", timeout: timeout)
                throw CheckFailure(description: "DNS accepts invalid timeout")
            } catch DNSError.timeout { }
        }
        print("NMTest: DNS IPv4/IPv6 UDP/TCP, shared deadline, EOF, cancellation and service status passed")
    }
}
