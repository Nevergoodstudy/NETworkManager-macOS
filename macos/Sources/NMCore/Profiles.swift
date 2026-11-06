import Foundation
import CryptoKit

// MARK: - Connection protocols

public enum ConnectionProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case ssh, telnet, rdp, vnc, http, https, snmp

    public var id: String { rawValue }

    public var displayName: String { rawValue.uppercased() }

    public var defaultPort: Int {
        switch self {
        case .ssh: return 22
        case .telnet: return 23
        case .rdp: return 3389
        case .vnc: return 5900
        case .http: return 80
        case .https: return 443
        case .snmp: return 161
        }
    }

    public var symbol: String {
        switch self {
        case .ssh: return "terminal"
        case .telnet: return "network"
        case .rdp: return "display"
        case .vnc: return "rectangle.on.rectangle"
        case .http, .https: return "globe"
        case .snmp: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Profile model

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String
    public var host: String
    public var port: Int
    public var proto: ConnectionProtocol
    public var username: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String = "",
                group: String = "",
                host: String = "",
                port: Int = 22,
                proto: ConnectionProtocol = .ssh,
                username: String = "",
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.proto = proto
        self.username = username
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var endpoint: String { "\(host):\(port)" }
}

// MARK: - Store

/// Profile storage compatible with an export/import flow and optional password
/// based encryption (AES-GCM, key derived with HKDF-SHA256).
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public private(set) var profiles: [Profile] = []
    @Published public private(set) var groups: [String] = []
    @Published public private(set) var recoveryError: String?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var preservedCorruptFileURL: URL?

    private static var defaultFileURL: URL {
        SettingsStore.supportDirectory.appendingPathComponent("profiles.json")
    }

    private let storageURL: URL

    private struct Payload: Codable {
        var profiles: [Profile]
        var groups: [String]
    }

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultFileURL
        load()
    }

    // MARK: CRUD

    public func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            profiles = payload.profiles
            groups = payload.groups
        } catch {
            recoveryError = t("Profile data is damaged or from an unsupported format. The original file was preserved. Import a valid profile export to recover this library.")
        }
    }

    public func save() {
        guard recoveryError == nil else { return }
        let payload = Payload(profiles: profiles, groups: groups)
        do {
            try write(payload)
            persistenceError = nil
        } catch {
            persistenceError = tf("Profile library could not be saved: %@", error.localizedDescription)
        }
    }

    public func upsert(_ profile: Profile) {
        var p = profile
        p.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
        if !p.group.isEmpty, !groups.contains(p.group) { groups.append(p.group) }
        save()
    }

    public func remove(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    public func addGroup(_ name: String) {
        guard !name.isEmpty, !groups.contains(name) else { return }
        groups.append(name)
        save()
    }

    public func removeGroup(_ name: String) {
        groups.removeAll { $0 == name }
        profiles.removeAll { $0.group == name }
        save()
    }

    public func profiles(in group: String) -> [Profile] {
        profiles.filter { $0.group == group }
    }

    // MARK: Import / export

    public func exportJSON(encryptWith password: String?) throws -> Data {
        let payload = Payload(profiles: profiles, groups: groups)
        let json = try JSONEncoder().encode(payload)
        guard let password, !password.isEmpty else { return json }
        return try ProfileCrypto.encrypt(json, password: password)
    }

    public func importJSON(_ data: Data, password: String?) throws {
        let previousProfiles = profiles
        let previousGroups = groups
        let isRecovering = recoveryError != nil
        var json = data
        do {
            if ProfileCrypto.isEncrypted(data) {
                guard let password else { throw ProfileError.passwordRequired }
                json = try ProfileCrypto.decrypt(data, password: password)
            }
            if let payload = try? JSONDecoder().decode(Payload.self, from: json) {
                merge(payload.profiles, groups: payload.groups)
            } else if !importWindowsProfileJSON(json) && !importWindowsProfileXML(json) {
                throw ProfileError.invalidFile
            }
            if isRecovering, FileManager.default.fileExists(atPath: storageURL.path) {
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let preservedURL = storageURL.deletingLastPathComponent()
                    .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(timestamp)")
                try FileManager.default.copyItem(at: storageURL, to: preservedURL)
                preservedCorruptFileURL = preservedURL
            }
            try write(Payload(profiles: profiles, groups: groups))
            recoveryError = nil
            persistenceError = nil
        } catch {
            profiles = previousProfiles
            groups = previousGroups
            throw error
        }
    }

    private func write(_ payload: Payload) throws {
        let data = try JSONEncoder().encode(payload)
        try data.write(to: storageURL, options: .atomic)
    }

    public enum ProfileError: LocalizedError {
        case passwordRequired
        case decryptionFailed
        case invalidFile

        public var errorDescription: String? {
            switch self {
            case .passwordRequired: return t("This profile file is encrypted. Enter the password to import it.")
            case .decryptionFailed: return t("The password is wrong or the file is corrupted.")
            case .invalidFile: return t("This profile file is not a supported NETworkManager or Windows profile export.")
            }
        }
    }

    private func merge(_ importedProfiles: [Profile], groups importedGroups: [String]) {
        for profile in importedProfiles {
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[idx] = profile }
            else { profiles.append(profile) }
        }
        for group in importedGroups where !groups.contains(group) { groups.append(group) }
    }

    /// Windows exports use a `Groups` array with the larger ProfileInfo schema.
    /// Keep the portable inventory fields and map each enabled Windows tool to
    /// the closest macOS protocol so an existing profile library remains useful.
    private func importWindowsProfileJSON(_ data: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: data)
        let groupsValue: [[String: Any]]
        if let root = object as? [String: Any], let groups = root["Groups"] as? [[String: Any]] {
            groupsValue = groups
        } else if let groups = object as? [[String: Any]] {
            // Legacy Windows exports serialized GroupInfoSerializable directly
            // as an array instead of using the ProfileFileData wrapper.
            groupsValue = groups
        } else {
            return false
        }
        var imported: [Profile] = []
        var importedGroups: [String] = []
        for group in groupsValue {
            let groupName = (group["Name"] as? String) ?? ""
            if !groupName.isEmpty { importedGroups.append(groupName) }
            guard let profileValues = group["Profiles"] as? [[String: Any]] else { continue }
            for value in profileValues {
                guard let name = value["Name"] as? String else { continue }
                let host = firstString(value, ["Host", "RemoteDesktop_Host", "PowerShell_Host", "PuTTY_HostOrSerialLine", "TigerVNC_Host", "SNMP_Host", "IPGeolocation_Host", "WebConsole_Url"]) ?? ""
                let mapped = mapWindowsProtocol(value)
                let port = firstInt(value, mapped.portKeys) ?? mapped.proto.defaultPort
                imported.append(Profile(name: name, group: groupName, host: host, port: port,
                                        proto: mapped.proto,
                                        username: firstString(value, ["RemoteDesktop_Username", "PuTTY_Username", "SNMP_Username"]) ?? "",
                                        notes: firstString(value, ["Description"]) ?? ""))
            }
        }
        guard !imported.isEmpty else { return false }
        merge(imported, groups: importedGroups)
        return true
    }

    private func firstString(_ value: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = value[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private func firstInt(_ value: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let number = value[key] as? NSNumber { return number.intValue }
            if let text = value[key] as? String, let number = Int(text) { return number }
        }
        return nil
    }

    private func mapWindowsProtocol(_ value: [String: Any]) -> (proto: ConnectionProtocol, portKeys: [String]) {
        if (value["SNMP_Enabled"] as? Bool == true) || value["SNMP_Host"] != nil { return (.snmp, ["SNMP_Port"]) }
        if (value["TigerVNC_Enabled"] as? Bool == true) || value["TigerVNC_Host"] != nil { return (.vnc, ["TigerVNC_Port"]) }
        if (value["RemoteDesktop_Enabled"] as? Bool == true) || value["RemoteDesktop_Host"] != nil { return (.rdp, ["RemoteDesktop_Port"]) }
        if (value["WebConsole_Enabled"] as? Bool == true) || value["WebConsole_Url"] != nil {
            let url = (value["WebConsole_Url"] as? String)?.lowercased() ?? ""
            return (url.hasPrefix("https") ? .https : .http, [])
        }
        if (value["PuTTY_Enabled"] as? Bool == true) || value["PuTTY_HostOrSerialLine"] != nil {
            let mode = String(describing: value["PuTTY_ConnectionMode"] ?? "").lowercased()
            return (mode.contains("telnet") ? .telnet : .ssh, ["PuTTY_PortOrBaud"])
        }
        return (.ssh, [])
    }

    private func importWindowsProfileXML(_ data: Data) -> Bool {
        let delegate = LegacyProfileXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.profiles.isEmpty else { return false }
        var imported: [Profile] = []
        var groupNames: [String] = []
        for record in delegate.profiles {
            let mapped = mapWindowsProtocol(record.values)
            let host = firstString(record.values, ["Host", "RemoteDesktop_Host", "PowerShell_Host", "PuTTY_HostOrSerialLine", "TigerVNC_Host", "SNMP_Host", "IPGeolocation_Host", "WebConsole_Url"]) ?? ""
            let group = record.group
            if !group.isEmpty && !groupNames.contains(group) { groupNames.append(group) }
            imported.append(Profile(name: firstString(record.values, ["Name"]) ?? host,
                                    group: group, host: host,
                                    port: firstInt(record.values, mapped.portKeys) ?? mapped.proto.defaultPort,
                                    proto: mapped.proto,
                                    username: firstString(record.values, ["RemoteDesktop_Username", "PuTTY_Username", "SNMP_Username"]) ?? "",
                                    notes: firstString(record.values, ["Description"]) ?? ""))
        }
        guard !imported.isEmpty else { return false }
        merge(imported, groups: groupNames)
        return true
    }
}

