import Foundation
import CryptoKit
import CommonCrypto
import Darwin

public enum SNMPv3AuthProtocol: Sendable, Equatable {
    case sha256
    case sha1

    fileprivate var authenticationParameterLength: Int {
        switch self {
        case .sha256: return 24
        case .sha1: return 12
        }
    }

}

private enum SNMPv3Crypto {
    static let passwordExpansionLength = 1_048_576

    static func passwordToKey(_ password: Data, protocol auth: SNMPv3AuthProtocol) throws -> Data {
        guard password.count >= 8 else { throw SNMPv3Error.invalidCredentials("SNMPv3 passwords must contain at least 8 octets.") }
        var expansion = Data()
        expansion.reserveCapacity(passwordExpansionLength)
        while expansion.count < passwordExpansionLength {
            let remaining = passwordExpansionLength - expansion.count
            expansion.append(password.prefix(remaining))
        }
        return digest(expansion, protocol: auth)
    }

    static func localize(_ key: Data, engineID: Data, protocol auth: SNMPv3AuthProtocol) throws -> Data {
        guard (5...32).contains(engineID.count) else { throw SNMPv3Error.invalidEngineID }
        var localized = Data()
        localized.reserveCapacity(key.count * 2 + engineID.count)
        localized.append(key)
        localized.append(engineID)
        localized.append(key)
        return digest(localized, protocol: auth)
    }

    static func passwordToLocalizedKey(_ password: Data, engineID: Data, protocol auth: SNMPv3AuthProtocol) throws -> Data {
        try localize(passwordToKey(password, protocol: auth), engineID: engineID, protocol: auth)
    }

    static func authenticationCode(_ message: Data, key: Data, protocol auth: SNMPv3AuthProtocol) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let code: Data
        switch auth {
        case .sha256:
            code = Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case .sha1:
            code = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        }
        return Data(code.prefix(auth.authenticationParameterLength))
    }

    private static func digest(_ data: Data, protocol auth: SNMPv3AuthProtocol) -> Data {
        switch auth {
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha1: return Data(Insecure.SHA1.hash(data: data))
        }
    }
}

public enum SNMPv3OfflineChecks {
    public static func run() throws {
        let engineID = Data(repeating: 0, count: 11) + Data([0x02])
        let password = Data("maplesyrup".utf8)
        let sha1Key = try SNMPv3Crypto.passwordToKey(password, protocol: .sha1)
        guard sha1Key == Data(hex: "9fb5cc0381497b3793528939ff788d5d79145211") else {
            throw SNMPv3Error.testFailure("RFC 3414 SHA-1 password-to-key Ku vector failed.")
        }
        let sha1Localized = try SNMPv3Crypto.passwordToLocalizedKey(password, engineID: engineID, protocol: .sha1)
        guard sha1Localized == Data(hex: "6695febc9288e36282235fc7151f128497b38f3f") else {
            throw SNMPv3Error.testFailure("RFC 3414 SHA-1 password-to-key vector failed.")
        }

        let hmacKey = Data(repeating: 0x0b, count: 20)
        let hmac = SNMPv3Crypto.authenticationCode(Data("Hi There".utf8), key: hmacKey, protocol: .sha256)
        guard hmac == Data(hex: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da7") else {
            throw SNMPv3Error.testFailure("RFC 7860 HMAC-SHA-256-192 vector failed.")
        }

        let iv = Data(repeating: 0x11, count: 16)
        let aesKey = Data(repeating: 0x22, count: 16)
        let plaintext = Data("scoped-pdu-roundtrip".utf8)
        let ciphertext = try SNMPv3Crypto.aesCFB(plaintext, key: aesKey, iv: iv, operation: CCOperation(kCCEncrypt))
        let decrypted = try SNMPv3Crypto.aesCFB(ciphertext, key: aesKey, iv: iv, operation: CCOperation(kCCDecrypt))
        guard decrypted == plaintext else { throw SNMPv3Error.testFailure("AES-128-CFB round trip failed.") }

        var engineClock = SNMPv3EngineClock()
        let initialTime = Date(timeIntervalSince1970: 1_000)
        guard try engineClock.synchronize(engineID: engineID, boots: 4, time: 20, at: initialTime) == .firstSync,
              engineClock.estimatedTime(at: Date(timeIntervalSince1970: 1_010)) == 30,
              engineClock.isWithinTimeWindow(boots: 4, time: 170, window: 150, at: initialTime),
              !engineClock.isWithinTimeWindow(boots: 4, time: 171, window: 150, at: initialTime),
              !engineClock.isWithinTimeWindow(boots: 5, time: 20, window: 150, at: initialTime),
              try engineClock.synchronize(engineID: engineID, boots: 5, time: 2, at: initialTime) == .restarted else {
            throw SNMPv3Error.testFailure("SNMPv3 authoritative engine clock checks failed.")
        }

        let timeoutConfiguration = SNMPv3Configuration(host: "127.0.0.1", username: "test", retries: 0)
        let timeoutClient = try SNMPv3Client(configuration: timeoutConfiguration, authenticationPassword: "auth-passphrase", transport: TimeoutTransport())
        do {
            _ = try timeoutClient.get("1.3.6.1.2.1.1.1.0")
            throw SNMPv3Error.testFailure("SNMPv3 timeout was not surfaced.")
        } catch SNMPv3Error.timeout {
        }

        for (reportOID, expectedError) in [
            ("1.3.6.1.6.3.15.1.1.3.0", "unknown-user"),
            ("1.3.6.1.6.3.15.1.1.5.0", "wrong-authentication")
        ] {
            let reportTransport = ReportTransport(engineID: engineID, reportOID: reportOID)
            let client = try SNMPv3Client(configuration: timeoutConfiguration, authenticationPassword: "auth-passphrase", transport: reportTransport)
            do {
                _ = try client.get("1.3.6.1.2.1.1.1.0")
                throw SNMPv3Error.testFailure("SNMPv3 \(expectedError) report was not surfaced.")
            } catch SNMPv3Error.unknownUser where expectedError == "unknown-user" {
            } catch SNMPv3Error.authenticationFailed where expectedError == "wrong-authentication" {
            }
        }
    }

