import NMCore
import SwiftUI

struct FieldInspectionView: View {
    @Binding var project: FieldProject
    @NMStateCompat private var selectedTemplateID: UUID?
    @NMStateCompat private var selectedRecordID: UUID?
    @NMStateCompat private var editingTemplate: FieldInspectionTemplate?
    @NMStateCompat private var editingRecord: FieldInspectionRecord?
    @NMStateCompat private var errorMessage = ""

    private var selectedTemplate: FieldInspectionTemplate? {
        project.inspectionTemplates.first { $0.id == selectedTemplateID }
    }

    private var selectedRecord: FieldInspectionRecord? {
        project.inspectionRecords.first { $0.id == selectedRecordID }
    }

    var body: some View {
        GroupBox(t("Manual inspections")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker(t("Inspection template"), selection: $selectedTemplateID) {
                        Text(t("Not selected")).tag(nil as UUID?)
                        ForEach(project.inspectionTemplates) { template in
                            Text("\(template.title) · \(template.version)").tag(Optional(template.id))
                        }
                    }
                    .accessibilityIdentifier("fieldInspectionTemplatePicker")
                    Button(t("New template"), systemImage: "plus") {
                        editingTemplate = FieldInspectionTemplate(title: "", items: [FieldInspectionTemplateItem(title: "")])
                    }
                    .disabled(project.inspectionTemplates.count >= FieldProject.maximumInspectionTemplates)
                    .accessibilityIdentifier("fieldNewInspectionTemplate")
                    Button(t("Edit template"), systemImage: "pencil") {
                        editingTemplate = selectedTemplate
                    }
                    .disabled(selectedTemplate == nil)
                }
                if let template = selectedTemplate {
                    Text(tf("%d inspection items", template.items.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(t("Start inspection"), systemImage: "checklist") {
                        do {
                            editingRecord = try project.makeInspectionRecord(from: template.id, owner: "")
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(project.inspectionRecords.count >= FieldProject.maximumInspectionRecords)
                    .accessibilityIdentifier("fieldStartInspection")
                }

                Divider()
                if project.inspectionRecords.isEmpty {
                    Text(t("No inspection records yet.")).foregroundStyle(.secondary)
                }
                if !project.inspectionRecords.isEmpty {
                    Picker(t("Inspection record"), selection: $selectedRecordID) {
                        Text(t("Not selected")).tag(nil as UUID?)
                        ForEach(project.inspectionRecords) { record in
                            Text("\(record.templateTitle) · \(Fmt.dateTime(record.recordedAt))").tag(Optional(record.id))
                        }
                    }
                    .accessibilityIdentifier("fieldInspectionRecordPicker")
                    if let record = selectedRecord {
                        recordDetails(record)
                    }
                }
                Text(t("Inspections are manual records and do not start network probes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .onAppear {
            if selectedTemplateID == nil { selectedTemplateID = project.inspectionTemplates.first?.id }
            if selectedRecordID == nil { selectedRecordID = project.inspectionRecords.first?.id }
        }
        .onChange(of: project.inspectionTemplates.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedTemplateID }) { selectedTemplateID = ids.first }
        }
        .onChange(of: project.inspectionRecords.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedRecordID }) { selectedRecordID = ids.first }
        }
        .sheet(item: $editingTemplate) { template in
            FieldInspectionTemplateEditor(
                template: template,
                isNew: !project.inspectionTemplates.contains { $0.id == template.id }
            ) { value in
                try project.saveInspectionTemplate(value)
                selectedTemplateID = value.id
            }
        }
        .sheet(item: $editingRecord) { record in
            FieldInspectionRecordEditor(record: record) { value in
                try project.saveInspectionRecord(value)
                selectedRecordID = value.id
            }
        }
        .fieldProjectError($errorMessage)
    }

    private func recordDetails(_ record: FieldInspectionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(t("Owner")): \(record.owner)").font(.callout)
                    Text("\(Fmt.dateTime(record.recordedAt)) · \(record.templateVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Edit inspection"), systemImage: "pencil") { editingRecord = record }
                    .accessibilityIdentifier("fieldEditInspection")
            }
            ForEach(record.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.title) · \(t(item.effectiveResult.title))")
                        .font(.callout.weight(.medium))
                    if !item.target.isEmpty { Text("\(t("Target")): \(item.target)").font(.caption) }
                    if !item.evidence.isEmpty { Text(item.evidence).font(.callout) }
                    if !item.followUpOwner.isEmpty || item.dueAt != nil {
                        Text("\(t("Follow-up owner")): \(item.followUpOwner) · \(item.dueAt.map(Fmt.dateTime) ?? t("No deadline"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .accessibilityIdentifier("fieldInspectionItem-\(item.id.uuidString)")
                Divider()
            }
        }
        .textSelection(.enabled)
    }
}

