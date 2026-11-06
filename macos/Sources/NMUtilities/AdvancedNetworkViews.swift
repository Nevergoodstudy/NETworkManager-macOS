import SwiftUI
import NMCore

public struct IPGeolocationView: View {
    @Environment(\.palette) private var palette
    @NMStateCompat private var query = "8.8.8.8"
    @NMStateCompat private var result: IPGeolocation?
    @NMStateCompat private var error: String?
    @NMStateCompat private var isRunning = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text(t("The address is sent to the selected public geolocation service only when you start a lookup."))
                .foregroundStyle(palette.textSecondary)
            if let error { Text(error).foregroundStyle(palette.danger) }
            if let result {
                details(result)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.card))
            } else {
                ContentUnavailableView(t("Nothing to show"), systemImage: "globe")
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
    }

    private var header: some View {
        HStack {
            Text(t("IP Geolocation")).font(.largeTitle.bold())
            Spacer()
            TextField(t("IP address or hostname"), text: $query)
                .textFieldStyle(.roundedBorder).frame(width: 260)
            Button(isRunning ? t("Running…") : t("Lookup")) { lookup() }
                .buttonStyle(.borderedProminent).disabled(isRunning)
        }
    }

    private func details(_ value: IPGeolocation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(t("IP address"), value.ip)
            row(t("Location"), value.location)
            row(t("Country code"), value.countryCode ?? "—")
            row(t("Coordinates"), coordinateText(value))
            row(t("Timezone"), value.timezone ?? "—")
            row(t("ISP"), value.isp ?? "—")
            row(t("Organization"), value.organization ?? "—")
            row("ASN", value.asn ?? "—")
        }
    }

    private func coordinateText(_ value: IPGeolocation) -> String {
        guard let latitude = value.latitude, let longitude = value.longitude else { return "—" }
        return "\(latitude), \(longitude)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(palette.textSecondary).frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }

    private func lookup() {
        let target = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { error = t("Invalid input"); return }
        isRunning = true; error = nil; result = nil
        Task {
            do { result = try await IPGeolocationClient.lookup(target) }
            catch { self.error = error.localizedDescription }
            isRunning = false
        }
    }
}

