import Foundation
import Network
import Security
import Darwin

public enum ServiceProbeFailure: String, Codable, Hashable, Sendable {
    case invalidInput, tlsValidation, tlsHandshake, httpStatus, transport, timedOut, cancelled, authenticationRequired, outputLimit
}

/// Facts reported by the transport. A proxy address is never an origin address.
public struct ServiceProbeEvidence: Codable, Hashable, Sendable {
    public var peerAddress: String?
    public var peerIsProxy: Bool?
    public var tlsVerified: Bool?
    public var tlsVersion: UInt16?
    public var tlsCipherSuite: UInt16?
    public var httpStatus: Int?
    public var redirectRefused: Bool?
    public var failure: ServiceProbeFailure?
    public var errorCode: Int?

    public init(peerAddress: String? = nil, peerIsProxy: Bool? = nil, tlsVerified: Bool? = nil,
                tlsVersion: UInt16? = nil, tlsCipherSuite: UInt16? = nil, httpStatus: Int? = nil,
                redirectRefused: Bool? = nil, failure: ServiceProbeFailure? = nil, errorCode: Int? = nil) {
        self.peerAddress = peerAddress
        self.peerIsProxy = peerIsProxy
        self.tlsVerified = tlsVerified
        self.tlsVersion = tlsVersion
        self.tlsCipherSuite = tlsCipherSuite
        self.httpStatus = httpStatus
        self.redirectRefused = redirectRefused
        self.failure = failure
        self.errorCode = errorCode
    }

    public var detail: String {
        var lines: [String] = []
        if let peerAddress { lines.append("\(t("Transport peer")): \(peerAddress)") }
        if peerIsProxy == true { lines.append(t("The transport peer is a proxy; the origin address was not measured.")) }
        if let tlsVerified { lines.append(t(tlsVerified ? "TLS trust verified" : "TLS trust not verified")) }
        if let tlsVersion { lines.append("\(t("TLS version")): " + String(format: "0x%04X", tlsVersion)) }
        if let tlsCipherSuite { lines.append("\(t("TLS cipher suite")): " + String(format: "0x%04X", tlsCipherSuite)) }
        if let httpStatus { lines.append("HTTP HEAD: \(httpStatus)") }
        if redirectRefused == true { lines.append(t("Redirect received and not followed.")) }
        if let failure { lines.append("reason=\(failure.rawValue)") }
        if let errorCode { lines.append("code=\(errorCode)") }
        return lines.joined(separator: "\n")
    }
}

