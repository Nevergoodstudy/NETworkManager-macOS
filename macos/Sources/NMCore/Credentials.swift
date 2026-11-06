import Foundation
import Security

public enum CredentialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case token
    case snmp
    case sshKeyReference

    public var id: String { rawValue }
}

/// Non-secret metadata that can be safely stored beside an asset.
public struct CredentialRef: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: CredentialKind
    public var account: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), label: String, kind: CredentialKind, account: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.kind = kind
        self.account = account
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CredentialSecret: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var privacyPassword: String?
    public var token: String?
    public var privateKeyPath: String?

    public init(username: String? = nil, password: String? = nil, privacyPassword: String? = nil, token: String? = nil, privateKeyPath: String? = nil) {
        self.username = username
        self.password = password
        self.privacyPassword = privacyPassword
        self.token = token
        self.privateKeyPath = privateKeyPath
    }
}

/// Minimal Keychain wrapper. The JSON metadata file never contains the secret
/// payload; it only stores CredentialRef values and UUID references.
public final class CredentialStore: ObservableObject {
    public static let shared = CredentialStore()
    public static let servicePrefix = "net.borntoberoot.networkmanager.credential"

    @Published public private(set) var references: [CredentialRef] = []
    @Published public private(set) var recoveryError: String?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var preservedCorruptFileURL: URL?
    private let metadataURL: URL
    private let initializationMarkerURL: URL

    private struct SecretPayload: Codable {
        var username: String?
        var password: String?
        var privacyPassword: String?
        var token: String?
        var privateKeyPath: String?
    }

    public init(metadataURL: URL? = nil) {
        let resolvedURL = metadataURL ?? SettingsStore.supportDirectory.appendingPathComponent("credentials.json")
        self.metadataURL = resolvedURL
        self.initializationMarkerURL = resolvedURL.appendingPathExtension("initialized")
        loadReferences()
    }

    public func create(label: String, kind: CredentialKind, account: String = "", secret: CredentialSecret) throws -> CredentialRef {
        try ensureWritable()
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else { throw CredentialError.invalidLabel }
        let ref = CredentialRef(label: normalizedLabel, kind: kind, account: account)
        try saveSecret(secret, for: ref.id)
        let updatedReferences = references + [ref]
        do {
            try persistReferences(updatedReferences)
        } catch {
            do {
                try deleteSecret(for: ref.id)
            } catch {
                persistenceError = tf("Credential was not saved and its temporary Keychain item could not be removed: %@", error.localizedDescription)
            }
            throw error
        }
        references = updatedReferences
        return ref
    }

    public func update(_ ref: CredentialRef, secret: CredentialSecret? = nil) throws {
        try ensureWritable()
        guard let index = references.firstIndex(where: { $0.id == ref.id }) else {
            throw CredentialError.referenceNotFound
        }
        var value = ref
        value.label = value.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.label.isEmpty else { throw CredentialError.invalidLabel }
        value.updatedAt = Date()
        var previousSecret: CredentialSecret?
        if let secret {
            previousSecret = try self.secret(for: references[index])
            try saveSecret(secret, for: value.id)
        }
        var updatedReferences = references
        updatedReferences[index] = value
        do {
            try persistReferences(updatedReferences)
        } catch {
            if let previousSecret {
                do {
                    try saveSecret(previousSecret, for: value.id)
                } catch {
                    persistenceError = tf("Credential metadata could not be saved and the previous Keychain value could not be restored: %@", error.localizedDescription)
                }
            }
            throw error
        }
        references = updatedReferences
    }

    public func secret(for ref: CredentialRef) throws -> CredentialSecret {
        guard let data = try keychainData(for: ref.id) else { throw CredentialError.notFound }
        let payload = try JSONDecoder().decode(SecretPayload.self, from: data)
        return CredentialSecret(username: payload.username, password: payload.password, privacyPassword: payload.privacyPassword, token: payload.token, privateKeyPath: payload.privateKeyPath)
    }

    public func remove(_ ref: CredentialRef) throws {
        try ensureWritable()
        guard references.contains(where: { $0.id == ref.id }) else { throw CredentialError.referenceNotFound }
        let updatedReferences = references.filter { $0.id != ref.id }
        try persistReferences(updatedReferences)
        do {
            try deleteSecret(for: ref.id)
        } catch {
            do {
                try persistReferences(references)
            } catch {
                persistenceError = tf("Credential metadata could not be restored after a failed Keychain deletion: %@", error.localizedDescription)
            }
            throw error
        }
        references = updatedReferences
    }

