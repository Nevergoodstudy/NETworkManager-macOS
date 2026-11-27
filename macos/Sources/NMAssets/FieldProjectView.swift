import NMCore
import SwiftUI

public struct FieldProjectLandingView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @NMStateCompat private var choosingProject = false
    @NMStateCompat private var searchingIncidents = false
    @NMStateCompat private var showingCaseLibrary = false
    @NMStateCompat private var errorMessage = ""

    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label(t("Field projects"), systemImage: "folder")
        } description: {
            Text(t("Keep the site survey, delivery baseline, and maintenance notes together in one project file."))
        } actions: {
            Button(t("New field project")) { newDocument(FieldProjectDocument()) }
                .buttonStyle(.borderedProminent)
            Button(t("Open field project…")) { choosingProject = true }
            Button(t("Search project incidents")) { searchingIncidents = true }
                .accessibilityIdentifier("fieldSearchProjectIncidents")
            Button(t("Local case library")) { showingCaseLibrary = true }
                .accessibilityIdentifier("fieldOpenCaseLibrary")
        }
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: [FieldProjectDocument.contentType]) { result in
            Task { @MainActor in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try await openDocument(at: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .fieldProjectError($errorMessage)
        .sheet(isPresented: $searchingIncidents) { FieldIncidentCatalogView() }
        .sheet(isPresented: $showingCaseLibrary) { FieldCaseLibraryView() }
    }
}

public struct FieldProjectView: View {
    @Binding private var document: FieldProjectDocument
    @Binding private var pendingMetric: FieldMetricObservation?
    @NMStateCompat private var phase: FieldProjectPhase = .survey
    @NMStateCompat private var showingReport = false
    @NMStateCompat private var acceptanceReport: AcceptanceReportSource?
    @NMStateCompat private var retestPreparation: FieldRetestPreparation?
    @NMStateCompat private var showingMetricAttachment = false
    @NMStateCompat private var metricIncidentID: UUID?
    @NMStateCompat private var metricAuthor = ""
    @NMStateCompat private var metricAttachmentError = ""

    private struct AcceptanceReportSource: Identifiable {
        let id = UUID()
        let revisionID: UUID?
    }

    public init(document: Binding<FieldProjectDocument>, pendingMetric: Binding<FieldMetricObservation?> = .constant(nil)) {
        _document = Binding(get: { document.wrappedValue }, set: { value in
            guard value.project != document.wrappedValue.project else { return }
            document.wrappedValue = value
        })
        _pendingMetric = pendingMetric
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox(t("Field project details")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                TextField(t("Customer"), text: $document.project.customer)
                                TextField(t("Site"), text: $document.project.site)
                            }
                            TextField(t("Project scope"), text: $document.project.projectScope, axis: .vertical)
                                .lineLimit(2...4)
                        }
                        .padding(6)
                    }

                    Picker(t("Project phase"), selection: $phase) {
                        ForEach(FieldProjectPhase.allCases, id: \.self) { phase in
                            Text(t(phase.title)).tag(phase)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch phase {
                    case .survey:
                        FieldAcceptanceSetupView(project: $document.project)
                        FieldAcceptanceDraftView(project: $document.project, kind: .poc)
                    case .acceptance:
                        FieldAcceptanceSetupView(project: $document.project)
                        FieldAcceptanceDraftView(project: $document.project, kind: .acceptance)
                        FieldAcceptanceCreateRevisionView(project: $document.project)
                    case .maintenance:
                        FieldAcceptanceRevisionView(project: $document.project) { revisionID in
                            acceptanceReport = AcceptanceReportSource(revisionID: revisionID)
                        }
                        FieldInspectionView(project: $document.project)
                        FieldIncidentView(project: $document.project) { incident in
                            retestPreparation = FieldRetestPreparation(incident: incident)
                        }
                        FieldRetestView(project: $document.project, preparation: retestPreparation)
                            .id("fieldRetest")
                        let baseline = document.project[.serviceBaseline]
                        if baseline.effectiveResult == .met || baseline.effectiveResult == .notMet {
                            GroupBox(t("Checklist baseline (current draft)")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(baseline.criterion).font(.callout)
                                    Text(baseline.evidence).font(.callout).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(6)
                            }
                        }
                    }

                    ForEach(phase.checks) { check in
                        FieldProjectCheckView(check: check, record: $document.project[check], onAttach: { item, context in
                            var project = document.project
                            try project.attachDiagnostic(
                                FieldProjectDiagnosticEvidence(item: item, networkContext: context),
                                to: check
                            )
                            document.project = project
                        }) { id in
                            document.project.removeDiagnosticEvidence(id: id, from: check)
                        }
                    }
                }
                .frame(maxWidth: 860)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 590, minHeight: 480)
            .onChange(of: retestPreparation) { _, preparation in
                guard preparation != nil else { return }
                withAnimation { proxy.scrollTo("fieldRetest", anchor: .top) }
            }
        }
        .toolbar {
            if pendingMetric != nil {
                Button(t("Attach metric to incident"), systemImage: "paperclip") {
                    metricIncidentID = nil
                    metricAuthor = ""
                    showingMetricAttachment = true
                }
                .disabled(document.project.incidents.isEmpty)
                .accessibilityIdentifier("fieldAttachMetric")
            }
            Button(t("Preview report"), systemImage: "doc.text.magnifyingglass") { showingReport = true }
            if !document.project.acceptanceDraft.items.isEmpty || !document.project.acceptanceRevisions.isEmpty {
                Button(t("Preview acceptance report"), systemImage: "checklist") {
                    acceptanceReport = AcceptanceReportSource(revisionID: nil)
                }
                .accessibilityIdentifier("fieldPreviewAcceptanceReport")
            }
        }
        .sheet(isPresented: $showingReport) { FieldProjectReportView(project: document.project) }
        .sheet(item: $acceptanceReport) { source in
            FieldAcceptanceReportView(project: document.project, revisionID: source.revisionID)
        }
        .sheet(isPresented: $showingMetricAttachment) {
            if let metric = pendingMetric { metricAttachment(metric) }
        }
        .onChange(of: pendingMetric) { _, _ in showingMetricAttachment = false }
    }

    private func metricAttachment(_ metric: FieldMetricObservation) -> some View {
        let candidates = document.project.incidents.filter { $0.entries.count < FieldIncident.maximumEntries }
        let author = metricAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            Text(t("Attach metric to incident")).font(.headline)
            Text("\(metric.itemName) · \(metric.hostName) · \(metric.source)")
                .foregroundStyle(.secondary)
            Picker(t("Incident"), selection: $metricIncidentID) {
                Text(t("Not selected")).tag(nil as UUID?)
                ForEach(candidates) { incident in
                    Text([incident.title, incident.ticketReference, Fmt.dateTime(incident.createdAt)]
                        .filter { !$0.isEmpty }.joined(separator: " · ")).tag(Optional(incident.id))
                }
            }
            TextField(t("Recorded by"), text: $metricAuthor)
            if candidates.isEmpty { Text(t("No incidents have room for another observation.")) }
            HStack {
                Button(t("Discard prepared metric"), role: .destructive) {
                    if pendingMetric == metric { pendingMetric = nil }
                }
                Spacer()
                Button(t("Cancel")) { showingMetricAttachment = false }.keyboardShortcut(.cancelAction)
                Button(t("Attach metric")) {
                    guard let id = metricIncidentID, pendingMetric == metric else { return }
                    do {
                        try document.project.appendIncidentEntry(
                            FieldIncidentEntry(kind: .metricObserved,
                                               occurredAt: Date(timeIntervalSince1970: Double(metric.alertSecond)),
                                               author: author, detail: metric.itemName, metricObservation: metric),
                            to: id
                        )
                        pendingMetric = nil
                        phase = .maintenance
                    } catch { metricAttachmentError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(author.isEmpty || author.count > 120 || !candidates.contains { $0.id == metricIncidentID })
                .accessibilityIdentifier("fieldConfirmMetric")
            }
        }
        .padding(20)
        .frame(width: 540)
        .fieldProjectError($metricAttachmentError)
    }
}

