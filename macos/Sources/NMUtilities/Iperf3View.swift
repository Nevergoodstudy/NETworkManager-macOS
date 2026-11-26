import SwiftUI
import NMCore
import UniformTypeIdentifiers

public struct Iperf3View: View {
    @NMStateCompat private var host = ""
    @NMStateCompat private var port = "5201"
    @NMStateCompat private var direction = Iperf3.Direction.forward
    @NMStateCompat private var seconds = 5
    @NMStateCompat private var megabitsPerSecond = 1
    @NMStateCompat private var task: Task<Void, Never>?
    @NMStateCompat private var measurement: Iperf3.Measurement?
    @NMStateCompat private var status: String?
    @NMStateCompat private var exportingReport = false
    @NMStateCompat private var exportFile: Iperf3ReportFile?
    @NMStateCompat private var selectingClient = false
    @NMStateCompat private var clientExecutable: URL?

    public init() {}

    public var body: some View {
        Form {
            Section(t("iperf3 throughput")) {
                TextField(t("iperf3 server"), text: $host)
                    .accessibilityLabel(t("iperf3 server"))
                    .accessibilityIdentifier("iperfServer")
                TextField(t("Port"), text: $port)
                    .accessibilityLabel(t("Port"))
                    .accessibilityIdentifier("iperfPort")
                HStack {
                    Button(t("Choose iperf3 executable…"), systemImage: "terminal") { selectingClient = true }
                    if let clientExecutable {
                        Text(clientExecutable.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button(t("Clear iperf3 executable"), systemImage: "xmark.circle") { self.clientExecutable = nil }
                            .labelStyle(.iconOnly)
                            .help(t("Clear iperf3 executable"))
                    }
                }
                .fileImporter(isPresented: $selectingClient, allowedContentTypes: [.unixExecutable]) { result in
                    switch result {
                    case .success(let url): clientExecutable = url
                    case .failure: status = t("Could not open the iperf3 executable.")
                    }
                }
                Picker(t("Traffic direction"), selection: $direction) {
                    Text(t("Mac to server")).tag(Iperf3.Direction.forward)
                    Text(t("Server to Mac")).tag(Iperf3.Direction.reverse)
                }
                .pickerStyle(.segmented)
                Stepper(tf("Duration: %d s", seconds), value: $seconds, in: 1...10)
                Stepper(tf("Target rate: %d Mbps", megabitsPerSecond), value: $megabitsPerSecond, in: 1...10)
            }
            .disabled(task != nil)

            HStack {
                Button(t("Start"), action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(task != nil || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if task != nil {
                    Button(t("Cancel")) { task?.cancel() }
                    ProgressView().controlSize(.small).accessibilityLabel(t("Running…"))
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }

            if let measurement {
                Section(t("Measured endpoints")) {
                    LabeledContent("Mac", value: measurement.localAddress)
                    LabeledContent(t("Interfaces matching local address"),
                                   value: measurement.localAddressInterfaces.isEmpty ? t("Not recorded") :
                                       measurement.localAddressInterfaces.joined(separator: ", "))
                    LabeledContent(t("Server"), value: measurement.remoteAddress.contains(":")
                                   ? "[\(measurement.remoteAddress)]:\(measurement.remotePort)"
                                   : "\(measurement.remoteAddress):\(measurement.remotePort)")
                    LabeledContent(t("Version"), value: measurement.clientVersion)
                }
                .textSelection(.enabled)

                Section(t("Measurement settings")) {
                    LabeledContent(t("Traffic direction"),
                                   value: t(measurement.direction == .forward ? "Mac to server" : "Server to Mac"))
                    Text(tf("Duration: %d s", measurement.requestedSeconds))
                    Text(tf("Target rate: %d Mbps", measurement.targetBitsPerSecond / 1_000_000))
                    LabeledContent(t("Sender"), value: summary(measurement.sender))
                    LabeledContent(t("Receiver"), value: summary(measurement.receiver))
                    Button(t("Export…"), systemImage: "square.and.arrow.up") {
                        do {
                            exportFile = Iperf3ReportFile(data: try measurement.reportJSON())
                            exportingReport = true
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onDisappear { task?.cancel() }
        .fileExporter(isPresented: $exportingReport, document: exportFile, contentType: .json,
                      defaultFilename: "NETworkManager-iperf3.json") { result in
            exportFile = nil
            if case .failure(let error) = result { status = error.localizedDescription }
        }
    }

    private func start() {
        status = nil
        measurement = nil
        let endpoint = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let selectedDirection = direction
        let duration = seconds
        let targetRate = megabitsPerSecond * 1_000_000
        let selectedClient = clientExecutable
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await Iperf3.measure(host: endpoint, port: serverPort, direction: selectedDirection,
                                                      seconds: duration, bitsPerSecond: targetRate, executable: selectedClient)
                guard !Task.isCancelled else {
                    status = t("Cancelled")
                    return
                }
                measurement = result
            } catch let failure as Iperf3.Failure {
                switch failure {
                case .invalidRequest:
                    status = t("Enter an iperf3 server hostname or IP address and a port from 1 to 65535.")
                case .outputTruncated:
                    status = t("iperf3 output exceeded the limit.")
                case .invalidReport:
                    status = t("iperf3 returned an incomplete or unsupported report.")
                case .process(let result):
                    if !result.cleanupCompleted {
                        status = t("iperf3 process cleanup did not complete.")
                        return
                    }
                    if result.cancelled {
                        status = t("Cancelled")
                        return
                    }
                    if result.timedOut {
                        status = t("Timed out")
                        return
                    }
                    switch result.failureCode {
                    case .missingExecutable:
                        status = t(selectedClient == nil ? "iperf3 was not found in the system or Homebrew command locations."
                                   : "Could not open the iperf3 executable.")
                    case .permissionDenied:
                        status = t("macOS denied permission to start iperf3.")
                    case .busy:
                        status = t("The command runner is busy. Try again shortly.")
                    case .launch:
                        status = t("Could not start iperf3.")
                    case nil:
                        status = tf("iperf3 exited with status %d.", result.status)
                    }
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func summary(_ transfer: Iperf3.Transfer) -> String {
        let bytes = transfer.bytes.formatted(.number.locale(Loc.shared.locale))
        return tf("%.2f Mbps · %@ bytes · %.2f s", transfer.bitsPerSecond / 1_000_000, bytes, transfer.seconds)
    }
}

private struct Iperf3ReportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
