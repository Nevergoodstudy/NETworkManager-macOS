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
    @NMStateCompat private var dnsMode: DNSLookupMode = .system
    @NMStateCompat private var recordType: DNSRecordType = .a
    @NMStateCompat private var records: [DNSRecord] = []
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
            }
            GroupBox(t("Query")) {
                VStack(alignment: .leading, spacing: 10) {
                    if kind == .dns {
                        Picker(t("Resolver"), selection: dnsModeBinding) {
                            ForEach(DNSLookupMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 340)
                        .accessibilityIdentifier("diagnosticDNSMode")
                    }

                    HStack {
                        TextField(kind == .sntp ? t("NTP server") : t("Hostname or IP address"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("diagnosticQueryTarget")
                        if kind == .dns {
                            Picker(t("Type"), selection: $recordType) {
                                ForEach(availableRecordTypes) { Text($0.displayName).tag($0) }
                            }
                            .frame(width: 110)
                            .accessibilityIdentifier("diagnosticDNSRecordType")
                        }
                        if kind != .dns || dnsMode == .server {
                            TextField(kind == .dns ? t("DNS server") : t("Server (optional)"), text: $server)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .accessibilityIdentifier("diagnosticLookupServer")
                        }
                        Button(isRunning ? t("Running…") : t("Lookup")) { run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRunning)
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
            if let error { Text(error).foregroundStyle(palette.danger) }
            if kind == .dns {
                Table(records) {
                    TableColumn(t("Name")) { Text($0.name).font(.body.monospaced()) }
                    TableColumn(t("Type")) { Text($0.type.displayName) }
                    TableColumn("TTL") { Text($0.ttl.map { String($0) } ?? "—") }
                    TableColumn(t("Value")) { Text($0.value).font(.body.monospaced()) }
                }.frame(minHeight: 300)
            } else {
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
    }

    private func run() {
        let target = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { error = t("Invalid input"); return }
        isRunning = true; error = nil; output = ""; records = []
        switch kind {
        case .dns:
            let selectedType = recordType
            let selectedMode = dnsMode
            let selectedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedMode == .server && selectedServer.isEmpty {
                error = t("Enter a DNS server for this query mode.")
                return
            }
            let serverArgument = selectedMode == .server ? selectedServer : nil
            let runID = history.beginDiagnostic(kind: .dns, target: target,
                                                parameters: ["recordType": selectedType.displayName,
                                                             "mode": selectedMode.rawValue,
                                                             "server": serverArgument ?? ""])
            diagnosticTask = Task {
                let result = await DiagnosticService.runDNS(host: target, recordType: selectedType,
                                                            server: serverArgument, mode: selectedMode)
                records = result.dnsRecords
                output = result.displayOutput ?? result.detail
                error = result.status == .succeeded ? nil : result.summary
                history.finishDiagnostic(id: runID, status: result.status, summary: result.summary,
                                          detail: result.detail, latency: result.latency, source: result.source)
                diagnosticTask = nil
                isRunning = false
            }
        case .whois:
            let selectedServer = server.isEmpty ? nil : server
            let runID = history.beginDiagnostic(kind: .whois, target: target, parameters: ["server": selectedServer ?? "auto"])
            diagnosticTask = Task {
                let result = await DiagnosticService.runWhois(host: target, server: selectedServer)
                output = result.displayOutput ?? result.detail
                error = result.status == .succeeded ? nil : result.summary
                history.finishDiagnostic(id: runID, status: result.status, summary: result.summary,
                                          detail: result.detail, latency: result.latency, source: result.source)
                diagnosticTask = nil
                isRunning = false
            }
        case .sntp:
            let timeout: TimeInterval = 3
            let runID = history.beginDiagnostic(kind: .sntp, target: target, parameters: ["timeout": String(timeout)])
            diagnosticTask = Task {
                let result = await DiagnosticService.runSNTP(host: target, timeout: timeout)
                output = result.displayOutput ?? result.detail
                error = result.status == .succeeded ? nil : result.summary
                history.finishDiagnostic(id: runID, status: result.status, summary: result.summary,
                                          detail: result.detail, latency: result.latency, source: result.source)
                diagnosticTask = nil
                isRunning = false
            }
        }
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
