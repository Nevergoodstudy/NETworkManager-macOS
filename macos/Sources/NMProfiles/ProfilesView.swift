import SwiftUI
import UniformTypeIdentifiers
import NMCore

public struct ProfilesView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var store = ProfileStore.shared
    @NMStateCompat private var selected: Profile?
    @NMStateCompat private var showingEditor = false
    @NMStateCompat private var showingImporter = false
    @NMStateCompat private var showingExporter = false
    @NMStateCompat private var showingImportPassword = false
    @NMStateCompat private var showingExportOptions = false
    @NMStateCompat private var pendingImportData = Data()
    @NMStateCompat private var exportEncrypted = false
    @NMStateCompat private var exportData = Data()
    @NMStateCompat private var message = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("Profiles")).font(.largeTitle.bold())
                Spacer()
                Button { selected = Profile(); showingEditor = true } label: { Label(t("Add"), systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(store.recoveryError != nil)
                Button(t("Import")) { showingImporter = true }.buttonStyle(.bordered)
                Button(t("Export")) { prepareExport() }.buttonStyle(.bordered).disabled(store.recoveryError != nil)
            }
            if let recoveryError = store.recoveryError {
                VStack(alignment: .leading, spacing: 10) {
                    Label(t("Profile recovery required"), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(recoveryError)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let preservedURL = store.preservedCorruptFileURL {
                        Text(tf("Damaged data copy: %@", preservedURL.path))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    Button { showingImporter = true } label: {
                        Label(t("Import profiles to recover"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1))
            } else if store.profiles.isEmpty {
                ContentUnavailableView(t("No profiles"), systemImage: "person.crop.rectangle.stack")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                List(selection: $selected) {
                    ForEach(store.groups, id: \.self) { group in
                        Section(group) {
                            ForEach(store.profiles(in: group)) { profileRow($0) }
                        }
                    }
                    let ungrouped = store.profiles.filter { $0.group.isEmpty }
                    if !ungrouped.isEmpty {
                        Section(t("General")) { ForEach(ungrouped) { profileRow($0) } }
                    }
                }
                .listStyle(.inset)
            }
            if let persistenceError = store.persistenceError {
                Text(persistenceError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(palette.textSecondary) }
        }
        .padding(28)
        .background(palette.background)
        .sheet(isPresented: $showingEditor) {
            if let selected { ProfileEditor(profile: selected) { value in store.upsert(value); showingEditor = false } }
        }
        .sheet(isPresented: $showingImportPassword) {
            ProfileImportOptions(data: pendingImportData) { password in
                do { try store.importJSON(pendingImportData, password: password.isEmpty ? nil : password); message = t("Imported"); showingImportPassword = false }
                catch { message = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showingExportOptions) {
            ProfileExportOptions { password in
                do {
                    exportEncrypted = !password.isEmpty
                    exportData = try store.exportJSON(encryptWith: password.isEmpty ? nil : password)
                    showingExportOptions = false
                    showingExporter = true
                } catch { message = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .xml, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                pendingImportData = try Data(contentsOf: url)
                showingImportPassword = true
            } catch {
                message = tf("Profile import failed: %@", error.localizedDescription)
            }
        }
        .fileExporter(isPresented: $showingExporter, document: ProfileDocument(data: exportData),
                      contentType: exportEncrypted ? .data : .json,
                      defaultFilename: exportEncrypted ? "NETworkManager-profiles.nme" : "NETworkManager-profiles.json") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack {
            Image(systemName: profile.proto.symbol).foregroundStyle(palette.accent)
            VStack(alignment: .leading) { Text(profile.name.isEmpty ? profile.host : profile.name); Text(profile.endpoint).font(.caption).foregroundStyle(palette.textSecondary) }
            Spacer(); Text(profile.proto.displayName).font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
        }
        .contentShape(Rectangle())
        .contextMenu { Button(t("Edit")) { selected = profile; showingEditor = true }; Button(t("Delete"), role: .destructive) { store.remove(profile) } }
        .onTapGesture(count: 2) { selected = profile; showingEditor = true }
    }

    private func prepareExport() {
        showingExportOptions = true
    }
}

private struct ProfileImportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var password = ""
    let data: Data
    let importData: (String) -> Void

    init(data: Data, importData: @escaping (String) -> Void) {
        self.data = data; self.importData = importData
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Import profiles")).font(.title.bold())
            Text(t("Leave the password empty for an unencrypted JSON/XML export."))
                .foregroundStyle(.secondary)
            SecureField(t("Password (optional)"), text: $password).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button(t("Cancel")) { dismiss() }.buttonStyle(.bordered); Button(t("Import")) { importData(password) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 420)
    }
}

private struct ProfileExportOptions: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var password = ""
    let exportData: (String) -> Void

    init(exportData: @escaping (String) -> Void) { self.exportData = exportData }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Export profiles")).font(.title.bold())
            Text(t("Enter a password to create an AES-GCM encrypted export. Leave it empty for JSON."))
                .foregroundStyle(.secondary)
            SecureField(t("Password (optional)"), text: $password).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button(t("Cancel")) { dismiss() }.buttonStyle(.bordered); Button(t("Export")) { exportData(password) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 460)
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var profile: Profile
    let save: (Profile) -> Void

    init(profile: Profile, save: @escaping (Profile) -> Void) { _profile = NMStateCompat(wrappedValue: profile); self.save = save }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile.name.isEmpty ? t("New profile") : t("Edit")).font(.title.bold())
            TextField(t("Name"), text: $profile.name).textFieldStyle(.roundedBorder)
            TextField(t("Group"), text: $profile.group).textFieldStyle(.roundedBorder)
            Picker(t("Protocol"), selection: $profile.proto) { ForEach(ConnectionProtocol.allCases) { Text($0.displayName).tag($0) } }.pickerStyle(.menu)
            TextField(t("Host"), text: $profile.host).textFieldStyle(.roundedBorder)
            TextField(t("Port"), value: $profile.port, format: .number).textFieldStyle(.roundedBorder)
            TextField(t("Username"), text: $profile.username).textFieldStyle(.roundedBorder)
            TextField(t("Notes"), text: $profile.notes, axis: .vertical).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button(t("Cancel")) { dismiss() }.buttonStyle(.bordered); Button(t("Save")) { save(profile) }.buttonStyle(.borderedProminent) }
        }
        .padding(24).frame(width: 430)
    }
}

private struct ProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
