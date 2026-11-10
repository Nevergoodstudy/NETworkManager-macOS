import SwiftUI
import NMCore

/// Presentation stays separate from the stable inventory reason codes.
struct SocketInventoryResultsView: View {
    let result: SocketInventoryResult
    let scope: SocketInventoryScope
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch result.state {
            case .loaded:
                socketTable
            case .empty:
                ContentUnavailableView(t(emptyTitle), systemImage: "network")
                    .frame(minHeight: 420)
                    .accessibilityIdentifier("socketInventoryEmpty")
            case .partial:
                issueSummary(title: "Socket data may be incomplete", color: palette.warning)
                if result.entries.isEmpty {
                    Text(t("No matching rows were found in this partial result."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    socketTable
                }
            case .unavailable:
                issueSummary(title: "Socket inventory unavailable", color: palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 240)
            }
            if !result.issues.isEmpty { commandDetails }
        }
        .accessibilityIdentifier("socketInventoryResults")
    }

    private var emptyTitle: String {
        switch scope {
        case .connections: return "No visible connections found"
        case .listeners: return "No visible listening ports found"
        case .all: return "No visible sockets found"
        }
    }

    private var socketTable: some View {
        Table(result.entries) {
            TableColumn(t("Process")) { Text("\($0.command) (\($0.pid))") }
            TableColumn(t("Protocol")) { Text("\($0.transport) / \($0.family)") }
            TableColumn(t("Local")) { Text($0.localAddress).font(.body.monospaced()) }
            TableColumn(t("Remote")) { Text($0.remoteAddress).font(.body.monospaced()) }
            TableColumn(t("Status")) { Text($0.state.isEmpty ? t("Unknown") : $0.state) }
        }
        .frame(minHeight: 420)
        .accessibilityIdentifier("socketInventoryTable")
    }

    private func issueSummary(title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(t(title), systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(color)
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                Text(t(message(for: issue)))
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("socketInventoryIssues")
    }

    private var commandDetails: some View {
        DisclosureGroup(t("Collection details")) {
            VStack(alignment: .leading, spacing: 8) {
                if result.command.status >= 0 {
                    Text(tf("Command exit status: %d", result.command.status))
                }
                if result.unrecognizedRecordCount > 0 {
                    Text(tf("Unrecognized record(s): %d", result.unrecognizedRecordCount))
                }
                if !result.command.stderr.isEmpty {
                    ScrollView {
                        Text(result.command.stderr)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            .font(.callout)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("socketInventoryDetails")
    }

    private func message(for issue: SocketInventoryIssue) -> String {
        switch issue {
        case .missingExecutable: return "The macOS lsof command could not be found."
        case .permissionDenied: return "macOS denied permission to start lsof."
        case .busy: return "The command runner is busy. Try refreshing shortly."
        case .launchFailed: return "The lsof command could not be started."
        case .executionFailed: return "The lsof command exited with an error."
        case .timedOut: return "Socket collection timed out."
        case .cancelled: return "Socket collection was cancelled."
        case .outputTruncated: return "The collection reached its output limit; some data was discarded."
        case .cleanupIncomplete: return "The command did not finish cleanup. This result may be incomplete."
        case .unrecognizedOutput: return "Some lsof output could not be read."
        case .unclassifiedTCPState: return "Some TCP sockets did not report a recognized state and could not be classified."
        case .commandWarning: return "The lsof command reported a message. See collection details."
        }
    }
}