    private struct TimeoutTransport: SNMPv3DatagramTransport {
        func exchange(_ packet: Data, host: String, port: Int, timeout: TimeInterval) throws -> Data { throw SNMPv3Error.timeout }
    }

    private struct ReportTransport: SNMPv3DatagramTransport {
        let engineID: Data
        let reportOID: String

        func exchange(_ packet: Data, host: String, port: Int, timeout: TimeInterval) throws -> Data {
            let request = try SNMPv3BER.parseMessage(packet)
            let requestID = try SNMPv3BER.parseScopedPDU(request.scopedPDU).requestID
            let oid = request.security.engineID.isEmpty ? "1.3.6.1.6.3.15.1.1.4.0" : reportOID
            let binding = SNMPv3BER.sequence(SNMPv3BER.oid(try SNMPv3BER.parseOID(oid)) + SNMPv3BER.integer(1, tag: 0x41))
            let reportPDU = SNMPv3BER.tlv(0xA8, SNMPv3BER.integer(requestID) + SNMPv3BER.integer(0) + SNMPv3BER.integer(0) + SNMPv3BER.sequence(binding))
            let scopedPDU = SNMPv3BER.sequence(SNMPv3BER.octets(engineID) + SNMPv3BER.octets(Data()) + reportPDU)
            return SNMPv3BER.message(messageID: request.messageID, pdu: scopedPDU, engineID: engineID, boots: 4, time: 20,
                                     username: Data(), authParameters: Data(), privacyParameters: Data(), flags: 0)
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

public enum SNMPv3Error: LocalizedError {
    case invalidCredentials(String)
    case invalidEngineID
    case timeout
    case transport(String)
    case malformed(String)
    case authenticationFailed
    case unknownUser
    case decryptionFailed
    case notInTimeWindow
    case engineRestarted
    case agent(String)
    case testFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials(let message), .transport(let message), .malformed(let message), .agent(let message), .testFailure(let message): return t(message)
        case .invalidEngineID: return t("The SNMPv3 authoritative engine ID is invalid.")
        case .timeout: return t("The SNMPv3 agent did not answer before the timeout.")
        case .authenticationFailed: return t("SNMPv3 authentication failed. Check the username and authentication password.")
        case .unknownUser: return t("The SNMPv3 agent does not recognize this user.")
        case .decryptionFailed: return t("The SNMPv3 agent could not decrypt the request. Check the privacy password and protocol.")
        case .notInTimeWindow: return t("SNMPv3 engine time is outside the accepted time window.")
        case .engineRestarted: return t("The SNMPv3 authoritative engine restarted; time synchronization is required.")
        }
    }
}

public final class SNMPv3Client: @unchecked Sendable {
    public let configuration: SNMPv3Configuration
    private let authenticationPassword: Data
    private let privacyPassword: Data?
    private let transport: any SNMPv3DatagramTransport
    private let lock = NSLock()
    private var clock = SNMPv3EngineClock()
    private var messageID = UInt32.random(in: 1...UInt32(Int32.max))
    private var requestID = Int32.random(in: 1...Int32.max)
    private var privacySalt: UInt64 = UInt64.random(in: 1...UInt64.max)

    public init(configuration: SNMPv3Configuration, authenticationPassword: String, privacyPassword: String? = nil,
                transport: any SNMPv3DatagramTransport = SNMPv3UDPTransport()) throws {
        guard !configuration.username.isEmpty, configuration.username.utf8.count <= 32 else {
            throw SNMPv3Error.invalidCredentials("SNMPv3 username must contain 1 to 32 UTF-8 octets.")
        }
        let auth = Data(authenticationPassword.utf8)
        guard auth.count >= 8 else { throw SNMPv3Error.invalidCredentials("Authentication password must contain at least 8 octets.") }
        if configuration.securityLevel == .authPriv {
            guard let privacyPassword, Data(privacyPassword.utf8).count >= 8 else {
                throw SNMPv3Error.invalidCredentials("Privacy password must contain at least 8 octets for authPriv.")
            }
        }
        self.configuration = configuration
        self.authenticationPassword = auth
        self.privacyPassword = privacyPassword.map { Data($0.utf8) }
        self.transport = transport
    }

    public func get(_ oid: String) throws -> SNMPv3Response {
        try request(pduTag: 0xA0, rootOID: oid, value: .null)
    }

    public func walk(_ rootOID: String, maxResults: Int = 500) throws -> [SNMPVarBind] {
        let root = try SNMPv3BER.parseOID(rootOID)
        var current = root
        var results: [SNMPVarBind] = []
        while results.count < maxResults {
            let response = try request(pduTag: 0xA1, rootOID: SNMPv3BER.formatOID(current), value: .null)
            guard let binding = response.varBinds.first,
                  let oid = try? SNMPv3BER.parseOID(binding.oid),
                  oid.count >= root.count, Array(oid.prefix(root.count)) == root,
                  oid != current else { break }
            results.append(binding)
            current = oid
        }
        return results
    }

