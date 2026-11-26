import NMCore
import SwiftUI
import UniformTypeIdentifiers

struct FieldIncidentView: View {
    @Binding var project: FieldProject
    var onPrepareRetest: (FieldIncident) -> Void = { _ in }
    @NMStateCompat private var selectedID: UUID?
    @NMStateCompat private var editingIncident: FieldIncident?
    @NMStateCompat private var addingEntry: FieldIncident?
    @NMStateCompat private var searchText = ""
    @NMStateCompat private var statusFilter: FieldIncidentStatus?
    @NMStateCompat private var choosingCaptureSummary = false
    @NMStateCompat private var captureIncidentID: UUID?
    @NMStateCompat private var errorMessage = ""

    private var visibleIncidents: [FieldIncident] {
        project.incidents.filter(FieldIncidentQuery(text: searchText, status: statusFilter).matches)
    }

    private var selected: FieldIncident? {
        project.incidents.first { $0.id == selectedID }
    }

    var body: some View {
        GroupBox(t("Maintenance incidents")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(t("Record incidents manually and explicitly link saved retests. Timeline entries do not run diagnostics or change the handoff assessment."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(t("New incident"), systemImage: "plus") {
                        editingIncident = FieldIncident(title: "", owner: "", baselineRevisionID: project.maintenanceRevisionID)
                    }
                    .disabled(project.incidents.count >= FieldProject.maximumIncidents)
                    .accessibilityIdentifier("fieldNewIncident")
                }
                if project.incidents.isEmpty {
                    Text(t("No incidents recorded yet.")).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField(t("Search incidents, tickets, owners or notes"), text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("fieldIncidentSearch")
                        Picker(t("Incident status"), selection: $statusFilter) {
                            Text(t("All incident states")).tag(nil as FieldIncidentStatus?)
                            ForEach(FieldIncidentStatus.allCases, id: \.self) { status in
                                Text(t(status.title)).tag(Optional(status))
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    Picker(t("Incident"), selection: $selectedID) {
                        Text(t("Not selected")).tag(nil as UUID?)
                        ForEach(visibleIncidents) { incident in
                            Text("\(incident.title) · \(t(incident.status.title))").tag(Optional(incident.id))
                        }
                    }
                    .accessibilityIdentifier("fieldIncidentPicker")
                    Text(tf("%d matching incidents", visibleIncidents.count)).font(.caption).foregroundStyle(.secondary)
                    if let incident = selected {
                        incidentDetails(incident)
                    }
                }
                Text(t("Save the project to keep timeline changes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .onAppear { if selectedID == nil { selectedID = project.incidents.first?.id } }
        .onChange(of: visibleIncidents.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .sheet(item: $editingIncident) { incident in
            FieldIncidentEditor(project: project, incident: incident,
                                isNew: !project.incidents.contains { $0.id == incident.id }) { value in
                try project.saveIncident(value)
                selectedID = value.id
            }
        }
        .sheet(item: $addingEntry) { incident in
            FieldIncidentEntryEditor(incident: incident, retests: project.retestRuns) { entry in
                try project.appendIncidentEntry(entry, to: incident.id)
            }
        }
        .fileImporter(isPresented: $choosingCaptureSummary, allowedContentTypes: [.json]) { result in
            guard let incidentID = captureIncidentID else { return }
            captureIncidentID = nil
            do {
                try importCaptureSummary(result.get(), incidentID: incidentID)
            } catch {
                errorMessage = t("Could not import the capture summary.") + " " + error.localizedDescription
            }
        }
        .fieldProjectError($errorMessage)
    }

    private func incidentDetails(_ incident: FieldIncident) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(t("Owner"), value: incident.owner)
            if !incident.ticketReference.isEmpty {
                LabeledContent(t("External ticket reference"), value: incident.ticketReference)
            }
            FieldIncidentAssociationView(project: project, incident: incident)
            HStack {
                Button(t("Edit incident")) { editingIncident = incident }
                    .accessibilityIdentifier("fieldEditIncident")
                Button(t("Prepare retest"), systemImage: "arrow.uturn.forward") {
                    onPrepareRetest(incident)
                }
                .accessibilityIdentifier("fieldPrepareIncidentRetest")
                Button(t("Import capture summary…"), systemImage: "square.and.arrow.down") {
                    captureIncidentID = incident.id
                    choosingCaptureSummary = true
                }
                .disabled(incident.entries.count >= FieldIncident.maximumEntries)
                .accessibilityIdentifier("fieldImportCaptureSummary")
                Spacer()
                Text("\(t("Timeline entries")) (\(incident.entries.count)/\(FieldIncident.maximumEntries))")
                    .font(.caption)
                Button(t("Add timeline entry"), systemImage: "plus.bubble") { addingEntry = incident }
                    .disabled(incident.entries.count >= FieldIncident.maximumEntries)
                    .accessibilityIdentifier("fieldAddIncidentEntry")
            }
            ForEach(incident.timeline) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Fmt.dateTime(entry.occurredAt)) · \(t(entry.title))")
                        .font(.callout.weight(.semibold))
                    let author = entry.packetCaptureSummary == nil ? entry.author : t(entry.author)
                    Text("\(t(entry.packetCaptureSummary == nil ? "Recorded at" : "Imported at")): \(Fmt.dateTime(entry.recordedAt)) · \(author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let metric = entry.metricObservation { FieldMetricObservationView(metric: metric) }
                    if let capture = entry.packetCaptureSummary {
                        FieldPacketCaptureSummaryView(summary: capture)
                        Button(t("Remove capture summary"), systemImage: "trash", role: .destructive) {
                            do {
                                try project.removePacketCaptureSummary(entry.id, from: incident.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("fieldRemoveCaptureSummary")
                    }
                    if entry.metricObservation == nil && entry.packetCaptureSummary == nil {
                        Text(entry.detail).font(.callout)
                    }
                    if let run = project.retestRuns.first(where: { $0.id == entry.retestRunID }) {
                        Text("\(t("Attached retest result")): \(t(run.status.title)) · \(run.actualTarget) · \(Fmt.dateTime(run.startedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
                .accessibilityIdentifier("fieldIncidentEntry-\(entry.id.uuidString)")
            }
        }
        .textSelection(.enabled)
    }

    private func importCaptureSummary(_ url: URL, incidentID: UUID) throws {
        let summary = try PacketCaptureSummary.importJSON(from: url)
        let importedAt = Date()
        try project.appendIncidentEntry(
            FieldIncidentEntry(kind: .note, occurredAt: importedAt, recordedAt: importedAt, author: "Local import",
                               detail: "Packet capture summary", packetCaptureSummary: summary), to: incidentID)
    }
}

struct FieldPacketCaptureSummaryView: View {
    let summary: PacketCaptureSummary

    var body: some View {
        LabeledContent(t("Captured packets"), value: summary.packets.formatted())
        LabeledContent(t("Capture file size"), value: summary.fileBytes.formatted(.byteCount(style: .file)))
        LabeledContent(t("Capture parser"), value: summary.parser)
        LabeledContent("SHA-256") {
            Text(summary.sha256).font(.caption.monospaced())
        }
    }
}

struct FieldMetricObservationView: View {
    private struct Row: Identifiable { let id: Int }
    let metric: FieldMetricObservation

    var body: some View {
        let start = Fmt.dateTime(Date(timeIntervalSince1970: Double(metric.window.lowerBound)))
        let end = Fmt.dateTime(Date(timeIntervalSince1970: Double(metric.window.upperBound)))
        DisclosureGroup(metric.itemName) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(t("Source"), value: metric.source)
                LabeledContent(t("Host"), value: "\(metric.hostName) · \(metric.hostID)")
                LabeledContent(t("Monitoring item"), value: metric.itemID)
                Text(tf("Event %@ · %@", metric.eventID, Fmt.dateTime(Date(timeIntervalSince1970: Double(metric.alertSecond)))))
                LabeledContent(t("Query time"), value: Fmt.dateTime(metric.queriedAt))
                LabeledContent(t("Time window"), value: "\(start) – \(end) · \(TimeZone.current.identifier)")
                LabeledContent(t("Unit"), value: metric.unit.isEmpty ? "–" : metric.unit)
                LabeledContent(t("Configured interval"), value: metric.configuredInterval.isEmpty ? "–" : metric.configuredInterval)
                ForEach(metric.states, id: \.self) { Text(t($0)).font(.caption) }
                if !metric.samples.isEmpty {
                    Table(metric.samples.indices.map { Row(id: $0) }) {
                        TableColumn(t("Unix timestamp")) { Text(metric.samples[$0.id].timestamp).monospacedDigit() }
                        TableColumn(t("Value")) { Text(metric.samples[$0.id].rawValue).monospacedDigit() }
                    }
                    .frame(height: 180)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("fieldMetricObservation")
    }
}

struct FieldIncidentAssociationView: View {
    let project: FieldProject
    let incident: FieldIncident

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let revision = project.acceptanceRevisions.first(where: { $0.id == incident.baselineRevisionID }) {
                LabeledContent(t("Handoff revision"), value: FieldAcceptanceRevisionView.title(for: revision))
            } else {
                Text(t("No handoff revision associated")).foregroundStyle(.secondary)
            }
            if let asset = incident.asset {
                LabeledContent(t("Associated asset snapshot"), value: "\(asset.name) · \(asset.address)")
                if let identity = asset.externalIdentity {
                    Text("\(t("Remote object")): \(identity.instance) · \(identity.objectType) · \(identity.remoteID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(t("No asset associated")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct FieldIncidentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var assets = AssetStore.shared
    @NMStateCompat private var draft: FieldIncident
    @NMStateCompat private var assetID: UUID?
    @NMStateCompat private var errorMessage = ""
    let project: FieldProject
    let isNew: Bool
    let onSave: (FieldIncident) throws -> Void

    init(project: FieldProject, incident: FieldIncident, isNew: Bool,
         onSave: @escaping (FieldIncident) throws -> Void) {
        self.project = project
        self.isNew = isNew
        self.onSave = onSave
        _draft = NMStateCompat(wrappedValue: incident)
    }

    private var availableAssets: [AssetDevice] {
        guard let workspace = assets.primaryWorkspace else { return [] }
        let siteIDs = Set(assets.sites(in: workspace.id).map(\.id))
        return assets.devices.filter { siteIDs.contains($0.siteID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(isNew ? "New incident" : "Edit incident")).font(.title3.weight(.semibold))
            TextField(t("Incident title"), text: $draft.title)
                .accessibilityIdentifier("fieldIncidentTitle")
            TextField(t("Owner"), text: $draft.owner)
                .accessibilityIdentifier("fieldIncidentOwner")
            TextField(t("External ticket reference"), text: $draft.ticketReference)
                .accessibilityIdentifier("fieldIncidentTicket")
            Picker(t("Incident status"), selection: $draft.status) {
                ForEach(FieldIncidentStatus.allCases, id: \.self) { status in
                    Text(t(status.title)).tag(status)
                }
            }
            if isNew {
                Picker(t("Handoff revision"), selection: $draft.baselineRevisionID) {
                    Text(t("Not selected")).tag(nil as UUID?)
                    ForEach(project.acceptanceRevisions) { revision in
                        Text(FieldAcceptanceRevisionView.title(for: revision)).tag(Optional(revision.id))
                    }
                }
                .accessibilityIdentifier("fieldIncidentBaseline")
                Picker(t("Associated asset snapshot"), selection: $assetID) {
                    Text(t("Not selected")).tag(nil as UUID?)
                    ForEach(availableAssets) { asset in
                        let site = assets.sites.first { $0.id == asset.siteID }?.name ?? ""
                        Text("\(site) · \(asset.name) · \(asset.address)").tag(Optional(asset.id))
                    }
                }
                .accessibilityIdentifier("fieldIncidentAsset")
            } else {
                FieldIncidentAssociationView(project: project, incident: draft)
            }
            Text(t("The associated revision and asset snapshot are fixed when the incident is created. Later asset changes do not rewrite this record."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Save incident")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              draft.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("fieldSaveIncident")
            }
        }
        .padding(20)
        .frame(width: 560)
        .fieldProjectError($errorMessage)
    }

    private func save() {
        do {
            var value = draft
            if isNew {
                if let assetID {
                    guard let device = availableAssets.first(where: { $0.id == assetID }) else {
                        throw FieldIncidentError.invalidReference
                    }
                    value.asset = FieldIncidentAssetReference(device: device)
                } else {
                    value.asset = nil
                }
            }
            try onSave(value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FieldIncidentEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var entry: FieldIncidentEntry
    @NMStateCompat private var errorMessage = ""
    let incident: FieldIncident
    let retests: [FieldRetestRecord]
    let onSave: (FieldIncidentEntry) throws -> Void

    init(incident: FieldIncident, retests: [FieldRetestRecord], onSave: @escaping (FieldIncidentEntry) throws -> Void) {
        self.incident = incident
        self.retests = retests
        self.onSave = onSave
        _entry = NMStateCompat(wrappedValue: FieldIncidentEntry(kind: .reported, author: incident.owner, detail: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Add timeline entry")).font(.title3.weight(.semibold))
            Text(incident.title).foregroundStyle(.secondary)
            Picker(t("Entry type"), selection: $entry.kind) {
                ForEach(FieldIncidentEntryKind.allCases.filter { $0 != .metricObserved }, id: \.self) { kind in
                    Text(t(kind.title)).tag(kind)
                }
            }
            .accessibilityIdentifier("fieldIncidentEntryKind")
            .onChange(of: entry.kind) { _, kind in
                if kind != .retested { entry.retestRunID = nil }
            }
            DatePicker(t("Occurred at"), selection: $entry.occurredAt, displayedComponents: [.date, .hourAndMinute])
            TextField(t("Recorded by"), text: $entry.author)
                .accessibilityIdentifier("fieldIncidentEntryAuthor")
            TextField(t("Evidence and notes"), text: $entry.detail, axis: .vertical)
                .lineLimit(4...8)
                .accessibilityIdentifier("fieldIncidentEntryDetail")
            if entry.kind == .retested {
                Picker(t("Attached retest result"), selection: $entry.retestRunID) {
                    Text(t("Manual entry without a diagnostic link")).tag(nil as UUID?)
                    ForEach(retests.filter { $0.request.baselineRevisionID == incident.baselineRevisionID }) { run in
                        Text("\(Fmt.dateTime(run.startedAt)) · \(t(run.status.title)) · \(run.actualTarget)")
                            .tag(Optional(run.id))
                    }
                }
                .accessibilityIdentifier("fieldIncidentRetestLink")
                Text(t("Only saved retests for this incident's handoff revision are offered. Linking a result does not run a new retest."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Add entry")) {
                    do {
                        var value = entry
                        value.recordedAt = Date()
                        try onSave(value)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          entry.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("fieldSaveIncidentEntry")
            }
        }
        .padding(20)
        .frame(width: 580)
        .fieldProjectError($errorMessage)
    }
}
