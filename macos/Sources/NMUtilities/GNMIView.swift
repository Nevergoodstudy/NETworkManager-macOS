import NMCore
import SwiftUI
import UniformTypeIdentifiers

public struct GNMIView: View {
    @NMStateCompat private var host = ""
    @NMStateCompat private var port = "57400"
    @NMStateCompat private var interfaceName = ""
    @NMStateCompat private var selectingCA = false
    @NMStateCompat private var certificateAuthority: URL?
    @NMStateCompat private var selectingClient = false
    @NMStateCompat private var clientExecutable: URL?
    @NMStateCompat private var task: Task<Void, Never>?
    @NMStateCompat private var report: GNMICapabilities.Report?
    @NMStateCompat private var interfaceState: GNMICapabilities.InterfaceState?
    @NMStateCompat private var status: String?

    public init() {}

    public var body: some View {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let interface = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        Form {
            Section("gNMI TLS") {
                TextField(t("Host"), text: $host)
                    .accessibilityIdentifier("gnmiHost")
                TextField(t("Port"), text: $port)
                    .accessibilityIdentifier("gnmiPort")
                HStack {
                    Button(t("Choose gnmic executable…"), systemImage: "terminal") { selectingClient = true }
                        .fileImporter(isPresented: $selectingClient, allowedContentTypes: [.unixExecutable]) { result in
                            switch result {
                            case .success(let url): clientExecutable = url
                            case .failure: status = t("Could not open the gnmic executable.")
                            }
                        }
                    if let clientExecutable {
                        Text(clientExecutable.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button(t("Clear gnmic executable"), systemImage: "xmark.circle") { self.clientExecutable = nil }
                            .labelStyle(.iconOnly)
                            .help(t("Clear gnmic executable"))
                    }
                }
                HStack {
                    Button(t("Choose CA certificate…"), systemImage: "doc.badge.plus") { selectingCA = true }
                    if let certificateAuthority {
                        Text(certificateAuthority.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button(t("Clear CA certificate"), systemImage: "xmark.circle") { self.certificateAuthority = nil }
                            .labelStyle(.iconOnly)
                            .help(t("Clear CA certificate"))
                    }
                }
            }
            .disabled(task != nil)
            Button(t("Read capabilities"), systemImage: "arrow.down.circle") { read(host: target) }
                .disabled(task != nil || target.isEmpty)
            Section(t("Interface state")) {
                TextField(t("Interface name"), text: $interfaceName)
                    .accessibilityIdentifier("gnmiInterface")
                    .disabled(task != nil)
                Button(t("Read interface state"), systemImage: "arrow.down.circle") { read(host: target, interface: interface) }
                    .disabled(task != nil || target.isEmpty || interface.isEmpty)
                if let interfaceState {
                    LabeledContent(interfaceState.interface, value: interfaceState.status.rawValue)
                    LabeledContent(t("Sampled at"), value: interfaceState.sampledAt.formatted())
                }
            }
            if task != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Button(t("Cancel")) { task?.cancel() }
                }
            }
            if let status { Text(status).foregroundStyle(.secondary) }
            if let report {
                Section(t("Capabilities")) {
                    LabeledContent(t("Version"), value: report.gNMIVersion)
                    LabeledContent(t("Supported encodings"), value: (report.supportedEncodings ?? []).joined(separator: ", "))
                    ForEach(Array((report.supportedModels ?? []).enumerated()), id: \.offset) { _, model in
                        LabeledContent(model.name,
                                       value: [model.organization, model.version].compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $selectingCA, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): certificateAuthority = url
            case .failure: status = t("Could not open the CA certificate file.")
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func read(host target: String, interface: String? = nil) {
        status = nil
        report = nil
        interfaceState = nil
        let targetPort = Int(port) ?? 0
        let selectedCA = certificateAuthority
        let selectedClient = clientExecutable
        task = Task { @MainActor in
            defer { task = nil }
            let scoped = selectedClient?.startAccessingSecurityScopedResource() == true
            defer { if scoped { selectedClient?.stopAccessingSecurityScopedResource() } }
            do {
                if let interface {
                    let response = try await GNMICapabilities.readInterfaceState(host: target, port: targetPort, interface: interface,
                                                                                   certificateAuthority: selectedCA,
                                                                                   executable: selectedClient)
                    guard !Task.isCancelled else { return }
                    interfaceState = response
                    return
                }
                let response = try await GNMICapabilities.read(host: target, port: targetPort, certificateAuthority: selectedCA,
                                                              executable: selectedClient)
                guard !Task.isCancelled else { return }
                report = response
            } catch GNMICapabilities.Failure.invalidTarget {
                status = t("Enter a valid hostname or IP address and port.")
            } catch GNMICapabilities.Failure.invalidInterface {
                status = t("Enter one exact interface name.")
            } catch GNMICapabilities.Failure.missingInterfaceState {
                status = t("The device returned no state for this interface.")
            } catch GNMICapabilities.Failure.missingClient {
                status = t("gnmic was not found in the system or Homebrew command locations.")
            } catch GNMICapabilities.Failure.invalidClient {
                status = t("Could not open the gnmic executable.")
            } catch GNMICapabilities.Failure.cancelled {
                status = t("Cancelled")
            } catch GNMICapabilities.Failure.timedOut {
                status = t("Timed out")
            } catch GNMICapabilities.Failure.invalidReport {
                status = t(interface == nil ? "gNMI returned an unsupported capabilities response." : "gNMI returned an unsupported interface state response.")
            } catch {
                status = t(interface == nil ? "Could not read gNMI capabilities. Check the endpoint and TLS certificate." :
                           "Could not read interface state. Check the endpoint, CA certificate, and OpenConfig support.")
            }
        }
    }
}