    private func request(pduTag: UInt8, rootOID: String, value: SNMPValue) throws -> SNMPv3Response {
        let oid = try SNMPv3BER.parseOID(rootOID)
        let varBind = SNMPv3BER.sequence(SNMPv3BER.oid(oid) + SNMPv3BER.value(value))
        let bindings = SNMPv3BER.sequence(varBind)
        let start = Date()

        try discoverIfNeeded()
        var lastError: Error = SNMPv3Error.timeout
        for attempt in 0...(configuration.retries + 1) {
            let ids = nextIDs()
            let pdu = SNMPv3BER.tlv(pduTag, SNMPv3BER.integer(ids.request) + SNMPv3BER.integer(0) + SNMPv3BER.integer(0) + bindings)
            let packet = try makeMessage(messageID: ids.message, requestID: ids.request, pdu: pdu, reportable: true)
            do {
                let responseData = try transport.exchange(packet, host: configuration.host, port: configuration.port, timeout: configuration.timeout)
                let response = try parseResponse(responseData, expectedMessageID: ids.message, expectedRequestID: ids.request)
                if let report = response.report {
                    switch report {
                    case .unknownUser: throw SNMPv3Error.unknownUser
                    case .authenticationFailed: throw SNMPv3Error.authenticationFailed
                    case .decryptionFailed: throw SNMPv3Error.decryptionFailed
                    case .notInTimeWindow:
                        guard response.authenticated else {
                            throw SNMPv3Error.authenticationFailed
                        }
                        let update = try synchronize(from: response.security)
                        if update == .restarted { lastError = SNMPv3Error.engineRestarted }
                        else { lastError = SNMPv3Error.notInTimeWindow }
                        continue
                    case .unknownEngine:
                        invalidateEngineClock()
                        try discoverIfNeeded()
                        continue
                    case .other(let message): throw SNMPv3Error.agent(message)
                    }
                }
                guard let parsed = response.pdu else { throw SNMPv3Error.malformed("SNMPv3 response did not contain a response PDU.") }
                if parsed.errorStatus != 0 {
                    throw SNMPv3Error.agent(tf("SNMP agent error %d at index %d.", parsed.errorStatus, parsed.errorIndex))
                }
                return SNMPv3Response(requestID: ids.request, errorStatus: parsed.errorStatus, errorIndex: parsed.errorIndex,
                                      varBinds: parsed.bindings, elapsed: Date().timeIntervalSince(start))
            } catch let error as SNMPv3Error {
                lastError = error
                switch error {
                case .timeout, .transport:
                    if attempt == configuration.retries + 1 { throw error }
                case .engineRestarted, .notInTimeWindow:
                    if attempt == configuration.retries + 1 { throw error }
                default:
                    throw error
                }
            } catch {
                lastError = error
                if attempt == configuration.retries + 1 { throw error }
            }
        }
        throw lastError
    }

    private func discoverIfNeeded() throws {
        lock.lock()
        let isSynchronized = clock.engineID != nil
        lock.unlock()
        guard !isSynchronized else { return }

        var lastError: Error = SNMPv3Error.timeout
        for attempt in 0...configuration.retries {
            let ids = nextIDs()
            let discoveryBinding = SNMPv3BER.sequence(SNMPv3BER.oid([1, 3, 6, 1, 2, 1, 1, 1, 0]) + SNMPv3BER.null())
            let pdu = SNMPv3BER.tlv(0xA0, SNMPv3BER.integer(ids.request) + SNMPv3BER.integer(0) + SNMPv3BER.integer(0) + SNMPv3BER.sequence(discoveryBinding))
            let scopedPDU = SNMPv3BER.sequence(SNMPv3BER.octets(Data()) + SNMPv3BER.octets(Data()) + pdu)
            let packet = SNMPv3BER.message(messageID: ids.message, pdu: scopedPDU, engineID: Data(), boots: 0, time: 0,
                                           username: Data(), authParameters: Data(), privacyParameters: Data(), flags: 0x04)
            do {
                let data = try transport.exchange(packet, host: configuration.host, port: configuration.port, timeout: configuration.timeout)
                let response = try parseMessage(data, expectedMessageID: ids.message, expectedRequestID: nil)
                guard !response.security.engineID.isEmpty else { throw SNMPv3Error.malformed("SNMPv3 discovery response omitted the authoritative engine ID.") }
                _ = try synchronize(from: response.security)
                return
            } catch let error as SNMPv3Error {
                lastError = error
                guard attempt < configuration.retries, case .timeout = error else { throw error }
            } catch {
                lastError = error
                if attempt == configuration.retries { throw error }
            }
        }
        throw lastError
    }

