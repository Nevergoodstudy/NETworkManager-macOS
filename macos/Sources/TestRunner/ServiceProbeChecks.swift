import Foundation
import Network
@testable import NMCore

/// Each name is one independently runnable case. No selector runs a suite.
enum ServiceProbeChecks {
    static let names = ["service-input", "service-legacy", "service-project", "http-head", "http-status",
                        "http-redirect", "http-timeout", "http-cancel", "tls-timeout", "tls-cancel", "tls-untrusted", "https-untrusted"]

    static func run(_ name: String) async throws {
        switch name {
        case "service-input": try requestBoundary()
        case "service-legacy": try legacyRecord()
        case "service-project": try await projectPersistence()
        case "http-head": try await head()
        case "http-status": try await nonSuccess()
        case "http-redirect": try await redirect()
        case "http-timeout": try await deadline(tls: false)
        case "http-cancel": try await cancellation(tls: false)
        case "tls-timeout": try await deadline(tls: true)
        case "tls-cancel": try await cancellation(tls: true)
        case "tls-untrusted", "https-untrusted": try await untrustedCertificate(http: name == "https-untrusted")
        default: throw CheckFailure(description: "Unknown single case: \(name). Available: \(names.joined(separator: ", "))")
        }
    }

    private static func request(_ method: FieldRetestMethod) -> FieldRetestRequest {
        FieldRetestRequest(target: "localhost", method: method, tcpPort: 443,
                           authorization: FieldRetestAuthorization(reference: "SYNTH-SERVICE", confirmedBy: "Fixture",
                             windowStart: Date().addingTimeInterval(-60), windowEnd: Date().addingTimeInterval(60), confirmed: true))
    }

    private static func requestBoundary() throws {
        var value = request(.http)
        value.target = "::1"
        value.httpPath = "/health ready"
        try value.validate()
        let url = ServiceProbeEndpoint.url(host: value.target, port: 443, scheme: "https", path: value.httpPath!)
        try check(url?.absoluteString == "https://[::1]:443/health%20ready" && url?.user == nil,
                  "IPv6 URL preserves the exact authority and escaped path: \(url?.absoluteString ?? "nil")")
        for host in [".", "host:443", "host\u{0}suffix", "good@other", "[::1]", "service..example", "主机.example"] {
            try check(!ServiceProbeEndpoint.validHost(host), "Ambiguous service authority is rejected")
        }
        for path in ["//other.example", "/?token=secret", "/#fragment", "/%2f%2fother", "/\r\nHost: other", "relative"] {
            try check(ServiceProbeEndpoint.url(host: "localhost", port: 443, scheme: "https", path: path) == nil,
                      "The HTTP path cannot change authority or carry query, fragment or control text")
        }
        value.selectMethod(.tls)
        try check(value.httpPath == nil && value.httpScheme == nil && value.method.layer == .tls, "Switching methods removes HTTP inputs")
    }

    private static func legacyRecord() throws {
        let oldRequest = request(.tcp)
        let record = FieldRetestRecord(request: oldRequest, status: .succeeded, startedAt: Date(), finishedAt: Date(), executedLayers: [.tcp])
        let decoded = try JSONDecoder().decode(FieldRetestRecord.self, from: JSONEncoder().encode(record))
        try decoded.validate()
        try check(decoded.serviceEvidence == nil && decoded.request.httpPath == nil && decoded.request.httpScheme == nil,
                  "Old DNS/TCP records with absent service keys remain readable")
        let evidence = try JSONDecoder().decode(DiagnosticRuntimeEvidence.self, from: Data("{}".utf8))
        try check(evidence.service == nil, "Old diagnostic runtime evidence remains readable")
    }