    public func loadReferences() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            references = []
            recoveryError = FileManager.default.fileExists(atPath: initializationMarkerURL.path)
                ? t("Credential metadata is missing, but Keychain items may still exist. Restore a valid reference backup before changing credentials.")
                : nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            recoveryError = tf("Credential metadata could not be read. The original file was preserved. Restore an exported reference backup. (%@)", error.localizedDescription)
            return
        }
        do {
            references = try Self.decodeReferences(data)
            recoveryError = nil
            persistenceError = nil
            do {
                try writeInitializationMarker()
            } catch {
                persistenceError = tf("Credential metadata marker could not be saved: %@", error.localizedDescription)
            }
        } catch {
            recoveryError = t("Credential metadata is damaged or invalid. The original file was preserved. Restore a valid reference backup.")
        }
    }

    public func exportReferences() throws -> Data {
        try ensureWritable()
        return try JSONEncoder().encode(references)
    }

    public func restoreReferences(from data: Data) throws {
        guard recoveryError != nil else { throw CredentialError.recoveryNotNeeded }
        let restoredReferences = try Self.decodeReferences(data)
        guard !restoredReferences.isEmpty else { throw CredentialError.invalidReferenceBackup }
        for ref in restoredReferences {
            do {
                _ = try secret(for: ref)
            } catch CredentialError.notFound {
                throw CredentialError.missingBackupSecret(ref.id.uuidString)
            }
        }

        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let suffix = String(UUID().uuidString.prefix(8))
            let preservedURL = metadataURL.deletingLastPathComponent()
                .appendingPathComponent("\(metadataURL.lastPathComponent).corrupt-\(timestamp)-\(suffix)")
            do {
                try FileManager.default.copyItem(at: metadataURL, to: preservedURL)
                preservedCorruptFileURL = preservedURL
            } catch {
                throw CredentialError.metadataBackup(error.localizedDescription)
            }
        }

        try persistReferences(restoredReferences)
        references = restoredReferences
        recoveryError = nil
        persistenceError = nil
    }

    private func ensureWritable() throws {
        guard recoveryError == nil else { throw CredentialError.recoveryRequired }
    }

    private static func decodeReferences(_ data: Data) throws -> [CredentialRef] {
        let values = try JSONDecoder().decode([CredentialRef].self, from: data)
        let ids = values.map(\.id)
        guard Set(ids).count == ids.count,
              values.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CredentialError.invalidReferenceBackup
        }
        return values
    }

    private func persistReferences(_ values: [CredentialRef]) throws {
        let metadataExisted = FileManager.default.fileExists(atPath: metadataURL.path)
        do {
            try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(values)
            try writeInitializationMarker()
            try data.write(to: metadataURL, options: .atomic)
            persistenceError = nil
        } catch {
            if !metadataExisted && references.isEmpty {
                try? FileManager.default.removeItem(at: initializationMarkerURL)
            }
            persistenceError = error.localizedDescription
            throw CredentialError.metadataWrite(error.localizedDescription)
        }
    }

    private func writeInitializationMarker() throws {
        guard !FileManager.default.fileExists(atPath: initializationMarkerURL.path) else { return }
        try Data("1".utf8).write(to: initializationMarkerURL, options: .atomic)
    }

    private func account(for id: UUID) -> String { id.uuidString }
    private func service(for id: UUID) -> String { "\(Self.servicePrefix).\(id.uuidString)" }

    private func saveSecret(_ secret: CredentialSecret, for id: UUID) throws {
        let payload = SecretPayload(username: secret.username, password: secret.password, privacyPassword: secret.privacyPassword, token: secret.token, privateKeyPath: secret.privateKeyPath)
        let data = try JSONEncoder().encode(payload)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: account(for: id),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookup: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service(for: id),
                kSecAttrAccount as String: account(for: id)
            ]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }

    private func keychainData(for id: UUID) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: account(for: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return result as? Data
    }

    private func deleteSecret(for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: account(for: id)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
}

public enum CredentialError: LocalizedError, Sendable {
    case notFound
    case invalidLabel
    case referenceNotFound
    case recoveryRequired
    case recoveryNotNeeded
    case invalidReferenceBackup
    case missingBackupSecret(String)
    case metadataWrite(String)
    case metadataBackup(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound: return t("Credential not found.")
        case .invalidLabel: return t("Enter a label")
        case .referenceNotFound: return t("Credential reference not found.")
        case .recoveryRequired: return t("Credential changes are disabled until metadata is restored.")
        case .recoveryNotNeeded: return t("Credential metadata recovery is not needed.")
        case .invalidReferenceBackup: return t("Credential reference backup is invalid.")
        case .missingBackupSecret(let id): return tf("The backup refers to a Keychain item that is unavailable: %@", id)
        case .metadataWrite(let message): return tf("Credential metadata could not be saved: %@", message)
        case .metadataBackup(let message): return tf("Credential metadata backup could not be preserved: %@", message)
        case .keychain(let status): return tf("Keychain operation failed (%d).", status)
        }
    }
}