    private func makeMessage(messageID: UInt32, requestID: Int32, pdu: Data, reportable: Bool) throws -> Data {
        lock.lock()
        guard let engineID = clock.engineID else { lock.unlock(); throw SNMPv3Error.invalidEngineID }
        let boots = clock.boots
        let engineTime = clock.estimatedTime()
        let authProtocol = configuration.authProtocol
        let level = configuration.securityLevel
        let salt = nextSaltLocked()
        lock.unlock()

        let authKey = try SNMPv3Crypto.passwordToLocalizedKey(authenticationPassword, engineID: engineID, protocol: authProtocol)
        let flags = UInt8((level == .authPriv ? 0x03 : 0x01) | (reportable ? 0x04 : 0))
        var privacyParameters = Data()
        var scopedPDU = SNMPv3BER.sequence(SNMPv3BER.octets(engineID) + SNMPv3BER.octets(Data()) + pdu)
        if level == .authPriv {
            guard let privacyPassword else { throw SNMPv3Error.invalidCredentials("Missing privacy password.") }
            let privacyKey = try SNMPv3Crypto.passwordToLocalizedKey(privacyPassword, engineID: engineID, protocol: authProtocol)
            let saltBytes = withUnsafeBytes(of: salt.bigEndian, Array.init)
            privacyParameters = Data(saltBytes)
            let iv = SNMPv3BER.uint32(boots) + SNMPv3BER.uint32(engineTime) + privacyParameters
            scopedPDU = try SNMPv3Crypto.aesCFB(scopedPDU, key: Data(privacyKey.prefix(16)), iv: iv, operation: CCOperation(kCCEncrypt))
        }
        let security = SNMPv3BER.usmParameters(engineID: engineID, boots: boots, time: engineTime, username: Data(configuration.username.utf8),
                                                authParameters: Data(repeating: 0, count: authProtocol.authenticationParameterLength), privacyParameters: privacyParameters)
        var message = SNMPv3BER.message(messageID: messageID, pdu: scopedPDU, engineID: engineID, boots: boots, time: engineTime,
                                        username: Data(configuration.username.utf8), authParameters: Data(repeating: 0, count: authProtocol.authenticationParameterLength),
                                        privacyParameters: privacyParameters, flags: flags, encodedSecurityParameters: security)
        let authentication = SNMPv3Crypto.authenticationCode(message, key: authKey, protocol: authProtocol)
        try SNMPv3BER.replaceAuthenticationParameters(&message, with: authentication)
        return message
    }

    private enum Report {
        case unknownEngine
        case unknownUser
        case authenticationFailed
        case decryptionFailed
        case notInTimeWindow
        case other(String)
    }

    private struct ParsedPDU {
        let errorStatus: Int
        let errorIndex: Int
        let bindings: [SNMPVarBind]
    }

    private struct ParsedMessage {
        let security: SNMPv3BER.SecurityParameters
        let authenticated: Bool
        let report: Report?
        let pdu: ParsedPDU?
    }

    private func parseResponse(_ data: Data, expectedMessageID: UInt32, expectedRequestID: Int32) throws -> ParsedMessage {
        let raw = try SNMPv3BER.parseMessage(data)
        let authenticated = raw.flags & 0x01 != 0
        if authenticated {
            guard raw.security.authParameters.count == configuration.authProtocol.authenticationParameterLength else {
                throw SNMPv3Error.authenticationFailed
            }
            var authenticatedMessage = raw.message
            authenticatedMessage.replaceSubrange(raw.authRange, with: Data(repeating: 0, count: raw.security.authParameters.count))
            let authKey = try SNMPv3Crypto.passwordToLocalizedKey(authenticationPassword, engineID: raw.security.engineID, protocol: configuration.authProtocol)
            let expected = SNMPv3Crypto.authenticationCode(authenticatedMessage, key: authKey, protocol: configuration.authProtocol)
            guard SNMPv3BER.constantTimeEqual(raw.security.authParameters, expected) else { throw SNMPv3Error.authenticationFailed }
        }
        let parsed = try parseMessage(data, expectedMessageID: expectedMessageID, expectedRequestID: expectedRequestID)
        if parsed.report == nil {
            guard authenticated, raw.security.username == Data(configuration.username.utf8) else {
                throw SNMPv3Error.authenticationFailed
            }
            guard (configuration.securityLevel == .authPriv) == (raw.flags & 0x02 != 0) else {
                throw SNMPv3Error.decryptionFailed
            }
            lock.lock()
            guard clock.engineID == raw.security.engineID else {
                lock.unlock()
                throw SNMPv3Error.invalidEngineID
            }
            let inWindow = clock.isWithinTimeWindow(boots: raw.security.boots, time: raw.security.time)
            let bootsChanged = clock.boots != raw.security.boots
            if !inWindow {
                do { _ = try clock.synchronize(engineID: raw.security.engineID, boots: raw.security.boots, time: raw.security.time) }
                catch { lock.unlock(); throw error }
            }
            lock.unlock()
            if bootsChanged { throw SNMPv3Error.engineRestarted }
            guard inWindow else { throw SNMPv3Error.notInTimeWindow }
        }
        return ParsedMessage(security: parsed.security, authenticated: authenticated, report: parsed.report, pdu: parsed.pdu)
    }

    private func parseMessage(_ data: Data, expectedMessageID: UInt32, expectedRequestID: Int32?) throws -> (security: SNMPv3BER.SecurityParameters, report: Report?, pdu: ParsedPDU?, messageForAuthentication: Data) {
        var parsed = try SNMPv3BER.parseMessage(data)
        guard parsed.messageID == expectedMessageID else { throw SNMPv3Error.malformed("Unexpected SNMPv3 message ID.") }
        var scopedPDU = parsed.scopedPDU
        if parsed.flags & 0x02 != 0 {
            guard configuration.securityLevel == .authPriv, let privacyPassword,
                  parsed.security.privacyParameters.count == 8 else { throw SNMPv3Error.decryptionFailed }
            let privacyKey = try SNMPv3Crypto.passwordToLocalizedKey(privacyPassword, engineID: parsed.security.engineID, protocol: configuration.authProtocol)
            let iv = SNMPv3BER.uint32(parsed.security.boots) + SNMPv3BER.uint32(parsed.security.time) + parsed.security.privacyParameters
            scopedPDU = try SNMPv3Crypto.aesCFB(scopedPDU, key: Data(privacyKey.prefix(16)), iv: iv, operation: CCOperation(kCCDecrypt))
        }
        parsed.message.replaceSubrange(parsed.authRange, with: Data(repeating: 0, count: parsed.security.authParameters.count))
        let scoped = try SNMPv3BER.parseScopedPDU(scopedPDU)
        let report = Self.classifyReport(scoped.bindings)
        if let expectedRequestID, scoped.requestID != expectedRequestID, report == nil {
            throw SNMPv3Error.malformed("Unexpected SNMPv3 request ID.")
        }
        return (parsed.security, report, report == nil ? ParsedPDU(errorStatus: scoped.errorStatus, errorIndex: scoped.errorIndex, bindings: scoped.bindings) : nil, parsed.message)
    }