    @MainActor
    private static func projectPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMServiceProject-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try await ServiceLoopbackFixture(response: "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        var value = request(.http)
        value.target = "127.0.0.1"
        value.tcpPort = Int(server.port)
        value.httpScheme = "http"
        value.httpPath = "/private-fixture-health"
        let store = AssetStore(storageURL: directory.appendingPathComponent("assets.sqlite"))
        var project = FieldProject()
        let incident = FieldIncident(title: "Loopback service retest", owner: "Fixture", ticketReference: "SYNTH-SERVICE")
        try project.saveIncident(incident)
        let record = try await FieldRetestExecutor.run(value, store: store)
        try check(record.status == .succeeded && record.executedLayers == [.http] && record.serviceEvidence?.httpStatus == 204,
                  "The executor saves HTTP as its own stage with structured evidence")
        try check(project.attachRetestRun(record) == .attached, "The HTTP result can be explicitly attached")
        let observation = FieldIncidentEntry(kind: .retested, occurredAt: record.startedAt, author: "Fixture",
                                             detail: "Loopback HTTP HEAD completed", retestRunID: record.id)
        try project.appendIncidentEntry(observation, to: incident.id)
        let bytes = try project.encoded()
        let projectURL = directory.appendingPathComponent("Service.nmfieldproject")
        try bytes.write(to: projectURL, options: .atomic)
        let reopened = try FieldProject.decode(Data(contentsOf: projectURL))
        struct Schema: Decodable { let schemaVersion: Int }
        let document = try JSONDecoder().decode(Schema.self, from: bytes)
        try check(reopened.retestRuns == [record] && reopened.incidents.first?.timeline == [observation] && document.schemaVersion == 5,
                  "Schema 5 restores the service result and its explicit timeline link")
        try check(!reopened.report(includeDetails: false, translate: { $0 }).contains("private-fixture-health") &&
                  reopened.report(includeDetails: true, translate: { $0 }).contains("private-fixture-health"), "Only detailed project reports include the HTTP path")
        let history = AssetStore(storageURL: directory.appendingPathComponent("assets.sqlite"))
        try check(history.diagnosticRuns.first?.kind == .http && history.diagnosticRuns.first?.evidence?.service == record.serviceEvidence,
                  "SQLite history restores the structured HTTP result")
        let exported = try DiagnosticEvidenceExporter.json(runs: history.diagnosticRuns, devices: [])
        try check(String(decoding: exported, as: UTF8.self).contains("httpStatus"), "Diagnostic JSON exports the service evidence")

        let libraryURL = directory.appendingPathComponent("cases.sqlite")
        try FieldCaseLibrary(url: libraryURL).importProject(reopened, from: projectURL, expectedRevision: nil)
        try FileManager.default.removeItem(at: projectURL)
        let library = FieldCaseLibrary(url: libraryURL)
        let found = try library.search(FieldIncidentQuery(ticketReference: incident.ticketReference))
        guard let saved = found.results.first else { throw CheckFailure(description: "The Case reopens without its source file") }
        let savedObservations = try library.observations(for: saved.id)
        try check(found.total == 1 && saved.incident.id == incident.id && saved.source.project.retestRuns == [record] &&
                  savedObservations == [observation],
                  "The offline Case restores the timeline link and complete measured retest")
        struct CaseExport: Decodable {
            struct Observation: Decodable {
                struct Retest: Decodable {
                    let status: FieldRetestStatus
                    let target: String
                    let method: FieldRetestMethod
                    let serviceEvidence: ServiceProbeEvidence
                }
                let id: UUID
                let retest: Retest
            }
            let observations: [Observation]
        }
        let caseJSON = try FieldIncidentExporter.json(for: saved.incident, retestRuns: saved.source.project.retestRuns)
        let caseExport = try JSONDecoder().decode(CaseExport.self, from: caseJSON)
        try check(caseExport.observations.count == 1 && caseExport.observations.first?.id == observation.id &&
                  caseExport.observations.first?.retest.status == record.status &&
                  caseExport.observations.first?.retest.target == record.actualTarget &&
                  caseExport.observations.first?.retest.method == .http &&
                  caseExport.observations.first?.retest.serviceEvidence == record.serviceEvidence,
                  "Case JSON contains the linked retest outcome and structured service evidence")
        let markdown = FieldIncidentExporter.markdown(for: saved.incident, retestRuns: saved.source.project.retestRuns)
        try check(markdown.contains(t("Attached retest result")) && markdown.contains("HTTP HEAD: 204"),
                  "Case Markdown displays the HTTP outcome from the measured service evidence")
        for report in [String(decoding: caseJSON, as: UTF8.self), markdown] {
            try check(!report.contains("private-fixture-health") && !report.contains("Service.nmfieldproject"),
                      "Case export omits the HTTP request path and local project path")
        }
    }

    private static func head() async throws {
        let server = try await ServiceLoopbackFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 10000000\r\nSet-Cookie: fixture-secret=do-not-save\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let result = await DiagnosticService.runHTTP(host: "127.0.0.1", port: Int(server.port), scheme: "http", path: "/health", timeout: 2)
        try check(result.status == .succeeded && result.evidence?.service?.httpStatus == 200 && result.evidence?.service?.tlsVerified == nil,
                  "Plain HTTP HEAD succeeds without claiming TLS")
        try check(server.requests.first?.hasPrefix("HEAD /health HTTP/") == true &&
                  !server.requests.joined().lowercased().contains("authorization:") &&
                  !result.detail.contains("fixture-secret"), "HEAD sends no authorization and stores no response headers or body")
    }

