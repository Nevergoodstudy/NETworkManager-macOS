import NMCore
import SwiftUI

struct FieldAcceptanceSetupView: View {
    @Binding var project: FieldProject

    var body: some View {
        GroupBox(t("Acceptance preparation")) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(t("Plan version")) {
                    TextField(t("Plan version"), text: $project.acceptanceDraft.planVersion)
                        .labelsHidden()
                        .accessibilityIdentifier("fieldAcceptancePlanVersion")
                }
                collectionHeader("Requirements", add: "Add requirement", id: "fieldAddRequirement",
                                 count: project.acceptanceDraft.requirements.count,
                                 limit: FieldAcceptanceDraft.maximumRequirements) {
                    project.acceptanceDraft.requirements.append(FieldRequirement())
                }
                ForEach($project.acceptanceDraft.requirements) { $requirement in
                    let id = requirement.id
                    let isLinked = project.acceptanceDraft.items.contains { $0.requirementID == id }
                    nameRow("Requirement", title: $requirement.title, id: "fieldRequirement-\(id.uuidString)",
                            remove: "Remove requirement", isLinked: isLinked) {
                        project.acceptanceDraft.requirements.removeAll { $0.id == id }
                    }
                }
                Divider()
                collectionHeader("Measurement points", add: "Add measurement point", id: "fieldAddMeasurementPoint",
                                 count: project.acceptanceDraft.points.count,
                                 limit: FieldAcceptanceDraft.maximumPoints) {
                    project.acceptanceDraft.points.append(FieldMeasurementPoint())
                }
                ForEach($project.acceptanceDraft.points) { $point in
                    let id = point.id
                    let isLinked = project.acceptanceDraft.items.contains { $0.pointID == id }
                    nameRow("Measurement point", title: $point.title, id: "fieldMeasurementPoint-\(id.uuidString)",
                            remove: "Remove measurement point", isLinked: isLinked) {
                        project.acceptanceDraft.points.removeAll { $0.id == id }
                    }
                }
            }
            .padding(6)
        }
    }

    private func collectionHeader(_ title: String, add: String, id: String, count: Int, limit: Int,
                                  action: @escaping () -> Void) -> some View {
        HStack {
            Text(t(title)).font(.headline)
            Text("\(count)/\(limit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button(t(add), systemImage: "plus", action: action)
                .disabled(count >= limit)
                .accessibilityIdentifier(id)
        }
    }

    private func nameRow(_ label: String, title: Binding<String>, id: String, remove: String, isLinked: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack {
            TextField(t(label), text: title)
                .accessibilityIdentifier(id)
            Button(t(remove), systemImage: "minus.circle", action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(t(isLinked ? "Remove this reference from the acceptance rows before deleting it." : remove))
                .disabled(isLinked)
                .accessibilityIdentifier("\(id)-remove")
        }
    }
}

struct FieldAcceptanceDraftView: View {
    @Binding var project: FieldProject
    @NMStateCompat private var expanded: Set<UUID> = []
    @NMStateCompat private var errorMessage = ""
    @NMStateCompat private var pendingRemoval: UUID?
    let kind: FieldAcceptanceKind

    var body: some View {
        GroupBox(t(kind.title)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(project.acceptanceDraft.items.count)/\(FieldAcceptanceDraft.maximumItems)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(t("Rows in the draft"))
                    Spacer()
                    Button(t(kind == .poc ? "Add PoC row" : "Add acceptance row"), systemImage: "plus") {
                        let item = FieldAcceptanceItem(kind: kind)
                        project.acceptanceDraft.items.append(item)
                        expanded.insert(item.id)
                    }
                    .disabled(project.acceptanceDraft.items.count >= FieldAcceptanceDraft.maximumItems)
                    .accessibilityIdentifier(kind == .poc ? "fieldAddPoCRow" : "fieldAddAcceptanceRow")
                }

                let rows = project.acceptanceDraft.items.filter { $0.kind == kind }
                if rows.isEmpty {
                    Text(t(kind == .poc ? "No PoC rows" : "No acceptance rows"))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    FieldAcceptanceItemView(
                        index: index + 1, id: item.id, project: $project,
                        isExpanded: Binding(get: { expanded.contains(item.id) }, set: {
                            if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) }
                        }),
                        requestRemoval: { pendingRemoval = item.id },
                        onError: { errorMessage = $0.localizedDescription }
                    )
                }
            }
            .padding(6)
        }
        .confirmationDialog(t("Remove this draft row?"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button(t("Remove"), role: .destructive) {
                guard let id = pendingRemoval else { return }
                project.acceptanceDraft.items.removeAll { $0.id == id }
                expanded.remove(id)
                pendingRemoval = nil
            }
            Button(t("Cancel"), role: .cancel) { pendingRemoval = nil }
        }
        .fieldProjectError($errorMessage)
    }
}