    private static func classifyReport(_ bindings: [SNMPVarBind]) -> Report? {
        guard let first = bindings.first else { return nil }
        let oid = first.oid
        switch oid {
        case "1.3.6.1.6.3.15.1.1.4.0": return .unknownEngine
        case "1.3.6.1.6.3.15.1.1.3.0": return .unknownUser
        case "1.3.6.1.6.3.15.1.1.5.0": return .authenticationFailed
        case "1.3.6.1.6.3.15.1.1.6.0": return .decryptionFailed
        case "1.3.6.1.6.3.15.1.1.2.0": return .notInTimeWindow
        default: return .other("SNMPv3 agent returned a REPORT PDU for \(oid).")
        }
    }

    @discardableResult
    private func synchronize(from security: SNMPv3BER.SecurityParameters) throws -> SNMPv3EngineClock.Update {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clock.engineID, existing != security.engineID { throw SNMPv3Error.invalidEngineID }
        let update = try clock.synchronize(engineID: security.engineID, boots: security.boots, time: security.time)
        if update == .restarted { throw SNMPv3Error.engineRestarted }
        return update
    }

    private func nextIDs() -> (message: UInt32, request: Int32) {
        lock.lock()
        defer { lock.unlock() }
        messageID &+= 1
        requestID &+= 1
        return (messageID, requestID)
    }

    private func nextSaltLocked() -> UInt64 {
        privacySalt &+= 1
        return privacySalt
    }

    private func invalidateEngineClock() {
        lock.lock()
        clock = SNMPv3EngineClock()
        lock.unlock()
    }

}

public enum SNMPv3SecurityLevel: Sendable, Equatable {
    case authNoPriv
    case authPriv
}

public struct SNMPv3Configuration: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let authProtocol: SNMPv3AuthProtocol
    public let securityLevel: SNMPv3SecurityLevel
    public let timeout: TimeInterval
    public let retries: Int

    public init(host: String, port: Int = 161, username: String, authProtocol: SNMPv3AuthProtocol = .sha256,
                securityLevel: SNMPv3SecurityLevel = .authNoPriv, timeout: TimeInterval = 2, retries: Int = 1) {
        self.host = host
        self.port = max(1, min(port, 65_535))
        self.username = username
        self.authProtocol = authProtocol
        self.securityLevel = securityLevel
        self.timeout = max(0.1, timeout)
        self.retries = max(0, retries)
    }
}

public struct SNMPv3Response: Sendable {
    public let requestID: Int32
    public let errorStatus: Int
    public let errorIndex: Int
    public let varBinds: [SNMPVarBind]
    public let elapsed: TimeInterval

    public init(requestID: Int32, errorStatus: Int, errorIndex: Int, varBinds: [SNMPVarBind], elapsed: TimeInterval) {
        self.requestID = requestID
        self.errorStatus = errorStatus
        self.errorIndex = errorIndex
        self.varBinds = varBinds
        self.elapsed = elapsed
    }
}

public protocol SNMPv3DatagramTransport: Sendable {
    func exchange(_ packet: Data, host: String, port: Int, timeout: TimeInterval) throws -> Data
}

public struct SNMPv3UDPTransport: SNMPv3DatagramTransport {
    private let cancellation: DiagnosticCancellation?

    public init(cancellation: DiagnosticCancellation? = nil) { self.cancellation = cancellation }

    public func exchange(_ packet: Data, host: String, port: Int, timeout: TimeInterval) throws -> Data {
        let addresses: [ResolvedSocketAddress]
        do {
            addresses = try SocketAddressResolver.resolve(host, port: port, timeout: timeout,
                                                           cancellation: cancellation)
            guard !addresses.isEmpty else {
                throw SNMPv3Error.transport(tf("Cannot resolve SNMP host %@.", host))
            }
        } catch SocketAddressResolutionError.cancelled {
            throw SNMPv3Error.timeout
        } catch SocketAddressResolutionError.timedOut {
            throw SNMPv3Error.timeout
        } catch let error as SNMPv3Error {
            throw error
        } catch {
            throw SNMPv3Error.transport(tf("Cannot resolve SNMP host %@.", host))
        }
        if cancellation?.isCancelled == true { throw SNMPv3Error.timeout }

        for address in addresses {
            if cancellation?.isCancelled == true { throw SNMPv3Error.timeout }
            let fd = socket(address.family, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let connected = address.withSockAddr { Darwin.connect(fd, $0, $1) }
            guard connected == 0 else { continue }
            let sent = packet.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
            }
            guard sent == packet.count else { continue }
            guard waitForSocketReadiness(fd: fd, events: Int16(POLLIN), timeout: timeout, cancellation: cancellation) != nil else {
                if cancellation?.isCancelled == true { throw SNMPv3Error.timeout }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 65_535)
            let received = Darwin.recv(fd, &buffer, buffer.count, 0)
            if received >= 0 { return Data(buffer.prefix(received)) }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
        }
        throw SNMPv3Error.timeout
    }
}

