import SwiftUI
import NMCore

public struct LookupView: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case dns, whois, sntp
        public var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }

    @Environment(\.palette) private var palette
    @ObservedObject private var history = AssetStore.shared
    @NMStateCompat private var kind: Kind
    @NMStateCompat private var query = "example.com"
    @NMStateCompat private var server = ""
    @NMStateCompat private var dnsServerPort = "53"
    @NMStateCompat private var dnsMode: DNSLookupMode = .system
    @NMStateCompat private var recordType: DNSRecordType = .a
    @NMStateCompat private var records: [DNSRecord] = []
    @NMStateCompat private var dnsRequestDescription: String?
    @NMStateCompat private var dnsResultMode: DNSLookupMode?
    @NMStateCompat private var output = ""
    @NMStateCompat private var isRunning = false
    @NMStateCompat private var diagnosticTask: Task<Void, Never>?
    @NMStateCompat private var error: String?

    public init(kind: Kind = .dns) { _kind = NMStateCompat(wrappedValue: kind) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t(kind.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Tool"), selection: $kind) { ForEach(Kind.allCases) { Text(t($0.title)).tag($0) } }
                    .pickerStyle(.menu)
                    .disabled(isRunning)
            }
            GroupBox(t("Query")) {
                VStack(alignment: .leading, spacing: 10) {
                    if kind == .dns {
                        Picker(t("Resolver"), selection: dnsModeBinding) {
                            ForEach(DNSLookupMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 340)
                        .disabled(isRunning)
                        .accessibilityIdentifier("diagnosticDNSMode")
                        if dnsMode == .server {
                            HStack {
                                TextField(t("DNS server"), text: $server)
                                    .accessibilityIdentifier("diagnosticLookupServer")
                                TextField(t("Port"), text: $dnsServerPort)
                                    .frame(width: 72)
                                    .accessibilityLabel(t("DNS server port"))
                                    .accessibilityIdentifier("diagnosticLookupDNSPort")
                            }
                            .textFieldStyle(.roundedBorder)
                            .disabled(isRunning)
                        }
                    }

                    HStack {
                        TextField(kind == .sntp ? t("NTP server") : t("Hostname or IP address"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isRunning)
                            .accessibilityIdentifier("diagnosticQueryTarget")
                        if kind == .dns {
                            Picker(t("Type"), selection: $recordType) {
                                ForEach(availableRecordTypes) { Text($0.displayName).tag($0) }
                            }
                            .frame(width: 110)
                            .disabled(isRunning)
                            .accessibilityIdentifier("diagnosticDNSRecordType")
                        }
                        if kind != .dns {
                            TextField(t("Server (optional)"), text: $server)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .disabled(isRunning)
                                .accessibilityIdentifier("diagnosticLookupServer")
                        }
                        Button(isRunning ? t("Running…") : t("Lookup")) { run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRunning || history.isLoadingWorkspace)
                            .accessibilityIdentifier("diagnosticLookupRun")
                        if isRunning {
                            Button { diagnosticTask?.cancel() } label: {
                                Label(t("Cancel"), systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("cancelDiagnosticLookup")
                        }
                    }
                }
            }
            if kind == .dns {
                dnsResults
            } else {
                if let error { Text(error).foregroundStyle(palette.danger) }
                ScrollView {
                    Text(output.isEmpty ? t("Nothing to show") : output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 300)
            }
        }
        .padding(28)
        .background(palette.background)
        .onDisappear { diagnosticTask?.cancel() }
        .onChange(of: kind) { _, _ in clearResults() }
        .onChange(of: query) { _, _ in clearResults() }
        .onChange(of: server) { _, _ in clearResults() }
        .onChange(of: dnsServerPort) { _, _ in clearResults() }
        .onChange(of: dnsMode) { _, _ in clearResults() }
        .onChange(of: recordType) { _, _ in clearResults() }
    }

    private func run() {
        guard !isRunning, !history.isLoadingWorkspace else { return }
        clearResults()
        let target = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { error = t("Invalid input"); return }
        let usesSpecifiedServer = kind == .dns && dnsMode == .server
        let selectedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesSpecifiedServer && selectedServer.isEmpty {
            error = t("Enter a DNS server for this query mode.")
            return
        }
        guard let port = usesSpecifiedServer ? UInt16(dnsServerPort.trimmingCharacters(in: .whitespacesAndNewlines)) : 53,
              port > 0 else {
            error = t("Enter a TCP or DNS port from 1 to 65535.")
            return
        }
        let diagnosticKind: DiagnosticKind
        let parameters: [String: String]
        let execute: @Sendable () async -> DiagnosticExecutionResult
        switch kind {
        case .dns:
            let selectedType = recordType
            let selectedMode = dnsMode
            let serverArgument = usesSpecifiedServer ? selectedServer : nil
            dnsRequestDescription = tf("Query: %@ (%@)", target, selectedType.displayName)
            dnsResultMode = selectedMode
            diagnosticKind = .dns
            var dnsParameters = ["recordType": selectedType.displayName, "mode": selectedMode.rawValue,
                                 "server": serverArgument ?? ""]
            if usesSpecifiedServer { dnsParameters["serverPort"] = String(port) }
            parameters = dnsParameters
            execute = {
                await DiagnosticService.runDNS(host: target, recordType: selectedType,
                                               server: serverArgument, serverPort: port, mode: selectedMode)
            }
        case .whois:
            let selectedServer = server.isEmpty ? nil : server
            diagnosticKind = .whois
            parameters = ["server": selectedServer ?? "auto"]
            execute = { await DiagnosticService.runWhois(host: target, server: selectedServer) }
        case .sntp:
            let timeout: TimeInterval = 3
            diagnosticKind = .sntp
            parameters = ["timeout": String(timeout)]
            execute = { await DiagnosticService.runSNTP(host: target, timeout: timeout) }
        }
        diagnosticTask = ProcessRuntime.startDiagnosticTask(DiagnosticCancellation()) {
            let runID = history.beginDiagnostic(kind: diagnosticKind, target: target, parameters: parameters)
            let result = await execute()
            if diagnosticKind == .dns { records = result.dnsRecords }
            output = result.displayOutput ?? result.detail
            error = result.status == .succeeded ? nil : result.summary
            history.finishDiagnostic(id: runID, status: result.status, summary: result.summary,
                                     detail: result.detail, latency: result.latency, source: result.source)
            diagnosticTask = nil
            isRunning = false
        }
        isRunning = diagnosticTask != nil
    }

    @ViewBuilder
    private var dnsResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dnsRequestDescription {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dnsRequestDescription)
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("diagnosticDNSQuerySummary")
                    if !output.isEmpty {
                        Text(output)
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.textSecondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("diagnosticDNSResultMetadata")
                    }
                }
            }

            if isRunning {
                ProgressView(t("Resolving DNS query…"))
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .accessibilityIdentifier("diagnosticDNSProgress")
            } else if let error {
                ContentUnavailableView(t("DNS lookup failed"),
                                       systemImage: "exclamationmark.magnifyingglass",
                                       description: Text(error))
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .accessibilityIdentifier("diagnosticDNSStatus")
            } else if dnsRequestDescription == nil {
                ContentUnavailableView(t("Run a DNS lookup to see results."),
                                       systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .accessibilityIdentifier("diagnosticDNSEmpty")
            } else if records.isEmpty {
                ContentUnavailableView(t("The query completed without matching records."),
                                       systemImage: "magnifyingglass",
                                       description: Text(t("The DNS response was successful, but contained no records of the selected type.")))
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .accessibilityIdentifier("diagnosticDNSEmpty")
            } else {
                Table(records) {
                    TableColumn(t("Name")) { Text($0.name).font(.body.monospaced()) }
                    TableColumn(t("Type")) { Text($0.type.displayName) }
                    TableColumn("TTL") { Text($0.ttl.map { String($0) } ?? "—") }
                    TableColumn(t("Value")) { Text($0.value).font(.body.monospaced()) }
                }
                .frame(minHeight: 300)

                if dnsResultMode == .system {
                    Text(t("The macOS system resolver does not expose DNS record TTLs."))
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }

    private func clearResults() {
        records = []
        dnsRequestDescription = nil
        dnsResultMode = nil
        output = ""
        error = nil
    }

    private var availableRecordTypes: [DNSRecordType] {
        dnsMode == .system ? [.a, .aaaa] : DNSRecordType.allCases
    }

    private var dnsModeBinding: Binding<DNSLookupMode> {
        Binding(get: { dnsMode }, set: { newMode in
            dnsMode = newMode
            if newMode == .system && recordType != .a && recordType != .aaaa {
                recordType = .a
            }
        })
    }
}