public struct SNMPView: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var credentials = CredentialStore.shared
    @NMStateCompat private var host = "127.0.0.1"
    @NMStateCompat private var port = "161"
    @NMStateCompat private var community = "public"
    @NMStateCompat private var username = ""
    @NMStateCompat private var authenticationPassword = ""
    @NMStateCompat private var privacyPassword = ""
    @NMStateCompat private var authenticationProtocol = "SHA-256"
    @NMStateCompat private var securityLevel = "authNoPriv"
    @NMStateCompat private var selectedCredentialID = ""
    @NMStateCompat private var oid = "1.3.6.1.2.1.1.1.0"
    @NMStateCompat private var value = ""
    @NMStateCompat private var version = "v2c"
    @NMStateCompat private var operation = "GET"
    @NMStateCompat private var rows: [SNMPVarBind] = []
    @NMStateCompat private var output = ""
    @NMStateCompat private var error: String?
    @NMStateCompat private var isRunning = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(t("SNMP")).font(.largeTitle.bold())
                    Spacer()
                    Picker(t("Operation"), selection: $operation) {
                        ForEach(availableOperations, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .accessibilityIdentifier("snmpOperationPicker")
                }
                GroupBox(t("Agent")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField(t("Host"), text: $host)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("snmpHost")
                            TextField(t("Port"), text: $port)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 75)
                                .accessibilityIdentifier("snmpPort")
                            Picker(t("Version"), selection: $version) {
                                Text("SNMP v1").tag("v1")
                                Text("SNMP v2c").tag("v2c")
                                Text("SNMP v3").tag("v3")
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("snmpVersionPicker")
                        }
                        if !snmpCredentials.isEmpty {
                            Picker(t("Credential reference"), selection: $selectedCredentialID) {
                                Text(t("None")).tag("")
                                ForEach(snmpCredentials) { ref in
                                    Text(ref.account.isEmpty ? ref.label : "\(ref.label) · \(ref.account)")
                                        .tag(ref.id.uuidString)
                                }
                            }
                            .accessibilityIdentifier("snmpCredentialPicker")
                        }
                        if version == "v3" {
                            snmpV3Fields
                        } else if selectedCredentialID.isEmpty {
                            SecureField(t("Community"), text: $community)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("snmpCommunity")
                        }
                        HStack {
                            TextField(t("OID"), text: $oid)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("snmpOID")
                            if operation == "SET" { TextField(t("Value"), text: $value).textFieldStyle(.roundedBorder) }
                            Button(isRunning ? t("Running…") : t("Run")) { run() }
                                .buttonStyle(.borderedProminent)
                                .disabled(isRunning)
                                .accessibilityIdentifier("snmpRun")
                            Button(t("Clear")) { rows.removeAll(); output = ""; error = nil }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(4)
                }
                if let error { Text(error).foregroundStyle(palette.danger).textSelection(.enabled) }
                if !output.isEmpty { Text(output).font(.caption).foregroundStyle(palette.textSecondary) }
                Table(rows) {
                    TableColumn(t("OID")) { Text($0.oid).font(.body.monospaced()) }
                    TableColumn(t("Value")) { Text($0.value.displayValue).textSelection(.enabled) }
                }
                .frame(minHeight: 380)
                Text(t(version == "v3"
                    ? "SNMPv3 supports authenticated GET and WALK with SHA-1 or SHA-256; authPriv uses AES-128-CFB. Device interoperability still requires field testing."
                    : "Native SNMP v1/v2c uses UDP sockets. Credentials are sent as the configured community string."))
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .background(palette.background)
        .onChange(of: version) { _, newVersion in
            if newVersion == "v3", operation == "SET" { operation = "GET" }
        }
        .onChange(of: selectedCredentialID) { _, selectedID in
            guard let ref = snmpCredentials.first(where: { $0.id.uuidString == selectedID }) else { return }
            username = ref.account
            community = ""
        }
    }

    private var snmpCredentials: [CredentialRef] {
        credentials.references.filter { $0.kind == .snmp }
    }

    private var availableOperations: [String] {
        version == "v3" ? ["GET", "WALK"] : ["GET", "WALK", "SET"]
    }

    @ViewBuilder
    private var snmpV3Fields: some View {
        if selectedCredentialID.isEmpty {
            TextField(t("Username"), text: $username)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snmpUsername")
            HStack {
                authenticationPickers
            }
            SecureField(t("Authentication password"), text: $authenticationPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("snmpAuthPassword")
            if securityLevel == "authPriv" {
                SecureField(t("Privacy password"), text: $privacyPassword)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("snmpPrivacyPassword")
            }
        } else {
            authenticationPickers
        }
    }

    private var authenticationPickers: some View {
        Group {
            Picker(t("Authentication"), selection: $authenticationProtocol) {
                Text("SHA-256").tag("SHA-256")
                Text("SHA-1").tag("SHA-1")
            }
            .pickerStyle(.menu)
            Picker(t("Security level"), selection: $securityLevel) {
                Text("authNoPriv").tag("authNoPriv")
                Text("authPriv").tag("authPriv")
            }
            .pickerStyle(.menu)
        }
    }

    private func run() {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !oid.isEmpty,
              let selectedPort = Int(port), (1...65_535).contains(selectedPort) else { error = t("Invalid input"); return }
        let selectedVersion = version
        let selectedOperation = operation
        let selectedOID = oid
        let selectedValue = value
        let selectedCommunity = community
        let selectedUsername = username
        let selectedAuthenticationPassword = authenticationPassword
        let selectedPrivacyPassword = privacyPassword
        let selectedAuthenticationProtocol = authenticationProtocol
        let selectedSecurityLevel = securityLevel
        let selectedCredential = snmpCredentials.first { $0.id.uuidString == selectedCredentialID }
        let runID = AssetStore.shared.beginDiagnostic(
            kind: .snmp,
            target: target,
            parameters: ["operation": selectedOperation, "version": selectedVersion, "oid": selectedOID, "port": String(selectedPort)]
        )
        let startedAt = Date()
        isRunning = true; error = nil; output = ""; rows = []
        Task {
            var runStatus: DiagnosticRunStatus = .failed
            var runSummary = ""
            var runDetail = ""
            var runLatency: TimeInterval?
            var runSource = "SNMP \(selectedVersion)"
            do {
                let secret = try selectedCredential.map { try credentials.secret(for: $0) }
                if selectedVersion == "v3" {
                    let resolvedUsername = secret?.username ?? selectedCredential?.account ?? selectedUsername
                    let resolvedAuthenticationPassword = secret?.password ?? selectedAuthenticationPassword
                    let resolvedPrivacyPassword = secret?.privacyPassword ?? selectedPrivacyPassword
                    let level: SNMPv3SecurityLevel = selectedSecurityLevel == "authPriv" ? .authPriv : .authNoPriv
                    let configuration = SNMPv3Configuration(
                        host: target,
                        port: selectedPort,
                        username: resolvedUsername,
                        authProtocol: selectedAuthenticationProtocol == "SHA-1" ? .sha1 : .sha256,
                        securityLevel: level
                    )
                    let client = try SNMPv3Client(configuration: configuration,
                                                  authenticationPassword: resolvedAuthenticationPassword,
                                                  privacyPassword: level == .authPriv ? resolvedPrivacyPassword : nil)
                    let activeSecrets: [String?] = [resolvedAuthenticationPassword, resolvedPrivacyPassword]
                    if selectedOperation == "WALK" {
                        let values = try await Task.detached { try client.walk(selectedOID) }.value
                        let safeValues = redactedVarBinds(values, secrets: activeSecrets)
                        rows = safeValues
                        output = tf("Completed: %d result(s)", values.count)
                        runSummary = tf("SNMP walk completed with %d result(s)", values.count)
                        runDetail = safeValues.map { "\($0.oid)=\($0.value.displayValue)" }.joined(separator: "\n")
                    } else {
                        let response = try await Task.detached { try client.get(selectedOID) }.value
                        let safeValues = redactedVarBinds(response.varBinds, secrets: activeSecrets)
                        rows = safeValues
                        output = tf("Response in %@", Fmt.duration(response.elapsed))
                        runSummary = t("SNMP responded")
                        runDetail = safeValues.map { "\($0.oid)=\($0.value.displayValue)" }.joined(separator: "\n")
                        runLatency = response.elapsed
                    }
                } else {
                    let resolvedCommunity = secret?.password ?? selectedCommunity
                    let selectedSNMPVersion: SNMPVersion = selectedVersion == "v1" ? .v1 : .v2c
                    let client = SNMPClient(host: target, community: resolvedCommunity, version: selectedSNMPVersion, port: selectedPort)
                    let activeSecrets: [String?] = [resolvedCommunity]
                    if selectedOperation == "WALK" {
                        let values = try await Task.detached { try client.walk(selectedOID) }.value
                        let safeValues = redactedVarBinds(values, secrets: activeSecrets)
                        rows = safeValues
                        output = tf("Completed: %d result(s)", values.count)
                        runSummary = tf("SNMP walk completed with %d result(s)", values.count)
                        runDetail = safeValues.map { "\($0.oid)=\($0.value.displayValue)" }.joined(separator: "\n")
                    } else {
                    let response = try await Task.detached {
                        if selectedOperation == "SET" { return try client.set(selectedOID, value: .string(selectedValue)) }
                        return try client.get(selectedOID)
                    }.value
                    let safeValues = redactedVarBinds(response.varBinds, secrets: activeSecrets)
                    rows = safeValues
                    output = tf("Response in %@", Fmt.duration(response.elapsed))
                    runSummary = selectedOperation == "SET" ? t("SNMP write completed") : t("SNMP responded")
                    runDetail = safeValues.map { "\($0.oid)=\($0.value.displayValue)" }.joined(separator: "\n")
                    runLatency = response.elapsed
                    }
                }
                runStatus = .succeeded
                runLatency = runLatency ?? Date().timeIntervalSince(startedAt)
            } catch {
                self.error = error.localizedDescription
                runSummary = error.localizedDescription
                runSource = "SNMP \(selectedVersion)"
                if let snmpError = error as? SNMPError {
                    switch snmpError {
                    case .timeout: runStatus = .timedOut
                    case .cancelled: runStatus = .cancelled
                    default: break
                    }
                }
                runLatency = Date().timeIntervalSince(startedAt)
            }
            AssetStore.shared.finishDiagnostic(id: runID, status: runStatus, summary: runSummary,
                                               detail: runDetail, latency: runLatency, source: runSource)
            isRunning = false
        }
    }

    private func redactedVarBinds(_ values: [SNMPVarBind], secrets: [String?]) -> [SNMPVarBind] {
        values.map { value in
            guard case .string(let text) = value.value else { return value }
            return SNMPVarBind(oid: value.oid, value: .string(DiagnosticSecretRedactor.redact(text, secrets: secrets)))
        }
    }
}