private struct SNMPv3EngineClock: Sendable {
    enum Update: Equatable {
        case firstSync
        case synchronized
        case restarted
        case engineChanged
    }

    private(set) var engineID: Data?
    private(set) var boots: Int32 = 0
    private(set) var time: Int32 = 0
    private(set) var synchronizedAt: Date = .distantPast

    mutating func synchronize(engineID newEngineID: Data, boots newBoots: Int32, time newTime: Int32, at date: Date = Date()) throws -> Update {
        guard (5...32).contains(newEngineID.count), newBoots >= 0, newTime >= 0 else {
            throw SNMPv3Error.invalidEngineID
        }
        let update: Update
        if let engineID {
            if engineID != newEngineID {
                update = .engineChanged
            } else if boots != newBoots {
                update = .restarted
            } else {
                update = .synchronized
            }
        } else {
            update = .firstSync
        }
        engineID = newEngineID
        boots = newBoots
        time = newTime
        synchronizedAt = date
        return update
    }

    func estimatedTime(at date: Date = Date()) -> Int32 {
        guard synchronizedAt != .distantPast else { return 0 }
        let elapsed = max(0, Int64(date.timeIntervalSince(synchronizedAt)))
        return Int32(min(Int64(Int32.max), Int64(time) + elapsed))
    }

    func isWithinTimeWindow(boots remoteBoots: Int32, time remoteTime: Int32, window: Int64 = 150, at date: Date = Date()) -> Bool {
        guard remoteBoots == boots, remoteTime >= 0 else { return false }
        return abs(Int64(remoteTime) - Int64(estimatedTime(at: date))) <= window
    }
}

private enum SNMPv3BER {
    struct SecurityParameters {
        let engineID: Data
        let boots: Int32
        let time: Int32
        let username: Data
        let authParameters: Data
        let privacyParameters: Data
    }

    struct ParsedMessage {
        let messageID: UInt32
        let flags: UInt8
        let security: SecurityParameters
        let scopedPDU: Data
        var message: Data
        let authRange: Range<Int>
    }

    struct ScopedPDU {
        let requestID: Int32
        let errorStatus: Int
        let errorIndex: Int
        let bindings: [SNMPVarBind]
    }

    static func message(messageID: UInt32, pdu: Data, engineID: Data, boots: Int32, time: Int32,
                        username: Data, authParameters: Data, privacyParameters: Data, flags: UInt8,
                        encodedSecurityParameters: Data? = nil) -> Data {
        let header = sequence(integer(Int32(bitPattern: messageID)) + integer(65_535) + octets(Data([flags])) + integer(3))
        let security = encodedSecurityParameters ?? usmParameters(engineID: engineID, boots: boots, time: time,
                                                                   username: username, authParameters: authParameters,
                                                                   privacyParameters: privacyParameters)
        return sequence(integer(3) + header + security + pdu)
    }

    static func usmParameters(engineID: Data, boots: Int32, time: Int32, username: Data, authParameters: Data, privacyParameters: Data) -> Data {
        octets(sequence(octets(engineID) + integer(boots) + integer(time) + octets(username) + octets(authParameters) + octets(privacyParameters)))
    }

    static func parseMessage(_ data: Data) throws -> ParsedMessage {
        var outer = Reader(data)
        let message = try outer.read(expected: 0x30)
        var body = Reader(message.value, baseOffset: message.valueRange.lowerBound)
        guard try body.readInteger() == 3 else { throw SNMPv3Error.malformed("SNMPv3 message has an unsupported version.") }
        let header = try body.read(expected: 0x30)
        var headerReader = Reader(header.value, baseOffset: header.valueRange.lowerBound)
        let messageID = UInt32(bitPattern: try headerReader.readInteger())
        _ = try headerReader.readInteger()
        let flagsData = try headerReader.readOctets()
        guard flagsData.count == 1, let flags = flagsData.first else { throw SNMPv3Error.malformed("SNMPv3 message flags are invalid.") }
        guard flags & 0x02 == 0 || flags & 0x01 != 0 else { throw SNMPv3Error.malformed("SNMPv3 privacy flag requires authentication.") }
        guard try headerReader.readInteger() == 3 else { throw SNMPv3Error.malformed("SNMPv3 security model is not USM.") }

        let securityOctets = try body.read(expected: 0x04)
        var securityReader = Reader(securityOctets.value, baseOffset: securityOctets.valueRange.lowerBound)
        let usmSequence = try securityReader.read(expected: 0x30)
        var usm = Reader(usmSequence.value, baseOffset: usmSequence.valueRange.lowerBound)
        let engineID = try usm.readOctets()
        let boots = try usm.readInteger()
        let engineTime = try usm.readInteger()
        let username = try usm.readOctets()
        let auth = try usm.read(expected: 0x04)
        let privacy = try usm.readOctets()
        guard usm.isAtEnd, securityReader.isAtEnd else { throw SNMPv3Error.malformed("SNMPv3 security parameters contain trailing data.") }
        let scoped = try body.readAny([0x30, 0x04])
        let scopedPDU = scoped.tag == 0x04 ? scoped.value : scoped.encoded
        guard body.isAtEnd else { throw SNMPv3Error.malformed("SNMPv3 message contains trailing data.") }
        let parameters = SecurityParameters(engineID: engineID, boots: boots, time: engineTime, username: username,
                                            authParameters: auth.value, privacyParameters: privacy)
        return ParsedMessage(messageID: messageID, flags: flags, security: parameters, scopedPDU: scopedPDU,
                             message: data, authRange: auth.valueRange)
    }