enum ServiceProbeEndpoint {
    static func isNumeric(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    static func validHost(_ host: String) -> Bool {
        if isNumeric(host) { return true }
        guard !host.isEmpty, host.utf8.count <= 253, host.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func url(host: String, port: Int, scheme: String, path: String) -> URL? {
        guard validHost(host), (1...65_535).contains(port), ["http", "https"].contains(scheme),
              path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 1_024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains(where: { "?#\\%".contains($0) }) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = port
        parts.path = path
        return parts.url
    }
}

extension DiagnosticService {
    public static func runTLS(host: String, port: Int = 443, timeout: TimeInterval = 5) async -> DiagnosticExecutionResult {
        guard ServiceProbeEndpoint.validHost(host), (1...65_535).contains(port) else {
            return serviceResult(status: .failed, evidence: ServiceProbeEvidence(failure: .invalidInput), source: "TLS")
        }
        let operation = TLSProbeOperation(host: host, port: UInt16(port), timeout: serviceTimeout(timeout))
        return await withTaskCancellationHandler(operation: { await operation.run() }, onCancel: { operation.cancel() })
    }

    public static func runHTTP(host: String, port: Int = 443, scheme: String = "https", path: String = "/",
                               timeout: TimeInterval = 5) async -> DiagnosticExecutionResult {
        guard let url = ServiceProbeEndpoint.url(host: host, port: port, scheme: scheme, path: path) else {
            return serviceResult(status: .failed, evidence: ServiceProbeEvidence(failure: .invalidInput), source: "HTTP")
        }
        let operation = HTTPProbeOperation(url: url, timeout: serviceTimeout(timeout))
        return await withTaskCancellationHandler(operation: { await operation.run() }, onCancel: { operation.cancel() })
    }
}

private func serviceTimeout(_ value: TimeInterval) -> TimeInterval { value.isFinite ? max(0.05, min(value, 15)) : 5 }

private func serviceResult(status: DiagnosticRunStatus, evidence: ServiceProbeEvidence, source: String,
                           elapsed: TimeInterval? = nil) -> DiagnosticExecutionResult {
    let summary: String
    switch evidence.failure {
    case .invalidInput: summary = t("Enter a valid service host, port and absolute HTTP path.")
    case .tlsValidation: summary = t("TLS certificate or hostname validation failed.")
    case .tlsHandshake: summary = t("TLS handshake failed.")
    case .httpStatus: summary = tf("HTTP HEAD returned status %d", evidence.httpStatus ?? 0)
    case .timedOut: summary = t("Service check timed out.")
    case .cancelled: summary = t("Service check cancelled.")
    case .authenticationRequired: summary = t("HTTP authentication is required; no credentials were sent.")
    case .outputLimit: summary = t("HTTP response exceeded the diagnostic limit.")
    case .transport: summary = t("Service transport failed.")
    case nil: summary = source == "TLS" ? t("TLS handshake and trust verification succeeded.") : tf("HTTP HEAD returned status %d", evidence.httpStatus ?? 0)
    }
    return DiagnosticExecutionResult(status: status, summary: summary, detail: evidence.detail, latency: elapsed,
                                     source: source, evidence: DiagnosticRuntimeEvidence(service: evidence))
}

/// Every state transition, including pre-start cancellation, is serialized here.
private final class TLSProbeOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NETworkManager.TLSProbe")
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<DiagnosticExecutionResult, Never>?
    private var timer: DispatchWorkItem?
    private var cancelled = false
    private var startedAt = Date()

    init(host: String, port: UInt16, timeout: TimeInterval) {
        let tls = NWProtocolTLS.Options()
        // Preserve platform certificate-chain and hostname validation. No verify bypass.
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.timeout = timeout
    }

    func run() async -> DiagnosticExecutionResult {
        await withCheckedContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.finish(.cancelled, evidence: ServiceProbeEvidence(failure: .cancelled))
        }
    }

    private func start(_ continuation: CheckedContinuation<DiagnosticExecutionResult, Never>) {
        self.continuation = continuation
        startedAt = Date()
        guard !cancelled else { finish(.cancelled, evidence: ServiceProbeEvidence(failure: .cancelled)); return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var evidence = ServiceProbeEvidence(tlsVerified: true)
                if case .hostPort(let host, _) = self.connection.currentPath?.remoteEndpoint,
                   ServiceProbeEndpoint.isNumeric(String(describing: host)) {
                    evidence.peerAddress = String(describing: host)
                }
                if let metadata = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    evidence.tlsVersion = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata).rawValue
                    evidence.tlsCipherSuite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
                }
                self.finish(.succeeded, evidence: evidence)
            case .failed(let error), .waiting(let error):
                var evidence = ServiceProbeEvidence(failure: .transport)
                var status: DiagnosticRunStatus = .failed
                switch error {
                case .tls(let code):
                    evidence.errorCode = Int(code)
                    let trustCodes: [OSStatus] = [errSSLXCertChainInvalid, errSSLUnknownRootCert, errSSLNoRootCert,
                                                 errSSLCertExpired, errSSLHostNameMismatch, errSSLCertNotYetValid]
                    evidence.failure = trustCodes.contains(code) ? .tlsValidation : .tlsHandshake
                    evidence.tlsVerified = false
                case .posix(let code):
                    evidence.errorCode = Int(code.rawValue)
                    if code == .EACCES || code == .EPERM { status = .permissionDenied }
                    if code == .ENETUNREACH || code == .EHOSTUNREACH || code == .ENETDOWN { status = .unreachable }
                    if code == .ETIMEDOUT { status = .timedOut; evidence.failure = .timedOut }
                case .dns(let code): evidence.errorCode = Int(code)
                default: break
                }
                self.finish(status, evidence: evidence)
            case .cancelled: self.finish(.cancelled, evidence: ServiceProbeEvidence(failure: .cancelled))
            default: break
            }
        }
        let timer = DispatchWorkItem { [weak self] in self?.finish(.timedOut, evidence: ServiceProbeEvidence(failure: .timedOut)) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connection.start(queue: queue)
    }

    private func finish(_ status: DiagnosticRunStatus, evidence: ServiceProbeEvidence) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: serviceResult(status: status, evidence: evidence, source: "TLS", elapsed: Date().timeIntervalSince(startedAt)))
    }
}