private final class LegacyProfileXMLDelegate: NSObject, XMLParserDelegate {
    struct Record { let group: String; let values: [String: Any] }
    var profiles: [Record] = []
    private var groupName = ""
    private var profileValues: [String: Any]?
    private var currentElement = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        text = ""
        if elementName == "ProfileInfoSerializable" || elementName == "ProfileInfo" { profileValues = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "ProfileInfoSerializable" || elementName == "ProfileInfo" {
            if let profileValues { profiles.append(Record(group: groupName, values: profileValues)) }
            profileValues = nil
        } else if !value.isEmpty {
            if profileValues != nil { profileValues?[elementName] = value }
            else if elementName == "Name" { groupName = value }
        }
        currentElement = ""
        text = ""
    }
}

// MARK: - Crypto

public enum ProfileCrypto {
    private static let legacyMagic = Data("NME1".utf8)
    private static let currentMagic = Data("NME2".utf8)
    private static let saltLength = 16
    private static let currentIterationCount: UInt32 = 120_000

    public static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: legacyMagic) || data.starts(with: currentMagic)
    }

    public static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = randomBytes(saltLength)
        let key = derivePasswordKey(password: password, salt: salt, iterations: currentIterationCount)
        let nonce = try AES.GCM.Nonce(data: randomBytes(12))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var result = currentMagic + salt
        var iterations = currentIterationCount.bigEndian
        withUnsafeBytes(of: &iterations) { result.append(contentsOf: $0) }
        result.append(contentsOf: sealed.combined!)
        return result
    }

    public static func decrypt(_ data: Data, password: String) throws -> Data {
        guard isEncrypted(data) else {
            throw ProfileStore.ProfileError.decryptionFailed
        }
        let key: SymmetricKey
        let payload: Data
        if data.starts(with: currentMagic) {
            guard data.count > currentMagic.count + saltLength + 4 else {
                throw ProfileStore.ProfileError.decryptionFailed
            }
            let saltStart = currentMagic.count
            let iterationStart = saltStart + saltLength
            let iterationBytes = Array(data[iterationStart..<(iterationStart + 4)])
            let iterations = (UInt32(iterationBytes[0]) << 24) |
                (UInt32(iterationBytes[1]) << 16) |
                (UInt32(iterationBytes[2]) << 8) |
                UInt32(iterationBytes[3])
            guard iterations >= 10_000, iterations <= 2_000_000 else {
                throw ProfileStore.ProfileError.decryptionFailed
            }
            let salt = Data(data[saltStart..<iterationStart])
            payload = Data(data[(iterationStart + 4)...])
            key = derivePasswordKey(password: password, salt: salt, iterations: iterations)
        } else {
            guard data.count > legacyMagic.count + saltLength else {
                throw ProfileStore.ProfileError.decryptionFailed
            }
            let body = data.dropFirst(legacyMagic.count)
            let salt = Data(body.prefix(saltLength))
            payload = Data(body.dropFirst(saltLength))
            key = deriveLegacyKey(password: password, salt: salt)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw ProfileStore.ProfileError.decryptionFailed
        }
    }

    private static func deriveLegacyKey(password: String, salt: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(password.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("NETworkManager-Mac-Profiles".utf8),
            outputByteCount: 32
        )
    }

    private static func derivePasswordKey(password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var indexedSalt = salt
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { indexedSalt.append(contentsOf: $0) }

        var u = Data(HMAC<SHA256>.authenticationCode(for: indexedSalt, using: passwordKey))
        var block = [UInt8](u)
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                for index in block.indices { block[index] ^= u[index] }
            }
        }
        return SymmetricKey(data: Data(block))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