    static func replaceAuthenticationParameters(_ message: inout Data, with value: Data) throws {
        let parsed = try parseMessage(message)
        guard parsed.authRange.count == value.count else { throw SNMPv3Error.malformed("Invalid SNMPv3 authentication parameter length.") }
        message.replaceSubrange(parsed.authRange, with: value)
    }

    static func parseScopedPDU(_ data: Data) throws -> ScopedPDU {
        var outer = Reader(data)
        let scoped = try outer.read(expected: 0x30)
        var reader = Reader(scoped.value, baseOffset: scoped.valueRange.lowerBound)
        _ = try reader.readOctets()
        _ = try reader.readOctets()
        let pdu = try reader.readAny([0xA0, 0xA1, 0xA2, 0xA8])
        var pduReader = Reader(pdu.value, baseOffset: pdu.valueRange.lowerBound)
        let requestID = try pduReader.readInteger()
        let status = Int(try pduReader.readInteger())
        let index = Int(try pduReader.readInteger())
        let list = try pduReader.read(expected: 0x30)
        guard pduReader.isAtEnd, reader.isAtEnd else { throw SNMPv3Error.malformed("SNMPv3 scoped PDU contains trailing data.") }
        var bindingsReader = Reader(list.value, baseOffset: list.valueRange.lowerBound)
        var bindings: [SNMPVarBind] = []
        while !bindingsReader.isAtEnd {
            let binding = try bindingsReader.read(expected: 0x30)
            var item = Reader(binding.value, baseOffset: binding.valueRange.lowerBound)
            let oid = try item.readOID()
            let value = try item.readValue()
            bindings.append(SNMPVarBind(oid: oid, value: value))
        }
        return ScopedPDU(requestID: requestID, errorStatus: status, errorIndex: index, bindings: bindings)
    }

    static func parseOID(_ string: String) throws -> [UInt32] {
        let components = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        let values = components.compactMap { UInt64($0) }
        guard values.count == components.count, values.count >= 2, values[0] <= 2,
              values[1] < 40 || values[0] == 2,
              values.allSatisfy({ $0 <= UInt64(UInt32.max) }) else { throw SNMPError.invalidOID }
        return values.map(UInt32.init)
    }

