import SwiftUI
import NMCore
import UniformTypeIdentifiers

/// Keychain-backed credential manager. The list displays only metadata; secret
/// values are entered into SecureField and are never rendered after saving.
public struct CredentialsView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var store = CredentialStore.shared
    @NMStateCompat private var showingAdd = false
    @NMStateCompat private var editingCredential: CredentialRef?
    @NMStateCompat private var message = ""
    @NMStateCompat private var showingBackupExporter = false
    @NMStateCompat private var showingRestoreImporter = false
    @NMStateCompat private var backupData = Data()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("Credentials")).font(.largeTitle.bold())
                Spacer()
                Button { exportReferences() } label: {
                    Label(t("Export credential references"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(store.recoveryError != nil || store.references.isEmpty)
                Button { showingAdd = true } label: {
                    Label(t("Add credential"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.recoveryError != nil)
            }
            Text(t("Secrets are stored in the macOS Keychain. This list contains references and metadata only."))
                .font(.callout)
                .foregroundStyle(palette.textSecondary)
            if let recoveryError = store.recoveryError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("Credential metadata needs recovery"))
                        .font(.headline)
                        .foregroundStyle(palette.danger)
                    Text(recoveryError)
                        .textSelection(.enabled)
                    Text(t("Reference backups contain metadata only and can be restored only while their Keychain items remain available on this Mac."))
                        .font(.callout)
                        .foregroundStyle(palette.textSecondary)
                    Button { showingRestoreImporter = true } label: {
                        Label(t("Restore credential references"), systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("restoreCredentialReferences")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            } else if store.references.isEmpty {
                ContentUnavailableView(t("No credentials"), systemImage: "key.fill", description: Text(t("Add a credential reference for a network device or service.")))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List {
                    ForEach(store.references) { ref in
                        credentialRow(ref)
                    }
                }
                .listStyle(.inset)
            }
            if let persistenceError = store.persistenceError {
                Text(persistenceError)
                    .font(.caption)
                    .foregroundStyle(palette.danger)
                    .textSelection(.enabled)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .background(palette.background)
        .sheet(isPresented: $showingAdd) {
            CredentialEditor { label, kind, account, secret in
                do {
                    guard let secret else { return }
                    _ = try store.create(label: label, kind: kind, account: account, secret: secret)
                    message = t("Credential saved to Keychain")
                    showingAdd = false
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .sheet(item: $editingCredential) { ref in
            CredentialEditor(existing: ref) { label, _, account, secret in
                do {
                    var updated = ref
                    updated.label = label
                    updated.account = account
                    try store.update(updated, secret: secret)
                    message = t("Credential updated")
                    editingCredential = nil
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: CredentialReferencesDocument(data: backupData),
            contentType: .json,
            defaultFilename: "NETworkManager-credential-references.json"
        ) { result in
            if case .failure(let error) = result {
                message = tf("Credential reference backup export failed: %@", error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showingRestoreImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { throw CredentialError.invalidReferenceBackup }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.restoreReferences(from: Data(contentsOf: url))
                message = t("Credential references restored.")
            } catch {
                message = tf("Credential reference import failed: %@", error.localizedDescription)
            }
        }
    }

    private func credentialRow(_ ref: CredentialRef) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: ref.kind))
                .foregroundStyle(palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(ref.label)
                Text(ref.account.isEmpty ? ref.kind.rawValue : "\(ref.kind.rawValue) · \(ref.account)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button { editingCredential = ref } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(t("Edit credential"))
            .accessibilityLabel(t("Edit credential"))
            Button {
                do {
                    try store.remove(ref)
                    message = t("Credential removed")
                } catch {
                    message = error.localizedDescription
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(t("Delete"))
            .accessibilityLabel(t("Delete credential"))
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(t("Delete"), role: .destructive) {
                do { try store.remove(ref); message = t("Credential removed") }
                catch { message = error.localizedDescription }
            }
        }
    }

    private func symbol(for kind: CredentialKind) -> String {
        switch kind {
        case .password: return "lock.fill"
        case .token: return "ticket.fill"
        case .snmp: return "antenna.radiowaves.left.and.right"
        case .sshKeyReference: return "key.fill"
        }
    }

    private func exportReferences() {
        do {
            backupData = try store.exportReferences()
            showingBackupExporter = true
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct CredentialReferencesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct CredentialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var label = ""
    @NMStateCompat private var account = ""
    @NMStateCompat private var kind: CredentialKind = .password
    @NMStateCompat private var username = ""
    @NMStateCompat private var password = ""
    @NMStateCompat private var privacyPassword = ""
    @NMStateCompat private var token = ""
    @NMStateCompat private var privateKeyPath = ""
    @NMStateCompat private var replaceSecret = true
    @NMStateCompat private var errorMessage = ""

    private let existing: CredentialRef?
    let save: (String, CredentialKind, String, CredentialSecret?) -> Void

    init(existing: CredentialRef? = nil, save: @escaping (String, CredentialKind, String, CredentialSecret?) -> Void) {
        self.existing = existing
        self.save = save
        _label = NMStateCompat(wrappedValue: existing?.label ?? "")
        _account = NMStateCompat(wrappedValue: existing?.account ?? "")
        _kind = NMStateCompat(wrappedValue: existing?.kind ?? .password)
        _replaceSecret = NMStateCompat(wrappedValue: existing == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(existing == nil ? "Add credential" : "Edit credential")).font(.title2.bold())
            TextField(t("Label"), text: $label)
                .textFieldStyle(.roundedBorder)
            Picker(t("Type"), selection: $kind) {
                ForEach(CredentialKind.allCases) { item in
                    Text(displayName(item)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .disabled(existing != nil)
            TextField(t("Account or username (optional)"), text: $account)
                .textFieldStyle(.roundedBorder)
            if existing != nil {
                Toggle(t("Replace secret in Keychain"), isOn: $replaceSecret)
            }
            if existing == nil || replaceSecret {
                secretFields
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(t("Save")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isSecretValid)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    @ViewBuilder
    private var secretFields: some View {
        switch kind {
        case .password:
            TextField(t("Username (optional)"), text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField(t("Password"), text: $password)
                .textFieldStyle(.roundedBorder)
        case .token:
            SecureField(t("API token"), text: $token)
                .textFieldStyle(.roundedBorder)
        case .snmp:
            SecureField(t("Authentication password or community"), text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField(t("Privacy password (SNMPv3 authPriv, optional)"), text: $privacyPassword)
                .textFieldStyle(.roundedBorder)
        case .sshKeyReference:
            TextField(t("Private key path"), text: $privateKeyPath)
                .textFieldStyle(.roundedBorder)
            Text(t("OpenSSH prompts for key passphrases in the terminal."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isSecretValid: Bool {
        if existing != nil && !replaceSecret { return true }
        switch kind {
        case .password, .snmp: return !password.isEmpty
        case .token: return !token.isEmpty
        case .sshKeyReference: return !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = t("Enter a label")
            return
        }
        guard isSecretValid else {
            errorMessage = t("Enter the required secret value")
            return
        }
        let secret: CredentialSecret?
        guard existing == nil || replaceSecret else {
            save(label.trimmingCharacters(in: .whitespacesAndNewlines), kind, account.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            return
        }
        switch kind {
        case .password: secret = CredentialSecret(username: username.isEmpty ? account : username, password: password)
        case .token: secret = CredentialSecret(token: token)
        case .snmp: secret = CredentialSecret(username: account.isEmpty ? nil : account, password: password, privacyPassword: privacyPassword.isEmpty ? nil : privacyPassword)
        case .sshKeyReference: secret = CredentialSecret(password: password.isEmpty ? nil : password, privateKeyPath: privateKeyPath)
        }
        save(label.trimmingCharacters(in: .whitespacesAndNewlines), kind, account.trimmingCharacters(in: .whitespacesAndNewlines), secret)
    }

    private func displayName(_ kind: CredentialKind) -> String {
        switch kind {
        case .password: return t("Password")
        case .token: return t("API token")
        case .snmp: return t("SNMP")
        case .sshKeyReference: return t("SSH key reference")
        }
    }
}
