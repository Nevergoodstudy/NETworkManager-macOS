import NMCore
import NMRemote
import SwiftUI
import UniformTypeIdentifiers

public struct ConfigurationComparisonView: View {
    @NMStateCompat private var format = ConfigurationComparison.Format.ciscoIOS
    @NMStateCompat private var before: ConfigurationComparison.Input?
    @NMStateCompat private var after: ConfigurationComparison.Input?
    @NMStateCompat private var selectingBefore = true
    @NMStateCompat private var importing = false
    @NMStateCompat private var task: Task<Void, Never>?
    @NMStateCompat private var report: ConfigurationComparison.Report?
    @NMStateCompat private var status: String?
    @NMStateCompat private var host = ""
    @NMStateCompat private var port = "22"
    @NMStateCompat private var username = ""
    @NMStateCompat private var jumpHost = ""

    public init() {}

    public var body: some View {
        Form {
            Picker(t("Configuration format"), selection: $format) {
                ForEach(ConfigurationComparison.Format.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .disabled(task != nil)
            .onChange(of: format) { _, _ in
                if case .capture = before { before = nil }
                if case .capture = after { after = nil }
                report = nil
                status = nil
            }
            LabeledContent(t("Before")) {
                Button(before?.title ?? t("Choose file…"), systemImage: "folder") {
                    selectingBefore = true
                    importing = true
                }
                .disabled(task != nil)
            }
            LabeledContent(t("After")) {
                Button(after?.title ?? t("Choose file…"), systemImage: "folder") {
                    selectingBefore = false
                    importing = true
                }
                .disabled(task != nil)
            }
            DisclosureGroup(t("Read configuration over SSH")) {
                HStack {
                    TextField(t("Host"), text: $host)
                    TextField(t("Port"), text: $port).frame(width: 70)
                    TextField(t("Username (optional)"), text: $username)
                    TextField(t("Jump host (optional)"), text: $jumpHost)
                }
                .disabled(task != nil)
                Text(t("Uses SSH agent authentication and verified SSH host keys."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(t("Read as Before")) { capture(asBefore: true) }
                    Button(t("Read as After")) { capture(asBefore: false) }
                }
                .disabled(task != nil || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button(t("Compare configurations"), systemImage: "arrow.left.arrow.right", action: compare)
                    .disabled(before == nil || after == nil || task != nil)
                if let task {
                    ProgressView().controlSize(.small).accessibilityLabel(t("Running…"))
                    Button(t("Cancel")) { task.cancel() }
                }
            }
            if let status { Text(status).foregroundStyle(.secondary) }
            if let report {
                Section("SHA-256") {
                    LabeledContent(t("Before"), value: report.beforeSHA256)
                    LabeledContent(t("After"), value: report.afterSHA256)
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                Section(t("Configuration changes")) {
                    if report.omittedLinesChanged { Text(t("Sensitive or unsupported lines changed.")).foregroundStyle(.secondary) }
                    if report.changes.isEmpty { Text(t("No changes in displayed commands.")).foregroundStyle(.secondary) }
                    ForEach(report.changes) { change in
                        let marker = change.kind == .added ? "+" : "−"
                        Text("\(marker)\(change.line)  \(change.text)").font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                if selectingBefore { before = .file(url) }
                if !selectingBefore { after = .file(url) }
                report = nil
                status = nil
            case .failure: status = t("Could not read the configuration file.")
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func capture(asBefore: Bool) {
        guard let sshPort = Int(port) else {
            status = SSHCommandBuilder.ValidationError.invalidPort.localizedDescription
            return
        }
        do {
            let selectedFormat = format
            let connection = try SSHCommandBuilder.build(host: host, port: sshPort, username: username, jumpHost: jumpHost)
            let command = selectedFormat == .ciscoIOS ? "show running-config" : "show configuration | display set | no-more"
            let arguments = SSHCommandBuilder.nonInteractive(connection) + [command]
            let job = ProcessJobSpec(operation: .command, targetScope: connection.auditTarget,
                                     deadline: Date().addingTimeInterval(20),
                                     maximumOutputBytesPerStream: ConfigurationComparison.maximumBytes)
            status = nil
            task = Task {
                defer { task = nil }
                let result = await Shell.run(connection.executable, arguments, job: job, environment: ["SSH_ASKPASS_REQUIRE": "never"])
                do {
                    try Task.checkCancellation()
                    let input = try ConfigurationComparison.capture(result, format: selectedFormat, target: connection.auditTarget)
                    if asBefore { before = input }
                    if !asBefore { after = input }
                    report = nil
                } catch ConfigurationComparison.CaptureFailure.timedOut {
                    status = t("Timed out")
                } catch ConfigurationComparison.Failure.limit {
                    status = t("Configuration files are limited to 512 KiB and 2,000 lines each.")
                } catch {
                    status = Task.isCancelled ? t("Diagnostic cancelled") : t("Could not read a complete configuration over SSH.")
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func compare() {
        guard let before, let after else { return }
        let selectedFormat = format
        report = nil
        status = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await ConfigurationComparison.compare(before: before, after: after, format: selectedFormat)
                guard !Task.isCancelled else { return }
                report = result
            } catch ConfigurationComparison.Failure.limit {
                status = t("Configuration files are limited to 512 KiB and 2,000 lines each.")
            } catch ConfigurationComparison.Failure.invalidText {
                status = t("Choose a UTF-8 configuration file.")
            } catch {
                status = t("Could not read the configuration file.")
            }
        }
    }
}