    static func formatOID(_ values: [UInt32]) -> String { values.map(String.init).joined(separator: ".") }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    static func integer(_ value: Int32, tag: UInt8 = 0x02) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1 && ((bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0)) { bytes.removeFirst() }
        return tlv(tag, Data(bytes))
    }

    static func uint32(_ value: Int32) -> Data { withUnsafeBytes(of: UInt32(bitPattern: value).bigEndian, Data.init) }
    static func null() -> Data { tlv(0x05, Data()) }
    static func octets(_ value: Data) -> Data { tlv(0x04, value) }
    static func sequence(_ value: Data) -> Data { tlv(0x30, value) }

    static func oid(_ values: [UInt32]) -> Data {
        guard values.count >= 2 else { return tlv(0x06, Data()) }
        var result = Data()
        appendBase128(UInt64(values[0]) * 40 + UInt64(values[1]), to: &result)
        for value in values.dropFirst(2) { appendBase128(UInt64(value), to: &result) }
        return tlv(0x06, result)
    }

    static func value(_ value: SNMPValue) -> Data {
        switch value {
        case .null: return null()
        case .integer(let value): return integer(value)
        case .unsigned(let value): return tlv(0x42, unsignedBytes(UInt64(value)))
        case .string(let value): return octets(Data(value.utf8))
        case .octets(let value): return octets(value)
        case .oid(let value): return (try? oid(parseOID(value))) ?? null()
        case .ipAddress(let value): return tlv(0x40, Data(value.split(separator: ".").compactMap { UInt8($0) }))
        case .counter64(let value): return tlv(0x46, unsignedBytes(value))
        case .exception: return tlv(0x82, Data())
        }
    }

    private static func unsignedBytes(_ value: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes.first ?? 0 >= 0x80 { bytes.insert(0, at: 0) }
        return Data(bytes)
    }

    private static func appendBase128(_ value: UInt64, to data: inout Data) {
        var chunks = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 { chunks.append(UInt8(remaining & 0x7F) | 0x80); remaining >>= 7 }
        data.append(contentsOf: chunks.reversed())
    }

    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var output = Data([tag])
        if value.count < 128 { output.append(UInt8(value.count)) }
        else {
            var length = value.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            output.append(0x80 | UInt8(bytes.count))
            output.append(contentsOf: bytes)
        }
        output.append(value)
        return output
    }

    private struct Reader {
        struct TLV {
            let tag: UInt8
            let value: Data
            let encoded: Data
            let valueRange: Range<Int>
            let tagOffset: Int
        }
        let bytes: [UInt8]
        let baseOffset: Int
        var offset = 0

        init(_ data: Data, baseOffset: Int = 0) { bytes = Array(data); self.baseOffset = baseOffset }
        var isAtEnd: Bool { offset == bytes.count }

        mutating func readAny(_ tags: [UInt8]) throws -> TLV {
            let item = try read()
            guard tags.contains(item.tag) else {
                let expected = tags.map { String(format: "%02X", $0) }.joined(separator: ", ")
                throw SNMPv3Error.malformed(String(format: "Unexpected SNMPv3 BER tag 0x%02X at byte %d; expected one of [%@].", item.tag, item.tagOffset, expected))
            }
            return item
        }

        mutating func read(expected tag: UInt8) throws -> TLV {
            let item = try read()
            guard item.tag == tag else {
                throw SNMPv3Error.malformed(String(format: "Unexpected SNMPv3 BER tag 0x%02X at byte %d; expected 0x%02X.", item.tag, item.tagOffset, tag))
            }
            return item
        }

        mutating func read() throws -> TLV {
            guard offset + 2 <= bytes.count else { throw SNMPv3Error.malformed("Truncated SNMPv3 BER value.") }
            let encodedStart = offset
            let tagOffset = baseOffset + encodedStart
            let tag = bytes[offset]
            offset += 1
            let first = bytes[offset]
            offset += 1
            let length: Int
            if first & 0x80 == 0 { length = Int(first) }
            else {
                let lengthBytes = Int(first & 0x7F)
                guard lengthBytes > 0, lengthBytes <= 4, offset + lengthBytes <= bytes.count else { throw SNMPv3Error.malformed("Invalid SNMPv3 BER length.") }
                length = bytes[offset..<(offset + lengthBytes)].reduce(0) { ($0 << 8) | Int($1) }
                offset += lengthBytes
            }
            guard length >= 0, offset + length <= bytes.count else { throw SNMPv3Error.malformed("SNMPv3 BER length exceeds packet size.") }
            let start = offset
            offset += length
            return TLV(tag: tag, value: Data(bytes[start..<offset]), encoded: Data(bytes[encodedStart..<offset]),
                       valueRange: (baseOffset + start)..<(baseOffset + offset), tagOffset: tagOffset)
        }

        mutating func readInteger() throws -> Int32 {
            let item = try read(expected: 0x02)
            guard !item.value.isEmpty, item.value.count <= 4 else { throw SNMPv3Error.malformed("Invalid SNMPv3 integer.") }
            var value: Int32 = item.value[0] & 0x80 == 0 ? 0 : -1
            for byte in item.value { value = (value << 8) | Int32(byte) }
            return value
        }

        mutating func readOctets() throws -> Data { try read(expected: 0x04).value }

        mutating func readOID() throws -> String {
            let item = try read(expected: 0x06)
            guard !item.value.isEmpty else { throw SNMPv3Error.malformed("Invalid SNMPv3 OID.") }
            var subidentifiers: [UInt64] = []
            var current: UInt64 = 0
            for byte in item.value {
                guard current <= UInt64.max >> 7 else { throw SNMPv3Error.malformed("SNMPv3 OID component overflow.") }
                current = (current << 7) | UInt64(byte & 0x7F)
                if byte & 0x80 == 0 { subidentifiers.append(current); current = 0 }
            }
            guard item.value.last! & 0x80 == 0, let firstValue = subidentifiers.first else { throw SNMPv3Error.malformed("Truncated SNMPv3 OID.") }
            let first: UInt64 = firstValue < 40 ? 0 : (firstValue < 80 ? 1 : 2)
            let second = firstValue - first * 40
            let remainder = subidentifiers.dropFirst()
            guard second <= UInt64(UInt32.max), remainder.allSatisfy({ $0 <= UInt64(UInt32.max) }) else {
                throw SNMPv3Error.malformed("SNMPv3 OID component overflow.")
            }
            return ([first, second] + remainder).map(String.init).joined(separator: ".")
        }

        mutating func readValue() throws -> SNMPValue {
            let item = try read()
            switch item.tag {
            case 0x02:
                guard !item.value.isEmpty, item.value.count <= 4 else { throw SNMPv3Error.malformed("Invalid SNMP integer value.") }
                var value: Int32 = item.value[0] & 0x80 == 0 ? 0 : -1
                for byte in item.value { value = (value << 8) | Int32(byte) }
                return .integer(value)
            case 0x04: return .string(String(decoding: item.value, as: UTF8.self))
            case 0x05: return .null
            case 0x06:
                var wrapped = Reader(tlv(0x06, item.value))
                return .oid(try wrapped.readOID())
            case 0x40: return .ipAddress(item.value.map(String.init).joined(separator: "."))
            case 0x41, 0x42, 0x43:
                return .unsigned(item.value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            case 0x46: return .counter64(item.value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            case 0x80: return .exception("noSuchObject")
            case 0x81: return .exception("noSuchInstance")
            case 0x82: return .exception("endOfMibView")
            default: return .octets(item.value)
            }
        }
    }
}

private extension SNMPv3Crypto {
    static func aesCFB(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw SNMPv3Error.malformed("AES-128-CFB requires a 16-byte key and IV.")
        }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(operation, CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw SNMPv3Error.decryptionFailed }
        defer { CCCryptorRelease(cryptor) }
        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(repeating: 0, count: outputCapacity)
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, outputCapacity, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { throw SNMPv3Error.decryptionFailed }
        var finalBytes = 0
        let finalStatus = output.withUnsafeMutableBytes { outputBytes in
            CCCryptorFinal(cryptor, outputBytes.baseAddress!.advanced(by: moved), outputCapacity - moved, &finalBytes)
        }
        guard finalStatus == kCCSuccess else { throw SNMPv3Error.decryptionFailed }
        output.count = moved + finalBytes
        return output
    }
}
