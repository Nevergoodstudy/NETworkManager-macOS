import NMCore
import SwiftUI

struct FieldAcceptanceReportView: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var revisionID: UUID?
    @NMStateCompat private var selection: [UUID: Set<FieldAcceptanceReportField>] = [:]
    @NMStateCompat private var exporting = false
    @NMStateCompat private var exportDocument: FieldProjectReport?
    @NMStateCompat private var errorMessage = ""
    let project: FieldProject

    init(project: FieldProject, revisionID: UUID?) {
        self.project = project
        _revisionID = NMStateCompat(wrappedValue: revisionID)
    }

    private var rows: [(id: UUID, kind: FieldAcceptanceKind)] {
        if let revisionID {
            return project.acceptanceRevisions.first { $0.id == revisionID }?.items.map { ($0.id, $0.item.kind) } ?? []
        }
        return project.acceptanceDraft.items.map { ($0.id, $0.kind) }
    }

    var body: some View {
        let preview = project.acceptanceReport(revisionID: revisionID, selection: selection, translate: t)
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Preview acceptance report")).font(.title2.bold())
            Picker(t("Report source"), selection: Binding(get: { revisionID }, set: { value in
                guard value != revisionID else { return }
                selection = [:]
                revisionID = value
            })) {
                Text(t("Acceptance draft")).tag(nil as UUID?)
                ForEach(project.acceptanceRevisions.reversed()) { version in
                    Text(FieldAcceptanceRevisionView.title(for: version)).tag(Optional(version.id))
                }
            }
            .accessibilityIdentifier("fieldAcceptanceReportSource")
            Text(t("The summary shares statuses and attachment counts. Select individual fields only after reviewing them."))
                .font(.callout)
                .foregroundStyle(.secondary)

            HSplitView {
                FieldAcceptanceReportSelectionView(rows: rows, selection: $selection)
                    .id(revisionID)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 340)
                ScrollView {
                    Text(preview)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .accessibilityIdentifier("fieldAcceptanceReportPreview")
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .frame(minWidth: 360)
            }

            HStack {
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Export report…")) {
                    exportDocument = FieldProjectReport(text: preview)
                    exporting = true
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("fieldExportAcceptanceReport")
            }
        }
        .padding(18)
        .frame(width: 760, height: 540)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentTypes: [.plainText],
            defaultFilename: "NETworkManager-acceptance-report.txt"
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        } onCancellation: {
            exportDocument = nil
        }
        .fieldProjectError($errorMessage)
    }
}

private struct FieldAcceptanceReportSelectionView: View {
    let rows: [(id: UUID, kind: FieldAcceptanceKind)]
    @Binding var selection: [UUID: Set<FieldAcceptanceReportField>]
    @NMStateCompat private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Optional report fields")).font(.headline)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    DisclosureGroup("\(tf("Row %d", Int32(index + 1))) · \(t(row.kind.title))", isExpanded: Binding(get: {
                        expanded.contains(row.id)
                    }, set: { isExpanded in
                        if isExpanded { expanded.insert(row.id) } else { expanded.remove(row.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(FieldAcceptanceReportField.allCases, id: \.self) { field in
                                Toggle(t(field.title), isOn: Binding(get: {
                                    selection[row.id, default: []].contains(field)
                                }, set: { enabled in
                                    if enabled {
                                        selection[row.id, default: []].insert(field)
                                    } else {
                                        selection[row.id, default: []].remove(field)
                                    }
                                }))
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("fieldAcceptanceReport-\(row.id.uuidString)-\(field.rawValue)")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("fieldAcceptanceReportRow-\(row.id.uuidString)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 10)
        }
    }
}