    private static func nonSuccess() async throws {
        let server = try await ServiceLoopbackFixture(response: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let result = await DiagnosticService.runHTTP(host: "127.0.0.1", port: Int(server.port), scheme: "http", timeout: 2)
        try check(result.status == .failed && result.evidence?.service?.httpStatus == 503 && result.evidence?.service?.failure == .httpStatus,
                  "A received non-2xx response is distinguished from a transport failure")
    }

    private static func redirect() async throws {
        let trap = try await ServiceLoopbackFixture(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        defer { trap.stop() }
        let server = try await ServiceLoopbackFixture(response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(trap.port)/secret?token=never-save\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let result = await DiagnosticService.runHTTP(host: "127.0.0.1", port: Int(server.port), scheme: "http", timeout: 2)
        try check(result.status == .failed && result.evidence?.service?.httpStatus == 302 && result.evidence?.service?.redirectRefused == true,
                  "Redirects retain their original status")
        try check(trap.requests.isEmpty && !result.detail.contains("never-save"), "A redirect destination is never contacted or persisted")
    }

    private static func deadline(tls: Bool) async throws {
        let server = try await ServiceLoopbackFixture(response: nil)
        defer { server.stop() }
        let startedAt = Date()
        let result = tls
            ? await DiagnosticService.runTLS(host: "127.0.0.1", port: Int(server.port), timeout: 0.2)
            : await DiagnosticService.runHTTP(host: "127.0.0.1", port: Int(server.port), scheme: "http", timeout: 0.2)
        try check(result.status == .timedOut && result.evidence?.service?.failure == .timedOut && Date().timeIntervalSince(startedAt) < 2,
                  "A silent accepted connection finishes within its total deadline")
    }

    private static func cancellation(tls: Bool) async throws {
        let server = try await ServiceLoopbackFixture(response: nil)
        defer { server.stop() }
        let operation = Task {
            if tls { return await DiagnosticService.runTLS(host: "127.0.0.1", port: Int(server.port), timeout: 5) }
            return await DiagnosticService.runHTTP(host: "127.0.0.1", port: Int(server.port), scheme: "http", timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(80))
        operation.cancel()
        let result = await operation.value
        try check(result.status == .cancelled && result.evidence?.service?.failure == .cancelled,
                  "Cancelling an active service operation returns a distinct terminal observation")
    }

    private static func untrustedCertificate(http: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMUntrustedTLS-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = Process()
        certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        certificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", directory.appendingPathComponent("key.pem").path,
                                 "-out", directory.appendingPathComponent("cert.pem").path, "-days", "1", "-subj", "/CN=localhost"]
        certificate.standardOutput = FileHandle.nullDevice
        certificate.standardError = FileHandle.nullDevice
        try certificate.run()
        certificate.waitUntilExit()
        try check(certificate.terminationStatus == 0, "The local untrusted certificate fixture was generated")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
        import socket,ssl,pathlib,sys
        root=pathlib.Path(sys.argv[1])
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root/'cert.pem',root/'key.pem')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen(1); listener.settimeout(8)
            (root/'port').write_text(str(listener.getsockname()[1]))
            connection,_=listener.accept()
            try:
                with context.wrap_socket(connection,server_side=True) as stream: stream.recv(1024)
            except ssl.SSLError: pass
        """, directory.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let portFile = directory.appendingPathComponent("port")
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = Int(try String(contentsOf: portFile, encoding: .utf8))!
        let result = http
            ? await DiagnosticService.runHTTP(host: "localhost", port: port, timeout: 3)
            : await DiagnosticService.runTLS(host: "localhost", port: port, timeout: 3)
        try check(result.status == .failed && result.evidence?.service?.tlsVerified == false &&
                  (result.evidence?.service?.failure == .tlsValidation || result.evidence?.service?.failure == .tlsHandshake),
                  "System trust rejects a local self-signed certificate")
    }
}

private final class ServiceLoopbackFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NETworkManager.ServiceFixture")
    private let listener: NWListener
    private let response: String?
    private var connections: [NWConnection] = []
    private var savedRequests: [String] = []
    var port: UInt16 { listener.port!.rawValue }
    var requests: [String] { queue.sync { savedRequests } }

    init(response: String?) async throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, bytes: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            let collected = bytes + (data ?? Data())
            let text = String(decoding: collected, as: UTF8.self)
            if text.contains("\r\n\r\n") {
                self.savedRequests.append(text)
                if let response = self.response {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            if !complete, error == nil, collected.count < 16_384 { self.read(connection, bytes: collected) }
        }
    }
}
