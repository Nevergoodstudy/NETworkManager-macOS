import NMCore
import SwiftUI

struct FieldAcceptanceCreateRevisionView: View {
    @Binding var project: FieldProject
    @NMStateCompat private var confirming = false
    @NMStateCompat private var status = ""
    @NMStateCompat private var errorMessage = ""

    var body: some View {
        GroupBox(t("Handoff revisions")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(t("Save the draft as a read-only handoff revision. This does not certify customer approval."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(t("Create handoff revision…"), systemImage: "tray.and.arrow.down") { confirming = true }
                        .disabled(project.acceptanceRevisions.count >= FieldProject.maximumAcceptanceRevisions)
                        .accessibilityIdentifier("fieldCreateHandoffRevision")
                }
                Text("\(project.acceptanceRevisions.count)/\(FieldProject.maximumAcceptanceRevisions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !status.isEmpty {
                    Label(status, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("fieldHandoffRevisionStatus")
                }
            }
            .padding(6)
        }
        .confirmationDialog(t("Create a read-only handoff revision?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(t("Create revision")) {
                do {
                    try project.createAcceptanceRevision()
                    status = tf("Handoff revision %d created. Save the project to keep it.", Int32(project.acceptanceRevisions.count))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("fieldConfirmHandoffRevision")
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("Unassessed and blocked rows remain as recorded. Future draft edits will not change this version."))
        }
        .fieldProjectError($errorMessage)
    }
}

struct FieldAcceptanceRevisionView: View {
    @Binding var project: FieldProject
    let openReport: (UUID) -> Void

    var body: some View {
        GroupBox(t("Handoff baseline")) {
            VStack(alignment: .leading, spacing: 10) {
                if project.acceptanceRevisions.isEmpty {
                    Text(t("No handoff revisions saved yet.")).foregroundStyle(.secondary)
                } else {
                    Picker(t("Handoff revision"), selection: $project.maintenanceRevisionID) {
                        Text(t("Not selected")).tag(nil as UUID?)
                        ForEach(project.acceptanceRevisions.reversed()) { version in
                            Text(Self.title(for: version)).tag(Optional(version.id))
                        }
                    }
                    .accessibilityIdentifier("fieldMaintenanceBaselinePicker")
                    if let version = project.maintenanceRevision {
                        LabeledContent(t("Plan version"), value: version.planVersion)
                            .accessibilityIdentifier("fieldMaintenancePlanVersion")
                            .textSelection(.enabled)
                        LabeledContent(t("Created at"), value: Fmt.dateTime(version.createdAt))
                        Text(t("Read-only handoff snapshot"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FieldAcceptanceSnapshotRows(rows: version.items)
                            .id(version.id)
                        Button(t("Preview acceptance report"), systemImage: "doc.text.magnifyingglass") { openReport(version.id) }
                            .accessibilityIdentifier("fieldPreviewHandoffReport")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    static func title(for version: FieldAcceptanceRevision) -> String {
        "\(tf("Handoff revision %d", Int32(version.number))) · \(version.planVersion)"
    }
}

private struct FieldAcceptanceSnapshotRows: View {
    let rows: [FieldAcceptanceSnapshotItem]
    @NMStateCompat private var showDetails = false

    var body: some View {
        DisclosureGroup(t("Review snapshot rows"), isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(tf("Row %d", Int32(index + 1))) · \(t(row.item.kind.title)) · \(t(row.result.title))")
                            .font(.headline)
                        field("Requirement", row.requirement)
                        field("Measurement point", row.point)
                        field("Criterion", [row.item.criterion, row.item.unit].filter { !$0.isEmpty }.joined(separator: " · "))
                        field("Observation conditions", row.item.conditions)
                        field("Evidence source", t(row.item.evidenceSource.title))
                        field("Evidence and notes", row.item.evidence)
                        field("Follow-up owner", row.item.owner)
                        field("Reason blocked", row.item.blockedReason)
                        if let exception = row.item.exception {
                            field("Confirmed exception", exception.note)
                            field("Confirmed by", exception.confirmedBy)
                            field("Confirmation date", Fmt.dateTime(exception.confirmedAt))
                            field("Retest plan", exception.retestPlan)
                        }
                        ForEach(row.diagnostics) { diagnostic in
                            field("Diagnostic run", "\(diagnostic.kind) · \(diagnostic.status) · \(diagnostic.target)")
                            field("Measured at", Fmt.dateTime(diagnostic.startedAt))
                            field("Source", diagnostic.source)
                            field("Summary", diagnostic.summary)
                            field("Address family", t(diagnostic.addressFamily.title))
                            field("Context note (added when attaching)", diagnostic.networkContext)
                        }
                    }
                    .accessibilityIdentifier("fieldSnapshotRow-\(row.id.uuidString)")
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityIdentifier("fieldMaintenanceBaselineDetails")
        }
        .accessibilityIdentifier("fieldReviewSnapshotRows")
    }

    @ViewBuilder
    private func field(_ title: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent(t(title), value: value)
        }
    }
}
