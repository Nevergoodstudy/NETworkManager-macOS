import Foundation
import Network

/// Same-port UDP/TCP loopback peer. Delays and framing are intentional, bounded
/// fixture behavior; stopping cancels every accepted connection.
final class DNSTransportFixture: @unchecked Sendable {
    enum Mode { case datagram, segmented, earlyEOF, slow, silentTCP }
    private let queue = DispatchQueue(label: "dns-transport-fixture")
    private let udp: NWListener
    private var tcp: NWListener?
    private let mode: Mode
    private let udpDelay: TimeInterval
    private let lock = NSLock()
    private var stopped = false
    private var connections: [NWConnection] = []
    private let tcpQuery = DispatchSemaphore(value: 0)
    let port: UInt16
    let host: String

    init(mode: Mode, ipv6: Bool = false, udpDelay: TimeInterval = 0) throws {
        self.mode = mode
        self.udpDelay = udpDelay
        host = ipv6 ? "::1" : "127.0.0.1"
        let endpoint = NWEndpoint.Host(host)
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: endpoint, port: .any)
        udp = try NWListener(using: parameters)
        try Self.start(udp, on: queue)
        guard let assigned = udp.port else { udp.cancel(); throw CheckFailure(description: "DNS fixture port missing") }
        port = assigned.rawValue
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = .hostPort(host: endpoint, port: assigned)
        do {
            let listener = try NWListener(using: tcpParameters)
            tcp = listener
            try Self.start(listener, on: queue)
        } catch { udp.cancel(); tcp?.cancel(); throw error }
        udp.newConnectionHandler = { [weak self] in self?.accept($0, tcp: false) }
        tcp?.newConnectionHandler = { [weak self] in self?.accept($0, tcp: true) }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        stopped = true
        let active = connections
        connections.removeAll()
        lock.unlock()
        udp.cancel(); tcp?.cancel()
        active.forEach { $0.cancel() }
    }

    func waitForTCPQuery() -> Bool { tcpQuery.wait(timeout: .now() + 2) == .success }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private static func start(_ listener: NWListener, on queue: DispatchQueue) throws {
        let state = DNSFixtureStartup()
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { value in
            switch value {
            case .ready: state.complete(nil)
            case .failed(let error): state.complete(error)
            default: break
            }
        }
        listener.start(queue: queue)
        guard state.ready.wait(timeout: .now() + 3) == .success else {
            listener.cancel(); throw CheckFailure(description: "DNS fixture startup timeout")
        }
        if let error = state.error { listener.cancel(); throw error }
    }

    private func accept(_ connection: NWConnection, tcp: Bool) {
        lock.lock()
        guard !stopped else { lock.unlock(); connection.cancel(); return }
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        if tcp {
            receive(connection, count: 2) { [weak self] prefix in
                guard let self else { return }
                let length = Int(prefix[0]) << 8 | Int(prefix[1])
                guard length >= 12 else { connection.cancel(); return }
                self.receive(connection, count: length) { [weak self] query in self?.replyTCP(connection, query: query) }
            }
        } else {
            connection.receiveMessage { [weak self] query, _, _, _ in
                guard let self, let query, let answer = DNSFixtureServer.loopbackARecordResponse(for: query) else { connection.cancel(); return }
                var response = answer
                if self.mode != .datagram {
                    response = Data(query)
                    response[2] = 0x83; response[3] = 0x80 // matching question, TC
                }
                let payload = response
                self.queue.asyncAfter(deadline: .now() + self.udpDelay) { [weak self] in
                    guard self?.isStopped == false else { return }
                    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private func receive(_ connection: NWConnection, count: Int, data: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { [weak self] next, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = data
            if let next { buffer.append(next) }
            if buffer.count == count { completion(buffer) }
            else if !complete { self.receive(connection, count: count, data: buffer, completion: completion) }
            else { connection.cancel() }
        }
    }

    private func replyTCP(_ connection: NWConnection, query: Data) {
        tcpQuery.signal()
        guard mode != .silentTCP, let response = DNSFixtureServer.loopbackARecordResponse(for: query) else { return }
        var frame = Data([UInt8(response.count >> 8), UInt8(response.count & 255)])
        frame.append(response)
        if mode == .earlyEOF {
            connection.send(content: Data(frame.prefix(5)), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            sendBytes(frame, at: 0, connection: connection, delay: mode == .slow ? 0.08 : 0.001)
        }
    }

    private func sendBytes(_ data: Data, at offset: Int, connection: NWConnection, delay: TimeInterval) {
        guard !isStopped, offset < data.count else { return }
        connection.send(content: Data([data[offset]]), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendBytes(data, at: offset + 1, connection: connection, delay: delay)
            }
        })
    }
}

private final class DNSFixtureStartup: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private(set) var error: Error?
    func complete(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; self.error = error
        lock.unlock(); ready.signal()
    }
}