private struct FieldProjectCheckView: View {
    let check: FieldProjectCheck
    @Binding var record: FieldCheckRecord
    let onAttach: (DiagnosticEvidenceItem, String) throws -> Void
    let onRemove: (UUID) -> Void
    @NMStateCompat private var showingDiagnostics = false
    private let limit = FieldProject.maximumDiagnosticEvidencePerCheck

    var body: some View {
        GroupBox(t(check.title)) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(t("Criterion"), text: $record.criterion, axis: .vertical).lineLimit(1...4)
                TextField(t("Evidence and notes"), text: $record.evidence, axis: .vertical).lineLimit(2...6)
                Picker(t("Assessment"), selection: $record.result) {
                    ForEach(FieldCheckResult.allCases, id: \.self) { result in
                        Text(t(result.title)).tag(result)
                    }
                }
                .fixedSize()
                if record.effectiveResult != record.result {
                    Label(t("Add a criterion and evidence to record this result."), systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(t("Attached diagnostic evidence")) (\(record.attachedDiagnostics.count)/\(limit))")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(t("Attach diagnostic"), systemImage: "paperclip") {
                        showingDiagnostics = true
                    }
                    .disabled(record.attachedDiagnostics.count >= limit)
                    .accessibilityIdentifier("attachDiagnostic-\(check.rawValue)")
                }

                ForEach(record.attachedDiagnostics) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.kind) · \(item.status)")
                                .font(.callout.weight(.medium))
                            Text("\(t(item.device)) · \(t(item.target))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("\(Fmt.dateTime(item.startedAt)) · \(item.source)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            onRemove(item.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(t("Remove diagnostic evidence"))
                        .accessibilityLabel(t("Remove diagnostic evidence"))
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("attachedDiagnostic-\(item.runID.uuidString)")
                }
            }
            .padding(6)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticEvidencePicker(
                existingRunIDs: Set(record.attachedDiagnostics.map(\.runID)),
                onAttach: onAttach
            )
        }
    }
}

