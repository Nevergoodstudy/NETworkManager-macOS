import SwiftUI
import NMCore
import NMAssets

extension NetBoxDeviceRecord: Identifiable {}

private struct NetBoxImportCandidate: Identifiable {
    let record: NetBoxDeviceRecord
    let snapshot: ExternalAssetSnapshot?
    let duplicateInResponse: Bool

    var id: Int { record.id }
}

/// Settings surface for a single read-only NetBox source.
///
/// Only the base URL and Keychain credential reference are persisted. The
/// secret is loaded immediately before a request and never copied into view
/// state or settings storage.
public struct NetBoxView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @ObservedObject private var assets = AssetStore.shared

    @NMStateCompat private var baseURLText: String
    @NMStateCompat private var selectedCredentialID: String
    @NMStateCompat private var isWorking = false
    @NMStateCompat private var statusMessage = ""
    @NMStateCompat private var statusKind: StatusKind = .idle
    @NMStateCompat private var lastTestAt: Date?
    @NMStateCompat private var syncResult: NetBoxSyncResult?
    @NMStateCompat private var importCandidates: [NetBoxImportCandidate] = []
    @NMStateCompat private var selectedImportIDs: Set<Int> = []
    @NMStateCompat private var showingImportConfirmation = false

    private enum StatusKind {
        case idle
        case running
        case preview
        case success
        case warning
        case failure
    }

    public init() {
        let configuration = Self.savedConfiguration()
        _baseURLText = NMStateCompat(wrappedValue: configuration?.baseURL.absoluteString ?? "https://netbox.example")
        _selectedCredentialID = NMStateCompat(wrappedValue: configuration?.tokenReference ?? "")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectionForm
                statusPanel
                if let syncResult {
                    syncSummary(syncResult)
                    importPreview(importCandidates)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.background)
        .onChange(of: baseURLText) { _, _ in
            invalidatePreviewForConfigurationChange()
            persistNonSecretConfiguration()
        }
        .onChange(of: selectedCredentialID) { _, _ in
            invalidatePreviewForConfigurationChange()
            persistNonSecretConfiguration()
        }
        .onChange(of: credentials.references) { _, references in
            guard !selectedCredentialID.isEmpty,
                  !references.contains(where: { $0.id.uuidString == selectedCredentialID && $0.kind == .token }) else { return }
            selectedCredentialID = ""
            statusKind = .warning
            statusMessage = t("The selected Keychain credential is no longer available.")
        }
        .confirmationDialog(t("Confirm local asset import"), isPresented: $showingImportConfirmation, titleVisibility: .visible) {
            Button(tf("Add %d selected devices", selectedEligibleCount)) {
                importSelectedCandidates()
            }
            .accessibilityIdentifier("netBoxConfirmAddSelectedAssets")
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("Selected NetBox devices will be added to the local workspace. No changes will be sent to NetBox."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("NetBox connection")).font(.largeTitle.bold())
            Text(t("Read-only asset context from your NetBox source of truth."))
                .font(.callout).foregroundStyle(palette.textSecondary)
        }
    }

    private var connectionForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                TextField(t("NetBox base URL"), text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("netBoxBaseURL")
                    .disabled(isWorking)
                if nonLoopbackHTTPURL {
                    Label(t("HTTP is allowed only for loopback testing. Use HTTPS for network NetBox instances."), systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(palette.warning)
                }

                HStack(alignment: .center, spacing: 12) {
                    Picker(t("API token in Keychain"), selection: $selectedCredentialID) {
                        Text(t("Select a credential")).tag("")
                        ForEach(tokenCredentials) { credential in
                            Text(credential.account.isEmpty ? credential.label : "\(credential.label) · \(credential.account)")
                                .tag(credential.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .disabled(isWorking || tokenCredentials.isEmpty)
                    .accessibilityIdentifier("netBoxCredentialPicker")

                    if tokenCredentials.isEmpty {
                        Text(t("Add an API token in Credentials before connecting."))
                            .font(.caption).foregroundStyle(palette.warning)
                    }
                }

                HStack(spacing: 9) {
                    Button { testConnection() } label: {
                        Label(t("Test connection"), systemImage: "checkmark.icloud")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking || !canConnect)
                    .accessibilityIdentifier("netBoxTestConnection")

                    Button { syncReadOnly() } label: {
                        Label(t("Sync read-only"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !canConnect)
                    .accessibilityIdentifier("netBoxSyncReadOnly")

#if DEBUG
                    Button { loadImportPreviewFixture() } label: {
                        Label(t("Load import preview fixture"), systemImage: "testtube.2")
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("netBoxLoadImportPreviewFixture")
#endif

                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(t("Read-only · no changes are sent to NetBox"))
                        .font(.caption).foregroundStyle(palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle).font(.headline)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(palette.textSecondary)
                        .textSelection(.enabled)
                }
                if let lastTestAt {
                    Text(tf("Last connection test: %@", Fmt.dateTime(lastTestAt)))
                        .font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
    }

    private func syncSummary(_ result: NetBoxSyncResult) -> some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 12) {
                stat(title: t("Devices read"), value: Fmt.integer(result.devices.count), symbol: "server.rack")
                stat(title: t("Sites read"), value: Fmt.integer(result.sites.count), symbol: "mappin.and.ellipse")
                stat(title: t("Pages read"), value: Fmt.integer(result.devicePages + result.sitePages), symbol: "doc.text.magnifyingglass")
                stat(title: t("Last synced"), value: Fmt.dateTime(result.fetchedAt), symbol: "clock")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.vertical, 8)
            LabeledContent(t("Source"), value: result.source)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func importPreview(_ candidates: [NetBoxImportCandidate]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("NetBox import preview")).font(.headline)
                        Text(tf("%d selected of %d importable", selectedEligibleCount, eligibleImportCount))
                            .font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                    }
                    Spacer()
                    Button { selectAllImportable(candidates) } label: {
                        Label(t("Select new"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(eligibleImportCount == 0)
                    .accessibilityIdentifier("netBoxSelectAllNew")

                    Button { selectedImportIDs.removeAll() } label: {
                        Label(t("Clear selection"), systemImage: "circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedEligibleCount == 0)
                    .accessibilityIdentifier("netBoxClearImportSelection")

                    Button { showingImportConfirmation = true } label: {
                        Label(t("Add selected"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedEligibleCount == 0)
                    .accessibilityIdentifier("netBoxAddSelectedAssets")
                }
                if candidates.isEmpty {
                    Text(t("No NetBox devices are available to review."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                resultCell(t("Select"), width: 28, isHeader: true)
                                resultCell(t("Name"), width: 190, isHeader: true)
                                resultCell(t("Site"), width: 150, isHeader: true)
                                resultCell(t("Role"), width: 120, isHeader: true)
                                resultCell(t("Status"), width: 100, isHeader: true)
                                resultCell(t("Primary IP"), width: 150, isHeader: true)
                                resultCell(t("Import status"), width: 190, isHeader: true)
                            }
                            .padding(.vertical, 7)
                            Divider()
                            ForEach(candidates) { candidate in
                                HStack(spacing: 12) {
                                    Toggle(isOn: candidateSelectionBinding(for: candidate)) {
                                        EmptyView()
                                    }
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .disabled(!canImport(candidate))
                                    .accessibilityLabel(tf("Select %@ for import", candidateName(candidate)))
                                    .accessibilityIdentifier("netBoxImportCandidate-\(candidate.id)")
                                    .frame(width: 28)
                                    resultCell(candidateName(candidate), width: 190)
                                    resultCell(candidate.record.site?.label ?? t("Unknown"), width: 150)
                                    resultCell(candidate.record.deviceRole?.label ?? t("Unknown"), width: 120)
                                    resultCell(candidate.record.status?.label ?? t("Unknown"), width: 100)
                                    resultCell(primaryAddress(candidate.record), width: 150, monospaced: true)
                                    Label(candidateStatus(candidate), systemImage: candidateStatusSymbol(candidate))
                                        .font(.caption)
                                        .foregroundStyle(candidateStatusColor(candidate))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 190, alignment: .leading)
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 420)
                    .accessibilityIdentifier("netBoxImportPreviewRows")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultCell(_ value: String, width: CGFloat, isHeader: Bool = false, monospaced: Bool = false) -> some View {
        Text(value)
            .font(isHeader ? .caption.weight(.semibold) : (monospaced ? .callout.monospaced() : .callout))
            .foregroundStyle(isHeader ? palette.textSecondary : palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }

    private func stat(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced().weight(.medium))
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 7))
    }

    private var tokenCredentials: [CredentialRef] {
        credentials.references.filter { $0.kind == .token }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var canConnect: Bool {
        validBaseURL != nil && selectedCredential != nil
    }

    private var validBaseURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), NetBoxConnectionPolicy.permits(url) else { return nil }
        return url
    }

    private var nonLoopbackHTTPURL: Bool {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return !NetBoxConnectionPolicy.isLoopbackHost(host)
    }

    private var selectedCredential: CredentialRef? {
        tokenCredentials.first { $0.id.uuidString == selectedCredentialID }
    }

    private var statusTitle: String {
        switch statusKind {
        case .idle: return t("Not connected")
        case .running: return t("Connecting to NetBox…")
        case .preview: return t("Offline preview loaded")
        case .success: return t("NetBox connection ready")
        case .warning: return t("Action required")
        case .failure: return t("NetBox request failed")
        }
    }

    private var statusSymbol: String {
        switch statusKind {
        case .idle: return "circle.dashed"
        case .running: return "arrow.triangle.2.circlepath.icloud"
        case .preview: return "testtube.2"
        case .success: return "checkmark.icloud.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.icloud.fill"
        }
    }

    private var statusColor: Color {
        switch statusKind {
        case .idle: return palette.textSecondary
        case .running: return palette.info
        case .preview: return palette.info
        case .success: return palette.success
        case .warning: return palette.warning
        case .failure: return palette.danger
        }
    }

    private func testConnection() {
        guard let client = makeClient() else { return }
        isWorking = true
        statusKind = .running
        statusMessage = ""
        Task {
            do {
                let testedAt = try await client.testConnection()
                lastTestAt = testedAt
                statusKind = .success
                statusMessage = t("NetBox API is reachable with this credential.")
            } catch {
                apply(error: error)
            }
            isWorking = false
        }
    }

    private func syncReadOnly() {
        guard let client = makeClient(), let requestedConnection = currentConnectionIdentity else { return }
        isWorking = true
        statusKind = .running
        statusMessage = t("Reading device and site pages from NetBox.")
        syncResult = nil
        importCandidates = []
        selectedImportIDs.removeAll()
        Task {
            do {
                let value = try await client.sync()
                if currentConnectionIdentity == requestedConnection {
                    let candidates = makeImportCandidates(from: value)
                    syncResult = value
                    importCandidates = candidates
                    selectAllImportable(candidates)
                    lastTestAt = value.fetchedAt
                    statusKind = .success
                    statusMessage = tf("Read-only sync completed. Review %d devices; %d are eligible to add.", value.devices.count, eligibleImportCount)
                } else {
                    statusKind = .warning
                    statusMessage = t("Connection changed while NetBox was responding. Sync again to review the current source.")
                }
            } catch {
                apply(error: error)
            }
            isWorking = false
        }
    }

    private var currentConnectionIdentity: String? {
        guard let url = validBaseURL, let credential = selectedCredential else { return nil }
        return "\(url.absoluteString)|\(credential.id.uuidString)"
    }

    private var eligibleImportCount: Int {
        importCandidates.filter(canImport).count
    }

    private var selectedEligibleCount: Int {
        importCandidates.filter { selectedImportIDs.contains($0.id) && canImport($0) }.count
    }

    private func makeImportCandidates(from result: NetBoxSyncResult) -> [NetBoxImportCandidate] {
        var seenSnapshots: [ExternalAssetSnapshot] = []
        return result.devices.map { record in
            let snapshot = NetBoxAssetMapper.snapshot(from: record, source: result.source, fetchedAt: result.fetchedAt)
            let duplicateInResponse = snapshot.map { value in
                seenSnapshots.contains { $0.hasSameIdentity(as: value) }
            } ?? false
            if let snapshot { seenSnapshots.append(snapshot) }
            return NetBoxImportCandidate(record: record, snapshot: snapshot, duplicateInResponse: duplicateInResponse)
        }
    }

    private func canImport(_ candidate: NetBoxImportCandidate) -> Bool {
        guard assets.primaryWorkspace != nil,
              let snapshot = candidate.snapshot,
              !candidate.duplicateInResponse else { return false }
        return !assets.containsExternalAsset(snapshot)
    }

    private func selectAllImportable(_ candidates: [NetBoxImportCandidate]) {
        selectedImportIDs = Set(candidates.filter(canImport).map(\.id))
    }

    private func candidateSelectionBinding(for candidate: NetBoxImportCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedImportIDs.contains(candidate.id) },
            set: { isSelected in
                if isSelected && canImport(candidate) {
                    selectedImportIDs.insert(candidate.id)
                } else {
                    selectedImportIDs.remove(candidate.id)
                }
            }
        )
    }

    private func candidateName(_ candidate: NetBoxImportCandidate) -> String {
        candidate.record.name.isEmpty ? "Device #\(candidate.record.id)" : candidate.record.name
    }

    private func candidateStatus(_ candidate: NetBoxImportCandidate) -> String {
        guard let snapshot = candidate.snapshot else { return t("No primary IP; cannot add") }
        if candidate.duplicateInResponse { return t("Duplicate in NetBox results") }
        guard assets.primaryWorkspace != nil else { return t("Local workspace is unavailable") }
        return assets.containsExternalAsset(snapshot) ? t("Already in local assets") : t("Ready to add")
    }

    private func candidateStatusSymbol(_ candidate: NetBoxImportCandidate) -> String {
        guard let snapshot = candidate.snapshot else { return "minus.circle" }
        if candidate.duplicateInResponse { return "exclamationmark.triangle" }
        guard assets.primaryWorkspace != nil else { return "exclamationmark.triangle" }
        return assets.containsExternalAsset(snapshot) ? "checkmark.circle" : "plus.circle"
    }

    private func candidateStatusColor(_ candidate: NetBoxImportCandidate) -> Color {
        guard let snapshot = candidate.snapshot else { return palette.textSecondary }
        if candidate.duplicateInResponse { return palette.warning }
        guard assets.primaryWorkspace != nil else { return palette.danger }
        return assets.containsExternalAsset(snapshot) ? palette.textSecondary : palette.success
    }

    private func importSelectedCandidates() {
        let snapshots = importCandidates.compactMap { candidate -> ExternalAssetSnapshot? in
            guard selectedImportIDs.contains(candidate.id), canImport(candidate) else { return nil }
            return candidate.snapshot
        }
        guard !snapshots.isEmpty else {
            selectedImportIDs.removeAll()
            statusKind = .warning
            statusMessage = t("The selected devices are already present or cannot be imported.")
            return
        }
        let addedCount = assets.mergeExternalAssets(snapshots)
        selectedImportIDs.removeAll()
        showingImportConfirmation = false
        statusKind = .success
        statusMessage = tf("Added %d new devices to the local workspace.", addedCount)
    }

    private func invalidatePreviewForConfigurationChange() {
        guard syncResult != nil else { return }
        syncResult = nil
        importCandidates = []
        selectedImportIDs.removeAll()
        showingImportConfirmation = false
        lastTestAt = nil
        statusKind = .warning
        statusMessage = t("Connection changed. Sync again to review devices from the current source.")
    }

#if DEBUG
    private func loadImportPreviewFixture() {
        let fetchedAt = Date()
        let site = NetBoxReference(id: 1, name: "lab", display: "Lab")
        let routerRole = NetBoxReference(id: 2, name: "router", display: "Router")
        let routerType = NetBoxDeviceType(id: 3, name: "fixture-router", model: "Fixture Router", manufacturer: NetBoxReference(name: "Example Vendor"))
        let devices = [
            NetBoxDeviceRecord(
                id: 9_900_001,
                name: "fixture-router-01",
                deviceType: routerType,
                deviceRole: routerRole,
                site: site,
                status: NetBoxChoice(value: "active", label: "Active"),
                primaryIP4: NetBoxReference(display: "192.0.2.25/24")
            ),
            NetBoxDeviceRecord(
                id: 9_900_002,
                name: "fixture-no-primary-ip",
                deviceRole: routerRole,
                site: site,
                status: NetBoxChoice(value: "active", label: "Active")
            ),
            NetBoxDeviceRecord(
                id: 9_900_003,
                name: "fixture-duplicate-ip",
                deviceType: routerType,
                deviceRole: routerRole,
                site: site,
                status: NetBoxChoice(value: "active", label: "Active"),
                primaryIP4: NetBoxReference(display: "192.0.2.25/24")
            )
        ]
        let result = NetBoxSyncResult(
            devices: devices,
            sites: [NetBoxSiteRecord(id: 1, name: "Lab")],
            fetchedAt: fetchedAt,
            devicePages: 1,
            sitePages: 1,
            source: "Debug fixture (offline)"
        )
        let candidates = makeImportCandidates(from: result)
        syncResult = result
        importCandidates = candidates
        selectAllImportable(candidates)
        lastTestAt = fetchedAt
        statusKind = .preview
        statusMessage = t("Offline preview fixture loaded. No service was contacted and no assets were changed.")
    }
#endif

    private func makeClient() -> NetBoxClient? {
        guard let url = validBaseURL else {
            statusKind = .warning
            statusMessage = t("Enter an HTTPS NetBox URL with no credentials or query parameters. HTTP is limited to loopback testing.")
            return nil
        }
        guard let selectedCredential else {
            statusKind = .warning
            statusMessage = tokenCredentials.isEmpty
                ? t("No API token is available in Keychain.")
                : t("Select a Keychain API token before connecting.")
            return nil
        }
        do {
            let secret = try credentials.secret(for: selectedCredential)
            guard let token = secret.token, !token.isEmpty else {
                statusKind = .warning
                statusMessage = t("The selected Keychain credential does not contain an API token.")
                return nil
            }
            let configuration = NetBoxConfiguration(baseURL: url, tokenReference: selectedCredential.id.uuidString)
            persist(configuration)
            return NetBoxClient(configuration: configuration, token: token)
        } catch {
            statusKind = .failure
            statusMessage = safeMessage(error.localizedDescription, token: nil)
            return nil
        }
    }

    private func apply(error: Error) {
        let token = selectedCredential.flatMap { try? credentials.secret(for: $0).token }
        if let netBoxError = error as? NetBoxError, case .missingToken = netBoxError {
            statusKind = .warning
        } else {
            statusKind = .failure
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            statusMessage = t("The NetBox request timed out. Check the URL and network path, then retry.")
        } else {
            statusMessage = safeMessage(error.localizedDescription, token: token ?? nil)
        }
    }

    private func safeMessage(_ message: String, token: String?) -> String {
        guard let token, !token.isEmpty else { return message }
        return message.replacingOccurrences(of: token, with: "••••••")
    }

    private func primaryAddress(_ device: NetBoxDeviceRecord) -> String {
        device.primaryIP4?.display ?? device.primaryIP6?.display ?? t("No primary address")
    }

    private func persistNonSecretConfiguration() {
        guard let url = validBaseURL else { return }
        let configuration = NetBoxConfiguration(baseURL: url, tokenReference: selectedCredentialID.isEmpty ? nil : selectedCredentialID)
        persist(configuration)
    }

    private func persist(_ configuration: NetBoxConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration),
              let value = String(data: data, encoding: .utf8) else { return }
        SettingsStore.shared.setString("netbox.connection", value)
    }

    private static func savedConfiguration() -> NetBoxConfiguration? {
        let raw = SettingsStore.shared.string("netbox.connection", default: "")
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NetBoxConfiguration.self, from: data)
    }
}