private struct FieldInspectionTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var draft: FieldInspectionTemplate
    @NMStateCompat private var errorMessage = ""
    let isNew: Bool
    let onSave: (FieldInspectionTemplate) throws -> Void

    init(template: FieldInspectionTemplate, isNew: Bool, onSave: @escaping (FieldInspectionTemplate) throws -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = NMStateCompat(wrappedValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t(isNew ? "New template" : "Edit template")).font(.title3.weight(.semibold))
            HStack {
                TextField(t("Template title"), text: $draft.title)
                    .accessibilityIdentifier("fieldInspectionTemplateTitle")
                TextField(t("Template version"), text: $draft.version)
                    .frame(width: 120)
                    .accessibilityIdentifier("fieldInspectionTemplateVersion")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($draft.items) { $item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                TextField(t("Inspection item"), text: $item.title)
                                    .accessibilityIdentifier("fieldInspectionItemTitle-\(item.id.uuidString)")
                                Button {
                                    draft.items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(t("Remove inspection item"))
                                .accessibilityLabel(t("Remove inspection item"))
                            }
                            TextField(t("Target"), text: $item.target)
                            TextField(t("Criterion"), text: $item.criterion, axis: .vertical)
                                .lineLimit(1...3)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            Button(t("Add inspection item"), systemImage: "plus") {
                draft.items.append(FieldInspectionTemplateItem(title: ""))
            }
            .disabled(draft.items.count >= FieldInspectionTemplate.maximumItems)
            HStack {
                Button(t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save template")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.items.isEmpty)
                    .accessibilityIdentifier("fieldSaveInspectionTemplate")
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .fieldProjectError($errorMessage)
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FieldInspectionRecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var draft: FieldInspectionRecord
    @NMStateCompat private var errorMessage = ""
    let onSave: (FieldInspectionRecord) throws -> Void

    init(record: FieldInspectionRecord, onSave: @escaping (FieldInspectionRecord) throws -> Void) {
        self.onSave = onSave
        _draft = NMStateCompat(wrappedValue: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Manual inspection record")).font(.title3.weight(.semibold))
            Text("\(draft.templateTitle) · \(draft.templateVersion)").foregroundStyle(.secondary)
            TextField(t("Owner"), text: $draft.owner)
                .accessibilityIdentifier("fieldInspectionOwner")
            DatePicker(t("Recorded at"), selection: $draft.recordedAt)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($draft.items) { $item in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.title).font(.callout.weight(.semibold))
                            if !item.target.isEmpty {
                                Text("\(t("Target")): \(item.target)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !item.criterion.isEmpty {
                                Text("\(t("Criterion")): \(item.criterion)")
                                    .font(.callout)
                            }
                            Picker(t("Assessment"), selection: $item.result) {
                                ForEach(FieldCheckResult.allCases, id: \.self) { result in
                                    Text(t(result.title)).tag(result)
                                }
                            }
                            TextField(t("Evidence and notes"), text: $item.evidence, axis: .vertical)
                                .lineLimit(2...4)
                            if item.effectiveResult != item.result {
                                Label(t("Add a criterion and evidence to record this result."), systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            TextField(t("Follow-up owner"), text: $item.followUpOwner)
                            Toggle(t("Set remediation deadline"), isOn: Binding(
                                get: { item.dueAt != nil },
                                set: { enabled in item.dueAt = enabled ? (item.dueAt ?? Date()) : nil }
                            ))
                            if item.dueAt != nil {
                                DatePicker(t("Remediation due"), selection: Binding(
                                    get: { item.dueAt ?? Date() },
                                    set: { item.dueAt = $0 }
                                ), displayedComponents: .date)
                            }
                        }
                        .accessibilityIdentifier("fieldInspectionEditItem-\(item.id.uuidString)")
                        Divider()
                    }
                }
            }
            HStack {
                Button(t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save inspection")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("fieldSaveInspection")
            }
        }
        .padding(20)
        .frame(width: 640, height: 680)
        .fieldProjectError($errorMessage)
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