private final class HTTPProbeOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "NETworkManager.HTTPProbe")
    private let url: URL
    private let timeout: TimeInterval
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<DiagnosticExecutionResult, Never>?
    private var timer: DispatchWorkItem?
    private var cancelled = false
    private var startedAt = Date()
    private var evidence = ServiceProbeEvidence()
    private var receivedBytes = 0

    init(url: URL, timeout: TimeInterval) { self.url = url; self.timeout = timeout }

    func run() async -> DiagnosticExecutionResult {
        await withCheckedContinuation { continuation in queue.async { self.start(continuation) } }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.evidence.failure = .cancelled
            self.finish(.cancelled)
        }
    }

    private func start(_ continuation: CheckedContinuation<DiagnosticExecutionResult, Never>) {
        self.continuation = continuation
        startedAt = Date()
        guard !cancelled else { evidence.failure = .cancelled; finish(.cancelled); return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        task = session?.dataTask(with: request)
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evidence.failure = .timedOut
            self.finish(.timedOut)
        }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        task?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        queue.async {
            self.evidence.httpStatus = response.statusCode
            self.evidence.redirectRefused = true
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        queue.async {
            self.evidence.failure = .authenticationRequired
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            self.evidence.httpStatus = (response as? HTTPURLResponse)?.statusCode
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            self.receivedBytes += data.count
            if self.receivedBytes > 16_384 { self.evidence.failure = .outputLimit; self.finish(.failed) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        queue.async {
            guard let metric = metrics.transactionMetrics.last else { return }
            self.evidence.peerAddress = metric.remoteAddress.flatMap { ServiceProbeEndpoint.isNumeric($0) ? $0 : nil }
            self.evidence.peerIsProxy = metric.isProxyConnection
            self.evidence.tlsVersion = metric.negotiatedTLSProtocolVersion?.rawValue
            self.evidence.tlsCipherSuite = metric.negotiatedTLSCipherSuite?.rawValue
            if self.url.scheme == "https", metric.secureConnectionEndDate != nil {
                self.evidence.tlsVerified = true
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard self.continuation != nil else { return }
            if self.evidence.failure == .authenticationRequired { self.finish(.failed); return }
            if let error = error as NSError? {
                self.evidence.errorCode = error.code
                var status: DiagnosticRunStatus = .failed
                self.evidence.failure = .transport
                if error.domain == NSURLErrorDomain {
                    switch error.code {
                    case NSURLErrorTimedOut: status = .timedOut; self.evidence.failure = .timedOut
                    case NSURLErrorCancelled: status = .cancelled; self.evidence.failure = .cancelled
                    case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost: status = .unreachable
                    case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                         NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                        self.evidence.failure = .tlsValidation; self.evidence.tlsVerified = false
                    case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                        self.evidence.failure = .tlsHandshake; self.evidence.tlsVerified = false
                    default: break
                    }
                }
                self.finish(status)
                return
            }
            if let code = self.evidence.httpStatus {
                if !(200...299).contains(code) { self.evidence.failure = .httpStatus }
                self.finish((200...299).contains(code) ? .succeeded : .failed)
                return
            }
            self.evidence.failure = .transport
            self.finish(.failed)
        }
    }

    private func finish(_ status: DiagnosticRunStatus) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(returning: serviceResult(status: status, evidence: evidence, source: "HTTP", elapsed: Date().timeIntervalSince(startedAt)))
    }
}
