import SwiftUI
import UniformTypeIdentifiers
import NMCore

public struct AssetsView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var store = AssetStore.shared
    @ObservedObject private var credentials = CredentialStore.shared
    @NMStateCompat private var searchText = ""
    @NMStateCompat private var selectedWorkspaceID = ""
    @NMStateCompat private var selectedDeviceID: UUID?
    @NMStateCompat private var editingSite: AssetSite?
    @NMStateCompat private var editingSubnet: AssetSubnet?
    @NMStateCompat private var addingSubnetToSite: AssetSite?
    @NMStateCompat private var pendingDeletion: AssetDeletion?
    @NMStateCompat private var showingAddWorkspace = false
    @NMStateCompat private var showingAddSite = false
    @NMStateCompat private var showingAddDevice = false
    @NMStateCompat private var showingBackupExporter = false
    @NMStateCompat private var showingBackupImporter = false
    @NMStateCompat private var backupData = Data()
    @NMStateCompat private var backupMessage = ""

    private enum AssetDeletion: Identifiable {
        case site(UUID)
        case subnet(UUID)

        var id: String {
            switch self {
            case .site(let id): return "site-\(id.uuidString)"
            case .subnet(let id): return "subnet-\(id.uuidString)"
            }
        }
    }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if let recoveryError = store.recoveryError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(t("Workspace recovery required"), systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(recoveryError)
                            .font(.caption)
                            .textSelection(.enabled)
                        if let preservedURL = store.preservedCorruptFileURL {
                            Text(tf("Damaged data copy: %@", preservedURL.path))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        Button {
                            showingBackupImporter = true
                        } label: {
                            Label(t("Import backup to recover"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
                } else if let persistenceError = store.persistenceError {
                    Label(persistenceError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(t("Search assets"), text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("assetSearch")
                }
                .padding(10)
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                    Picker(t("Workspace"), selection: $selectedWorkspaceID) {
                        ForEach(store.workspaces) { workspace in
                            Text(workspace.name).tag(workspace.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(t("Workspace"))
                    .accessibilityIdentifier("assetWorkspacePicker")
                    Menu {
                        Button { showingAddWorkspace = true } label: { Label(t("Add workspace"), systemImage: "plus") }
                        Button { showingAddSite = true } label: { Label(t("Add site"), systemImage: "mappin.and.ellipse") }
                            .disabled(activeWorkspace == nil || store.recoveryError != nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(t("Add workspace or site"))
                    .accessibilityLabel(t("Add workspace or site"))
                    .disabled(store.recoveryError != nil)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                Divider()
                List(selection: $selectedDeviceID) {
                    if let workspace = activeWorkspace {
                        Section {
                            Label(workspace.name, systemImage: "square.grid.2x2")
                                .font(.headline)
                            ForEach(store.sites(in: workspace.id)) { site in
                                Section {
                                    ForEach(store.subnets(in: site.id)) { subnet in
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(subnet.name)
                                                Text(subnet.cidr).font(.caption.monospaced()).foregroundStyle(.secondary)
                                            }
                                        } icon: {
                                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                        }
                                        .contextMenu {
                                            Button { editingSubnet = subnet } label: { Label(t("Edit subnet"), systemImage: "pencil") }
                                            Button(t("Delete"), role: .destructive) { pendingDeletion = .subnet(subnet.id) }
                                        }
                                    }
                                    ForEach(filteredDevices(in: site.id)) { device in
                                        Label {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(device.name)
                                                Text(deviceSubtitle(device)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        } icon: {
                                            Image(systemName: device.kind.symbol)
                                        }
                                        .tag(Optional(device.id))
                                    }
                                } header: {
                                    HStack {
                                        Label(site.name, systemImage: "mappin.and.ellipse")
                                        Spacer()
                                        Menu {
                                            Button { addingSubnetToSite = site } label: { Label(t("Add subnet"), systemImage: "plus") }
                                            Button { editingSite = site } label: { Label(t("Edit site"), systemImage: "pencil") }
                                            Button(t("Delete site"), role: .destructive) { pendingDeletion = .site(site.id) }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .help(t("Site actions"))
                                        .accessibilityLabel(tf("Actions for %@", site.name))
                                    }
                                }
                            }
                        } header: {
                            Text(t("Workspace"))
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationTitle(t("Assets"))
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button { exportBackup() } label: { Label(t("Export backup"), systemImage: "square.and.arrow.up") }
                            .disabled(store.recoveryError != nil)
                        Button { showingBackupImporter = true } label: { Label(t("Import backup"), systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help(t("Asset workspace actions"))
                    .accessibilityLabel(t("Asset workspace actions"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingAddDevice = true } label: { Label(t("Add device"), systemImage: "desktopcomputer.badge.plus") }
                        Button { showingAddSite = true } label: { Label(t("Add site"), systemImage: "mappin.and.ellipse") }
                    } label: {
                        Label(t("Add asset"), systemImage: "plus")
                    }
                    .help(t("Add asset"))
                    .accessibilityLabel(t("Add asset"))
                    .disabled(store.recoveryError != nil || activeWorkspace == nil)
                }
            }
            .sheet(isPresented: $showingAddDevice) {
                if let workspace = activeWorkspace {
                    AddDeviceSheet(workspaceID: workspace.id)
                }
            }
            .sheet(isPresented: $showingAddWorkspace) {
                WorkspaceEditorSheet { workspace in
                    store.upsert(workspace)
                    selectedWorkspaceID = workspace.id.uuidString
                }
            }
            .sheet(isPresented: $showingAddSite) {
                if let workspace = activeWorkspace {
                    SiteEditorSheet(workspaceID: workspace.id) { store.upsert($0) }
                }
            }
            .sheet(item: $editingSite) { site in
                SiteEditorSheet(site: site, workspaceID: site.workspaceID) { store.upsert($0) }
            }
            .sheet(item: $addingSubnetToSite) { site in
                SubnetEditorSheet(siteID: site.id) { store.upsert($0) }
            }
            .sheet(item: $editingSubnet) { subnet in
                SubnetEditorSheet(subnet: subnet, siteID: subnet.siteID) { store.upsert($0) }
            }
            .onAppear { selectDefaultWorkspaceIfNeeded() }
            .onChange(of: store.workspaces) { _, _ in selectDefaultWorkspaceIfNeeded() }
        } detail: {
            if let id = selectedDeviceID, let device = store.devices.first(where: { $0.id == id }) {
                DeviceInspector(device: device)
            } else {
                ContentUnavailableView(t("Select a device"), systemImage: "server.rack", description: Text(t("Choose an asset to inspect status and run diagnostics.")))
            }
        }
        .background(palette.background)
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: AssetBackupFile(data: backupData),
            contentType: .json,
            defaultFilename: "NETworkManager-assets-backup.json"
        ) { result in
            if case .failure(let error) = result { backupMessage = tf("Backup export failed: %@", error.localizedDescription) }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { throw AssetBackupError.emptyWorkspace }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.importBackup(Data(contentsOf: url))
                backupMessage = t("Asset backup imported.")
            } catch {
                backupMessage = tf("Backup import failed: %@", error.localizedDescription)
            }
        }
        .alert(t("Asset workspace"), isPresented: Binding(get: { !backupMessage.isEmpty }, set: { if !$0 { backupMessage = "" } })) {
            Button(t("OK"), role: .cancel) { backupMessage = "" }
        } message: {
            Text(backupMessage)
        }
        .confirmationDialog(t("Delete selected asset group?"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(t("Delete"), role: .destructive) { deletePendingAsset() }
            Button(t("Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletionMessage)
        }
    }

    private var activeWorkspace: OperationsWorkspace? {
        store.workspaces.first { $0.id.uuidString == selectedWorkspaceID } ?? store.primaryWorkspace
    }

    private var pendingDeletionMessage: String {
        guard let pendingDeletion else { return "" }
        switch pendingDeletion {
        case .site(let id):
            let count = store.devices.filter { device in
                device.siteID == id || store.subnets(in: id).contains { $0.id == device.subnetID }
            }.count
            return tf("Deleting this site removes %d devices and their diagnostic history.", count)
        case .subnet:
            return t("Deleting a subnet keeps its devices and clears their subnet association.")
        }
    }

    private func selectDefaultWorkspaceIfNeeded() {
        if store.workspaces.contains(where: { $0.id.uuidString == selectedWorkspaceID }) { return }
        selectedWorkspaceID = store.primaryWorkspace?.id.uuidString ?? ""
    }

    private func deviceSubtitle(_ device: AssetDevice) -> String {
        guard let subnetID = device.subnetID, let subnet = store.subnets.first(where: { $0.id == subnetID }) else {
            return device.address
        }
        return "\(device.address) · \(subnet.name)"
    }

    private func deletePendingAsset() {
        guard let pendingDeletion else { return }
        switch pendingDeletion {
        case .site(let id):
            if selectedDeviceID.map({ selected in store.devices.first(where: { $0.id == selected })?.siteID == id }) == true {
                selectedDeviceID = nil
            }
            store.removeSite(id: id)
        case .subnet(let id):
            store.removeSubnet(id: id)
        }
        self.pendingDeletion = nil
    }

    private func filteredDevices(in siteID: UUID) -> [AssetDevice] {
        store.searchDevices(searchText).filter { $0.siteID == siteID }
    }

    private func exportBackup() {
        do {
            backupData = try store.exportBackup()
            showingBackupExporter = true
        } catch {
            backupMessage = tf("Backup export failed: %@", error.localizedDescription)
        }
    }
}

private struct AssetBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DeviceInspector: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var store = AssetStore.shared
    @ObservedObject private var credentials = CredentialStore.shared
    let device: AssetDevice
    let rerun: DiagnosticRun?
    @NMStateCompat private var isPinging = false
    @NMStateCompat private var activeDiagnostic: DiagnosticKind?
    @NMStateCompat private var activeRunID: UUID?
    @NMStateCompat private var diagnosticTask: Task<Void, Never>?
    @NMStateCompat private var message = ""
    @NMStateCompat private var showingEvidenceExporter = false
    @NMStateCompat private var evidenceData = Data()
    @NMStateCompat private var evidenceIsMarkdown = true

    init(device: AssetDevice, rerun: DiagnosticRun? = nil) {
        self.device = device
        self.rerun = rerun
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(device.name, systemImage: device.kind.symbol).font(.largeTitle.bold())
                        Text(device.address).font(.title3.monospaced()).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                    }
                    Spacer()
                    diagnosticButton(kind: .ping, title: t("Ping"), icon: "waveform.path.ecg", identifier: "devicePing")
                }

                if let source = device.source, !source.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(tf("Source: %@", source), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let sourceFetchedAt = device.sourceFetchedAt {
                            LabeledContent(t("Last synced"), value: Fmt.dateTime(sourceFetchedAt))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("deviceSourceMetadata")
                }

                HStack(spacing: 10) {
                    info(title: t("Type"), value: device.kind.displayName, icon: device.kind.symbol)
                    info(title: t("Role"), value: device.role.isEmpty ? t("Unknown") : device.role, icon: "person.crop.rectangle")
                    info(title: t("Vendor"), value: device.vendor.isEmpty ? t("Unknown") : device.vendor, icon: "building.2")
                }

                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                }

                GroupBox(t("Quick diagnostics")) {
                    HStack(spacing: 8) {
                        diagnosticButton(kind: .dns, title: t("DNS"), icon: "magnifyingglass", identifier: "deviceDNS")
                        diagnosticButton(kind: .tcp, title: t("TCP 22"), icon: "rectangle.connected.to.line.below", identifier: "deviceTCP")
                        diagnosticButton(kind: .traceroute, title: t("Trace"), icon: "point.3.connected.trianglepath.dotted", identifier: "deviceTraceroute")
                        diagnosticButton(kind: .snmp, title: t("SNMP"), icon: "antenna.radiowaves.left.and.right", identifier: "deviceSNMP")
                        if activeDiagnostic != nil {
                            Button { diagnosticTask?.cancel() } label: { Label(t("Cancel"), systemImage: "xmark.circle") }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("cancelDiagnostic")
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t("Diagnostic history")).font(.headline)
                            Spacer()
                            Menu {
                                Button { exportEvidence(markdown: true) } label: { Label(t("Export Markdown"), systemImage: "doc.richtext") }
                                Button { exportEvidence(markdown: false) } label: { Label(t("Export JSON"), systemImage: "curlybraces.square") }
                            } label: {
                                Label(t("Export"), systemImage: "square.and.arrow.up")
                            }
                            .menuStyle(.borderlessButton)
                            .help(t("Export redacted diagnostic evidence"))
                            Text(tf("%d runs", store.runs(for: device.id).count)).font(.caption).foregroundStyle(.secondary)
                        }
                        if store.runs(for: device.id).isEmpty {
                            Text(t("No diagnostics have been run for this device."))
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(store.runs(for: device.id).prefix(12)) { run in
                                HStack(spacing: 10) {
                                    Image(systemName: statusSymbol(run.status))
                                        .foregroundStyle(statusColor(run.status))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(run.kind.displayName) · \(statusLabel(run.status)) · \(run.summary.isEmpty ? t("Running…") : run.summary)")
                                        Text(Fmt.dateTime(run.startedAt)).font(.caption).foregroundStyle(.secondary)
                                        Text(tf("Target: %@", run.target ?? device.address)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let latency = run.latency { Text(Fmt.ms(latency)).font(.caption.monospaced()) }
                                }
                                .padding(.vertical, 3)
                                .contextMenu {
                                    Button {
                                        runDiagnostic(run.kind, targetOverride: run.target ?? device.address, savedParameters: run.parameters)
                                    } label: {
                                        Label(t("Rerun with same parameters"), systemImage: "arrow.clockwise")
                                    }
                                    .disabled(activeDiagnostic != nil)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !device.notes.isEmpty {
                    GroupBox(t("Notes")) { Text(device.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }
            }
            .padding(26)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .background(palette.background)
        .task {
            guard let rerun else { return }
            runDiagnostic(rerun.kind, targetOverride: rerun.target, savedParameters: rerun.parameters)
        }
        .onDisappear { diagnosticTask?.cancel() }
        .fileExporter(
            isPresented: $showingEvidenceExporter,
            document: EvidenceDocument(data: evidenceData, isMarkdown: evidenceIsMarkdown),
            contentType: evidenceIsMarkdown ? .plainText : .json,
            defaultFilename: evidenceIsMarkdown ? "NETworkManager-\(device.name)-evidence.md" : "NETworkManager-\(device.name)-evidence.json"
        ) { _ in }
    }

    private func info(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
    }

    private func diagnosticButton(kind: DiagnosticKind, title: String, icon: String, identifier: String) -> some View {
        Button {
            runDiagnostic(kind)
        } label: {
            Label(activeDiagnostic == kind ? t("Running…") : title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .disabled(activeDiagnostic != nil)
        .accessibilityIdentifier(identifier)
    }

    fileprivate func runDiagnostic(_ kind: DiagnosticKind, targetOverride: String? = nil, savedParameters: [String: String] = [:]) {
        guard activeDiagnostic == nil else { return }
        activeDiagnostic = kind
        isPinging = true
        message = t("Running…")
        let target = targetOverride ?? device.address
        var parameters: [String: String]
        if savedParameters.isEmpty {
            switch kind {
            case .ping: parameters = ["timeout": "2.0"]
            case .dns: parameters = ["recordType": "A", "timeout": "3.0"]
            case .tcp: parameters = ["port": "22", "timeout": "2.0"]
            case .traceroute: parameters = ["maxHops": "16", "timeout": "45.0"]
            case .whois: parameters = ["server": "auto", "timeout": "10.0"]
            case .sntp: parameters = ["timeout": "3.0"]
            case .snmp:
                let reference = credentials.references.first { $0.id == device.credentialRefID && $0.kind == .snmp }
                let secret = reference.flatMap { try? credentials.secret(for: $0) }
                parameters = [
                    "oid": "1.3.6.1.2.1.1.1.0",
                    "version": secret?.username?.isEmpty == false ? "v3" : "v2c",
                    "authProtocol": "SHA-256",
                    "securityLevel": secret?.privacyPassword == nil ? "authNoPriv" : "authPriv",
                    "port": "161",
                    "timeout": "2.0"
                ]
                if let reference { parameters["credentialRefID"] = reference.id.uuidString }
            }
        } else {
            parameters = savedParameters
        }
        let timeout = Double(parameters["timeout"] ?? (kind == .dns ? "3.0" : kind == .traceroute ? "45.0" : "2.0")) ?? 2.0
        let defaultPort = kind == .snmp ? 161 : 22
        let port = Int(parameters["port"] ?? String(defaultPort)) ?? defaultPort
        let maxHops = Int(parameters["maxHops"] ?? "16") ?? 16
        let recordType = DNSRecordType.allCases.first { $0.displayName.caseInsensitiveCompare(parameters["recordType"] ?? "A") == .orderedSame } ?? .a
        let version = parameters["version"] ?? "v2c"
        let authProtocol = parameters["authProtocol"] ?? "SHA-256"
        let oid = parameters["oid"] ?? "1.3.6.1.2.1.1.1.0"
        let credentialRefID = UUID(uuidString: parameters["credentialRefID"] ?? "")
        let credentialRef = credentials.references.first { $0.id == credentialRefID && $0.kind == .snmp }
        let credentialSecret = credentialRef.flatMap { try? credentials.secret(for: $0) }
        let securityLevel = parameters["securityLevel"] ?? (credentialSecret?.privacyPassword == nil ? "authNoPriv" : "authPriv")
        let runID = store.beginDiagnostic(deviceID: device.id, kind: kind, target: target, parameters: parameters)
        activeRunID = runID
        let startedAt = Date()
        OperationsTelemetry.diagnosticStarted(kind: kind, runID: runID)
        diagnosticTask = Task {
            let result: DiagnosticExecutionResult
            switch kind {
            case .ping: result = await DiagnosticService.runPing(host: target, timeout: timeout)
            case .dns: result = await DiagnosticService.runDNS(host: target, recordType: recordType, timeout: timeout)
            case .tcp: result = await DiagnosticService.runTCP(host: target, port: port, timeout: timeout)
            case .traceroute: result = await DiagnosticService.runTraceroute(host: target, maxHops: maxHops, timeout: timeout)
            case .whois: result = await DiagnosticService.runWhois(host: target, server: parameters["server"] == "auto" ? nil : parameters["server"], timeout: timeout)
            case .sntp: result = await DiagnosticService.runSNTP(host: target, timeout: timeout)
            case .snmp: result = await DiagnosticService.runSNMP(host: target, port: port, timeout: timeout, oid: oid, version: version, authProtocol: authProtocol, securityLevel: securityLevel, credential: credentialSecret)
            }
            let finalResult = result
            await MainActor.run {
                store.finishDiagnostic(id: runID, status: finalResult.status, summary: finalResult.summary, detail: finalResult.detail, latency: finalResult.latency, source: finalResult.source, evidence: finalResult.evidence)
                OperationsTelemetry.diagnosticFinished(kind: kind, status: finalResult.status, runID: runID, duration: Date().timeIntervalSince(startedAt))
                message = finalResult.latency.map { tf("%@ · %@", finalResult.summary, Fmt.ms($0)) } ?? finalResult.summary
                activeDiagnostic = nil
                activeRunID = nil
                diagnosticTask = nil
                isPinging = false
            }
        }
    }

    private func statusSymbol(_ status: DiagnosticRunStatus) -> String {
        switch status {
        case .running: return "clock"
        case .succeeded: return "checkmark.circle.fill"
        case .interrupted: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        case .timedOut: return "clock.badge.exclamationmark"
        case .permissionDenied: return "lock.fill"
        case .unreachable: return "wifi.slash"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: DiagnosticRunStatus) -> Color {
        switch status {
        case .succeeded: return palette.success
        case .running, .interrupted, .timedOut, .cancelled: return palette.warning
        case .permissionDenied, .unreachable, .failed: return palette.danger
        }
    }

    private func statusLabel(_ status: DiagnosticRunStatus) -> String {
        switch status {
        case .running: return t("Running")
        case .succeeded: return t("Succeeded")
        case .interrupted: return t("Interrupted")
        case .failed: return t("Failed")
        case .cancelled: return t("Cancelled")
        case .timedOut: return t("Timed out")
        case .permissionDenied: return t("Permission denied")
        case .unreachable: return t("Unreachable")
        }
    }

    private func exportEvidence(markdown: Bool) {
        let runs = store.runs(for: device.id)
        do {
            evidenceIsMarkdown = markdown
            evidenceData = markdown
                ? Data(DiagnosticEvidenceExporter.markdown(runs: runs, devices: [device]).utf8)
                : try DiagnosticEvidenceExporter.json(runs: runs, devices: [device])
            showingEvidenceExporter = true
        } catch {
            message = tf("Export failed: %@", error.localizedDescription)
        }
    }
}

private struct EvidenceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var data: Data
    let isMarkdown: Bool

    init(data: Data, isMarkdown: Bool) {
        self.data = data
        self.isMarkdown = isMarkdown
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        isMarkdown = configuration.contentType == .plainText
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AssetStore.shared
    @ObservedObject private var credentials = CredentialStore.shared
    @NMStateCompat private var name = ""
    @NMStateCompat private var address = ""
    @NMStateCompat private var role = ""
    @NMStateCompat private var kind: AssetDeviceKind = .other
    @NMStateCompat private var selectedSiteID = ""
    @NMStateCompat private var selectedSubnetID = ""
    @NMStateCompat private var selectedCredentialID = ""
    private let workspaceID: UUID

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        _selectedSiteID = NMStateCompat(wrappedValue: AssetStore.shared.sites(in: workspaceID).first?.id.uuidString ?? "")
    }

    private var availableSites: [AssetSite] { store.sites(in: workspaceID) }
    private var availableSubnets: [AssetSubnet] {
        guard let siteID = UUID(uuidString: selectedSiteID) else { return [] }
        return store.subnets(in: siteID)
    }
    private var snmpCredentials: [CredentialRef] { credentials.references.filter { $0.kind == .snmp } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Add device")).font(.title2.bold())
            Form {
                TextField(t("Name"), text: $name)
                TextField(t("Address or hostname"), text: $address)
                Picker(t("Site"), selection: $selectedSiteID) {
                    ForEach(availableSites) { Text($0.name).tag($0.id.uuidString) }
                }
                .disabled(availableSites.isEmpty)
                .onChange(of: selectedSiteID) { _, _ in selectedSubnetID = "" }
                Picker(t("Subnet"), selection: $selectedSubnetID) {
                    Text(t("None")).tag("")
                    ForEach(availableSubnets) { Text("\($0.name) · \($0.cidr)").tag($0.id.uuidString) }
                }
                .disabled(availableSubnets.isEmpty)
                Picker(t("Type"), selection: $kind) { ForEach(AssetDeviceKind.allCases) { Text($0.displayName).tag($0) } }
                TextField(t("Role"), text: $role)
                Picker(t("Credential reference"), selection: $selectedCredentialID) {
                    Text(t("None")).tag("")
                    ForEach(snmpCredentials) { ref in
                        Text(ref.label).tag(ref.id.uuidString)
                    }
                }
                .disabled(snmpCredentials.isEmpty)
            }
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(availableSites.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        guard let site = availableSites.first(where: { $0.id.uuidString == selectedSiteID }) else { return }
        let subnetID = availableSubnets.first(where: { $0.id.uuidString == selectedSubnetID })?.id
        let credentialID = snmpCredentials.first(where: { $0.id.uuidString == selectedCredentialID })?.id
        store.upsert(AssetDevice(siteID: site.id, subnetID: subnetID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: address.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, role: role, credentialRefID: credentialID))
        dismiss()
    }
}

private struct WorkspaceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var name = ""
    let onSave: (OperationsWorkspace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Add workspace")).font(.title2.bold())
            TextField(t("Workspace name"), text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newWorkspaceName")
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Save")) {
                    let workspace = OperationsWorkspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    onSave(workspace)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct SiteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var name: String
    @NMStateCompat private var location: String
    @NMStateCompat private var notes: String
    let workspaceID: UUID
    let existingID: UUID?
    let onSave: (AssetSite) -> Void

    init(site: AssetSite? = nil, workspaceID: UUID, onSave: @escaping (AssetSite) -> Void) {
        self.workspaceID = workspaceID
        self.existingID = site?.id
        self.onSave = onSave
        _name = NMStateCompat(wrappedValue: site?.name ?? "")
        _location = NMStateCompat(wrappedValue: site?.location ?? "")
        _notes = NMStateCompat(wrappedValue: site?.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(existingID == nil ? "Add site" : "Edit site")).font(.title2.bold())
            Form {
                TextField(t("Name"), text: $name)
                TextField(t("Location"), text: $location)
                TextField(t("Notes"), text: $notes)
            }
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Save")) {
                    onSave(AssetSite(id: existingID ?? UUID(), workspaceID: workspaceID,
                                     name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     location: location.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 300)
    }
}

private struct SubnetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var name: String
    @NMStateCompat private var cidr: String
    @NMStateCompat private var purpose: String
    @NMStateCompat private var notes: String
    let siteID: UUID
    let existingID: UUID?
    let onSave: (AssetSubnet) -> Void

    init(subnet: AssetSubnet? = nil, siteID: UUID, onSave: @escaping (AssetSubnet) -> Void) {
        self.siteID = siteID
        self.existingID = subnet?.id
        self.onSave = onSave
        _name = NMStateCompat(wrappedValue: subnet?.name ?? "")
        _cidr = NMStateCompat(wrappedValue: subnet?.cidr ?? "")
        _purpose = NMStateCompat(wrappedValue: subnet?.purpose ?? "")
        _notes = NMStateCompat(wrappedValue: subnet?.notes ?? "")
    }

    private var normalizedCIDR: String? {
        let input = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subnet = IPv4Subnet(input) { return subnet.cidr }
        if let subnet = IPv6Subnet(input) { return subnet.description }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(existingID == nil ? "Add subnet" : "Edit subnet")).font(.title2.bold())
            Form {
                TextField(t("Name"), text: $name)
                TextField(t("CIDR"), text: $cidr)
                    .accessibilityIdentifier("subnetCIDR")
                TextField(t("Purpose"), text: $purpose)
                TextField(t("Notes"), text: $notes)
            }
            if !cidr.isEmpty && normalizedCIDR == nil {
                Label(t("Enter a valid IPv4 or IPv6 CIDR."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Save")) {
                    guard let normalizedCIDR else { return }
                    onSave(AssetSubnet(id: existingID ?? UUID(), siteID: siteID,
                                       name: name.trimmingCharacters(in: .whitespacesAndNewlines), cidr: normalizedCIDR,
                                       purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || normalizedCIDR == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 390)
    }
}
