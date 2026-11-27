import NMCore
import SwiftUI

struct FieldAcceptanceItemView: View {
    let index: Int
    let id: UUID
    @Binding var project: FieldProject
    @Binding var isExpanded: Bool
    let requestRemoval: () -> Void
    let onError: (Error) -> Void
    @NMStateCompat private var showingException = false

    private var item: FieldAcceptanceItem? {
        project.acceptanceDraft.items.first { $0.id == id }
    }

    var body: some View {
        if let item {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    linkedRecords
                    textField("Criterion", \.criterion)
                    textField("Unit", \.unit)
                    textField("Observation conditions", \.conditions)
                    textField("Evidence and notes", \.evidence)
                    Picker(t("Evidence source"), selection: value(\.evidenceSource, default: .engineer)) {
                        ForEach(FieldAcceptanceEvidenceSource.allCases, id: \.self) {
                            Text(t($0.title)).tag($0)
                        }
                    }
                    .accessibilityIdentifier("fieldAcceptanceEvidenceSource-\(id.uuidString)")
                    if item.evidenceSource == .history {
                        Picker(t("Historical evidence check"), selection: value(\.historicalCheck, default: nil)) {
                            Text(t("Not selected")).tag(nil as FieldProjectCheck?)
                            ForEach(FieldProjectCheck.allCases) { check in
                                Text("\(t(check.title)) (\(project[check].attachedDiagnostics.count))").tag(Optional(check))
                            }
                        }
                        .accessibilityIdentifier("fieldAcceptanceHistoricalCheck-\(id.uuidString)")
                        Text(t("Verify that the attached diagnostic targets and measurement conditions match this row."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    textField("Follow-up owner", \.owner)
                    textField("Reason blocked", \.blockedReason)
                    Divider()
                    HStack {
                        Picker(t("Assessment"), selection: Binding(get: {
                            self.item.map { project.acceptanceResult(for: $0) } ?? .pending
                        }, set: { result in
                            do { try project.recordAcceptanceResult(result, for: id) }
                            catch { onError(error) }
                        })) {
                            ForEach(FieldCheckResult.allCases, id: \.self) { result in
                                Text(t(result.title)).tag(result)
                            }
                        }
                        .accessibilityIdentifier("fieldAcceptanceResult-\(id.uuidString)")
                        Spacer()
                        if item.exception != nil {
                            Button(t("Remove exception"), role: .destructive) { value(\.exception, default: nil).wrappedValue = nil }
                                .accessibilityIdentifier("fieldRemoveException-\(id.uuidString)")
                        }
                        Button(t(item.exception == nil ? "Add confirmed exception" : "Review confirmed exception")) {
                            showingException = true
                        }
                        .accessibilityIdentifier("fieldAcceptanceException-\(id.uuidString)")
                    }
                    if let exception = item.exception {
                        Text(exception.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button(t("Remove draft row"), role: .destructive, action: requestRemoval)
                        .accessibilityIdentifier("fieldRemoveAcceptanceRow-\(id.uuidString)")
                }
                .padding(.vertical, 8)
                .padding(.leading, 8)
            } label: {
                HStack {
                    Text(tf("Row %d", Int32(index)))
                        .fontWeight(.medium)
                    if let requirement = project.acceptanceDraft.requirements.first(where: { $0.id == item.requirementID }),
                       !requirement.title.isEmpty {
                        Text(requirement.title).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t(project.acceptanceResult(for: item).title))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("fieldAcceptanceRow-\(id.uuidString)")
            .sheet(isPresented: $showingException) {
                FieldAcceptanceExceptionEditor(initial: item.exception ?? FieldAcceptanceException()) { exception in
                    value(\.exception, default: nil).wrappedValue = exception
                }
            }
        }
    }

    private var linkedRecords: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(t("Requirement"), selection: value(\.requirementID, default: nil)) {
                Text(t("Not selected")).tag(nil as UUID?)
                ForEach(Array(project.acceptanceDraft.requirements.enumerated()), id: \.element.id) { index, requirement in
                    Text(requirement.title.isEmpty ? tf("Requirement %d", Int32(index + 1)) : requirement.title)
                        .tag(Optional(requirement.id))
                }
            }
            .accessibilityIdentifier("fieldAcceptanceRequirement-\(id.uuidString)")
            Picker(t("Measurement point"), selection: value(\.pointID, default: nil)) {
                Text(t("Not selected")).tag(nil as UUID?)
                ForEach(Array(project.acceptanceDraft.points.enumerated()), id: \.element.id) { index, point in
                    Text(point.title.isEmpty ? tf("Measurement point %d", Int32(index + 1)) : point.title)
                        .tag(Optional(point.id))
                }
            }
            .accessibilityIdentifier("fieldAcceptancePoint-\(id.uuidString)")
        }
    }

    private func textField(_ label: String, _ keyPath: WritableKeyPath<FieldAcceptanceItem, String>) -> some View {
        LabeledContent(t(label)) {
            TextField(t(label), text: value(keyPath, default: ""), axis: .vertical)
                .lineLimit(1...4)
                .labelsHidden()
                .accessibilityIdentifier("fieldAcceptance-\(label)-\(id.uuidString)")
        }
    }

    private func value<Value>(_ keyPath: WritableKeyPath<FieldAcceptanceItem, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { item?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let index = project.acceptanceDraft.items.firstIndex(where: { $0.id == id }) else { return }
            project.acceptanceDraft.items[index][keyPath: keyPath] = value
        })
    }
}

private struct FieldAcceptanceExceptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var exception: FieldAcceptanceException
    let save: (FieldAcceptanceException) -> Void

    init(initial: FieldAcceptanceException, save: @escaping (FieldAcceptanceException) -> Void) {
        _exception = NMStateCompat(wrappedValue: initial)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Confirmed exception")).font(.title2.bold())
            TextField(t("Exception note"), text: $exception.note, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("fieldExceptionNote")
            TextField(t("Confirmed by"), text: $exception.confirmedBy)
                .accessibilityIdentifier("fieldExceptionConfirmedBy")
            DatePicker(t("Confirmation date"), selection: $exception.confirmedAt)
                .accessibilityIdentifier("fieldExceptionConfirmedAt")
            TextField(t("Retest plan"), text: $exception.retestPlan, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("fieldExceptionRetestPlan")
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Save exception")) {
                    save(exception)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled([exception.note, exception.confirmedBy, exception.retestPlan].contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                .accessibilityIdentifier("fieldSaveException")
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
