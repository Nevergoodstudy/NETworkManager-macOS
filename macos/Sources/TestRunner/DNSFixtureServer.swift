import Foundation
import Network

final class DNSFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dns-fixture-\(UUID().uuidString)")
    private let startup = DNSListenerStartup()
    private let queryReceived = DispatchSemaphore(value: 0)
    private let responseBuilder: (@Sendable (Data) -> Data?)?
    private(set) var port: UInt16 = 0

    init(responseBuilder: (@Sendable (Data) -> Data?)? = nil) throws {
        self.responseBuilder = responseBuilder
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [startup] state in
            switch state {
            case .ready:
                startup.complete(error: nil)
            case .failed(let error):
                startup.complete(error: error)
            case .cancelled:
                startup.complete(error: NSError(domain: "DNSFixtureServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled before starting."]))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveQueries(on: connection)
        }
        listener.start(queue: queue)
        guard startup.semaphore.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw NSError(domain: "DNSFixtureServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out starting the loopback DNS fixture."])
        }
        if let error = startup.error {
            listener.cancel()
            throw error
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "DNSFixtureServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Loopback DNS fixture has no port."])
        }
        self.port = port
    }

    func waitForQuery(timeout: TimeInterval) -> Bool {
        queryReceived.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        listener.cancel()
    }

    private func receiveQueries(on connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                self.queryReceived.signal()
                if let response = self.responseBuilder?(data) {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receiveQueries(on: connection) }
        }
    }

    static func loopbackARecordResponse(for query: Data) -> Data? {
        guard query.count >= 17, query[4] == 0, query[5] == 1 else { return nil }
        var response = Data(query.prefix(2))
        response.append(contentsOf: [0x81, 0x80])
        response.append(contentsOf: query[4..<6])
        response.append(contentsOf: [0, 1, 0, 0, 0, 0])
        response.append(query.subdata(in: 12..<query.count))
        response.append(contentsOf: [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 42])
        return response
    }
}

private final class DNSListenerStartup: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didComplete = false
    private(set) var error: Error?

    func complete(error: Error?) {
        lock.lock()
        guard !didComplete else { lock.unlock(); return }
        didComplete = true
        self.error = error
        lock.unlock()
        semaphore.signal()
    }
}