private struct DiagnosticEvidencePicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var assets = AssetStore.shared
    @NMStateCompat private var search = ""
    @NMStateCompat private var selectedID: UUID?
    @NMStateCompat private var networkContext = ""
    @NMStateCompat private var errorMessage = ""

    let existingRunIDs: Set<UUID>
    let onAttach: (DiagnosticEvidenceItem, String) throws -> Void

    private var items: [DiagnosticEvidenceItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let completedRuns = assets.diagnosticRuns.filter { $0.status != .running }
        return DiagnosticEvidenceExporter.items(runs: completedRuns, devices: assets.devices, useCurrentDeviceAddress: false)
            .filter { item in
                query.isEmpty || [item.device, item.address, item.kind, item.status, item.summary, item.source, item.id.uuidString]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .reversed()
    }

    var body: some View {
        let items = items
        let selectedItem = items.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Choose from completed diagnostic history"))
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(t("Search history"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("fieldDiagnosticSearch")
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if items.isEmpty {
                ContentUnavailableView(t(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No completed diagnostic history" : "No matching diagnostics"), systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(selection: $selectedID) {
                    ForEach(items, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(t(item.device)) · \(item.kind) · \(item.status)")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                if existingRunIDs.contains(item.id) {
                                    Text(t("Already attached"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(t(item.address)) · \(Fmt.dateTime(item.startedAt)) · \(item.source)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !item.summary.isEmpty {
                                Text(item.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
                .accessibilityIdentifier("fieldDiagnosticHistoryList")
            }

            TextField(t("Network context note (optional)"), text: $networkContext, axis: .vertical)
                .lineLimit(2...3)
                .onChange(of: networkContext) { _, value in
                    if value.count > 500 { networkContext = String(value.prefix(500)) }
                }
                .accessibilityIdentifier("fieldDiagnosticNetworkContext")
            Text(t("This context is not stored with the original run. Leave blank if unknown."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("Attach selected record"), systemImage: "paperclip") {
                    guard let selectedID, let selectedItem = self.items.first(where: { $0.id == selectedID }) else { return }
                    do {
                        try onAttach(selectedItem, networkContext)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedItem == nil || selectedItem.map { existingRunIDs.contains($0.id) } == true)
                .accessibilityIdentifier("attachSelectedDiagnostic")
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 520)
        .fieldProjectError($errorMessage)
    }
}

private struct FieldProjectReportView: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var includeDetails = false
    @NMStateCompat private var exporting = false
    @NMStateCompat private var errorMessage = ""
    let project: FieldProject

    private var report: String { project.report(includeDetails: includeDetails, translate: t) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Preview report")).font(.title2.bold())
            Toggle(t("Include customer, site, notes, and diagnostic details"), isOn: $includeDetails)
            ScrollView {
                Text(report)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("Export report…")) { exporting = true }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .fileExporter(isPresented: $exporting, document: FieldProjectReport(text: report), contentType: .plainText,
                      defaultFilename: "NETworkManager-field-report.txt") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .fieldProjectError($errorMessage)
    }
}

extension View {
    func fieldProjectError(_ message: Binding<String>) -> some View {
        alert(t("Field project error"), isPresented: Binding(
            get: { !message.wrappedValue.isEmpty },
            set: { if !$0 { message.wrappedValue = "" } }
        )) {
            Button(t("OK"), role: .cancel) {}
        } message: {
            Text(message.wrappedValue)
        }
    }
}
