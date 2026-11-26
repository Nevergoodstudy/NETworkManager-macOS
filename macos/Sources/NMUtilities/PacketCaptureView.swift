import NMCore
import SwiftUI
import UniformTypeIdentifiers

public struct PacketCaptureView: View {
    @NMStateCompat private var choosingFile = false
    @NMStateCompat private var task: Task<Void, Never>?
    @NMStateCompat private var summary: PacketCaptureSummary?
    @NMStateCompat private var status: String?
    @NMStateCompat private var exporting = false

    public init() {}

    public var body: some View {
        Form {
            HStack {
                Button(t("Open pcapng…"), systemImage: "folder") { choosingFile = true }
                    .disabled(task != nil)
                if task != nil {
                    ProgressView().controlSize(.small).accessibilityLabel(t("Running…"))
                    Button(t("Cancel")) { task?.cancel() }
                }
            }
            if let status { Text(status).foregroundStyle(.secondary) }
            if let summary {
                Section(t("Packet capture summary")) {
                    LabeledContent(t("Captured packets"), value: summary.packets.formatted())
                    LabeledContent(t("Capture file size"), value: summary.fileBytes.formatted(.byteCount(style: .file)))
                    LabeledContent(t("Capture parser"), value: summary.parser)
                    LabeledContent("SHA-256") {
                        Text(summary.sha256)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(t("Export summary…"), systemImage: "square.and.arrow.up") { exporting = true }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "pcapng") ?? .data]) { result in
            switch result {
            case .success(let url): analyze(url)
            case .failure: status = t("Could not read the selected capture file.")
            }
        }
        .fileExporter(isPresented: $exporting, document: summary.map(PacketCaptureReport.init), contentType: .json,
                      defaultFilename: "NETworkManager-pcapng-summary.json") { result in
            if case .failure = result { status = t("Could not export the capture summary.") }
        }
        .onDisappear { task?.cancel() }
    }

    private func analyze(_ url: URL) {
        summary = nil
        status = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await PacketCaptureSummary.analyze(url)
                try Task.checkCancellation()
                summary = result
            } catch is CancellationError {
                status = t("Cancelled")
            } catch PacketCaptureSummary.Failure.tooLarge {
                status = t("The capture file exceeds 64 MiB.")
            } catch PacketCaptureSummary.Failure.invalidCapture {
                status = t("The pcapng file is damaged or unsupported by this Mac.")
            } catch PacketCaptureSummary.Failure.modifiedDuringRead {
                status = t("The capture file changed during analysis.")
            } catch PacketCaptureSummary.Failure.timedOut {
                status = t("Timed out")
            } catch {
                status = t("Could not read the selected capture file.")
            }
        }
    }
}

private struct PacketCaptureReport: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let summary: PacketCaptureSummary

    init(summary: PacketCaptureSummary) { self.summary = summary }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        summary = try JSONDecoder().decode(PacketCaptureSummary.self, from: bytes)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(summary))
    }
}
