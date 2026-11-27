import NMCore
import SwiftUI
import UniformTypeIdentifiers

struct FieldIncidentSearchFilters: View {
    @Binding var text: String
    @Binding var status: FieldIncidentStatus?
    @Binding var asset: FieldIncidentAssetReference?
    @Binding var filteringDates: Bool
    @Binding var from: Date
    @Binding var through: Date
    let ticketReference: String?
    let onClearTicket: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(t("Search incidents, tickets, owners or notes"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("fieldCatalogSearch")
                Picker(t("Incident status"), selection: $status) {
                    Text(t("All incident states")).tag(nil as FieldIncidentStatus?)
                    ForEach(FieldIncidentStatus.allCases, id: \.self) { value in
                        Text(t(value.title)).tag(Optional(value))
                    }
                }
                .frame(maxWidth: 220)
            }
            HStack {
                Toggle(t("Filter by occurrence time"), isOn: $filteringDates).toggleStyle(.checkbox)
                if filteringDates {
                    DatePicker(t("From"), selection: $from, displayedComponents: [.date, .hourAndMinute])
                    DatePicker(t("Through"), selection: $through, displayedComponents: [.date, .hourAndMinute])
                }
                Spacer()
                if let asset {
                    Text("\(t("Associated asset snapshot")): \(asset.name)").font(.caption)
                    Button(t("Clear asset filter")) { self.asset = nil }
                }
            }
            if let ticketReference {
                HStack {
                    Text(tf("Exact ticket: %@", ticketReference)).font(.caption)
                    Button(t("Clear ticket filter"), action: onClearTicket)
                }
                .help(t("Matches the whole ticket, case-sensitive, ignoring surrounding whitespace. The selected case is excluded."))
                .accessibilityIdentifier("fieldTicketFilter")
            }
        }
    }

}

struct FieldIncidentSearchDetailView: View {
    @Environment(\.openDocument) private var openDocument
    @NMStateCompat private var errorMessage = ""
    @NMStateCompat private var exportFormat: FieldIncidentExportFormat = .markdown
    @NMStateCompat private var exportData = Data()
    @NMStateCompat private var exportPreview = ""
    @NMStateCompat private var showingExporter = false
    let result: FieldIncidentSearchResult
    let onFindAsset: (FieldIncidentAssetReference) -> Void
    let onFindTicket: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.incident.title).font(.title3.bold())
            LabeledContent(t("Source file"), value: result.source.label)
            LabeledContent(t("Snapshot loaded at"), value: Fmt.dateTime(result.source.loadedAt))
            LabeledContent(t("Site"), value: result.source.project.site)
            LabeledContent(t("Incident status"), value: t(result.incident.status.title))
            LabeledContent(t("Owner"), value: result.incident.owner)
            LabeledContent(t("External ticket reference")) {
                if !result.incident.ticketReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(result.incident.ticketReference, action: onFindTicket)
                        .buttonStyle(.link)
                        .help(t("Find other cases with this ticket"))
                        .accessibilityLabel(tf("Find other cases for ticket %@", result.incident.ticketReference))
                        .accessibilityIdentifier("fieldFindTicket")
                }
            }
            FieldIncidentAssociationView(project: result.source.project, incident: result.incident)
            HStack {
                Button(t("Open source project")) { open(result.source.id) }
                if let reference = result.incident.asset {
                    Button(t("Find incidents for this asset")) { onFindAsset(reference) }
                }
            }
            Divider()
            ForEach(result.incident.timeline) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Fmt.dateTime(entry.occurredAt)) · \(t(entry.title))").font(.headline)
                    let author = entry.packetCaptureSummary == nil ? entry.author : t(entry.author)
                    Text("\(t(entry.packetCaptureSummary == nil ? "Recorded at" : "Imported at")): \(Fmt.dateTime(entry.recordedAt)) · \(author)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let metric = entry.metricObservation { FieldMetricObservationView(metric: metric) }
                    if let capture = entry.packetCaptureSummary { FieldPacketCaptureSummaryView(summary: capture) }
                    if entry.metricObservation == nil && entry.packetCaptureSummary == nil { Text(entry.detail) }
                    if let run = result.source.project.retestRuns.first(where: { $0.id == entry.retestRunID }) {
                        Text("\(t("Attached retest result")): \(t(run.status.title)) · \(run.actualTarget)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            exportControls
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        .fieldProjectError($errorMessage)
        .onAppear(perform: updateExportPreview)
        .onChange(of: exportFormat) { _, _ in updateExportPreview() }
        .onChange(of: result.id) { _, _ in updateExportPreview() }
        .fileExporter(isPresented: $showingExporter,
                      document: FieldIncidentExportFile(data: exportData),
                      contentType: exportFormat == .markdown ? .plainText : .json,
                      defaultFilename: "NETworkManager-incident.\(exportFormat.fileExtension)") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private var exportControls: some View {
        DisclosureGroup(t("Preview case export")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(t("Export format"), selection: $exportFormat) {
                        ForEach(FieldIncidentExportFormat.allCases) { format in
                            Text(t(format.title)).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                    Button(t("Export…"), systemImage: "square.and.arrow.up") {
                        updateExportPreview()
                        showingExporter = true
                    }
                    .accessibilityIdentifier("fieldIncidentExport")
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(exportPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 140, idealHeight: 220, maxHeight: 300)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("fieldIncidentExportPreview")
            }
            .padding(.top, 8)
        }
    }

    private func updateExportPreview() {
        do {
            exportData = try FieldIncidentExporter.data(for: result.incident,
                                                        retestRuns: result.source.project.retestRuns,
                                                        format: exportFormat)
            exportPreview = String(decoding: exportData, as: UTF8.self)
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    private func open(_ sourceID: String) {
        guard let url = URL(string: sourceID) else { return }
        Task { @MainActor in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do { try await openDocument(at: url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct FieldIncidentExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
