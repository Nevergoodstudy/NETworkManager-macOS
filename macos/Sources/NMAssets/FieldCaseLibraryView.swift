import NMCore
import SwiftUI

struct FieldCaseLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FieldCaseLibraryModel()
    @NMStateCompat private var choosingFiles = false
    @NMStateCompat private var text = ""
    @NMStateCompat private var status: FieldIncidentStatus?
    @NMStateCompat private var asset: FieldIncidentAssetReference?
    @NMStateCompat private var ticketReference: String?
    @NMStateCompat private var excludingCaseID: FieldIncidentSearchResult.ID?
    @NMStateCompat private var filteringDates = false
    @NMStateCompat private var from = Date().addingTimeInterval(-30 * 86_400)
    @NMStateCompat private var through = Date()
    @NMStateCompat private var pageIndex = 0
    @NMStateCompat private var selectedID: FieldIncidentSearchResult.ID?
    @NMStateCompat private var removingSource: FieldCaseSource?
    @NMStateCompat private var errorMessage = ""

    private var query: FieldIncidentQuery {
        FieldIncidentQuery(text: text, status: status, asset: asset,
                           occurredFrom: filteringDates ? from : nil, occurredThrough: filteringDates ? through : nil,
                           ticketReference: ticketReference, excludingCaseID: excludingCaseID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Local case library")).font(.title2.bold())
                Spacer()
                Button(t("Import project snapshots…")) { choosingFiles = true }
                    .disabled(model.isLoading || model.isImporting || !model.loadError.isEmpty)
                    .accessibilityIdentifier("fieldCaseLibraryImport")
                Button(t("Reload library")) { model.reload(query, pageIndex: pageIndex) }
                    .disabled(model.isImporting)
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(t("Imported project copies stay on this Mac after closing the app. Choose saved files explicitly; refresh a source to update its snapshot. Unsaved changes are excluded."))
                .font(.caption).foregroundStyle(.secondary)
            importedSources
            FieldIncidentSearchFilters(text: $text, status: $status, asset: $asset, filteringDates: $filteringDates,
                                       from: $from, through: $through, ticketReference: ticketReference) {
                ticketReference = nil
                excludingCaseID = nil
            }
                .disabled(model.isImporting)
            if model.isLoading || model.isImporting { ProgressView(t("Loading local case library…")) }
            if !model.errors.isEmpty {
                DisclosureGroup(tf("%d files could not be loaded; previous snapshots are retained", model.errors.count)) {
                    ScrollView { Text(model.errors.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 80)
                }
                .font(.caption).foregroundStyle(.orange)
            }
            if !model.loadError.isEmpty { Text(model.loadError).foregroundStyle(.orange).textSelection(.enabled) }
            if let page = model.page {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(page.results) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.incident.title).lineLimit(1)
                                Text("\(result.source.label) · \(t(result.incident.status.title))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.tag(result.id)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                    .accessibilityIdentifier("fieldCaseLibraryResults")
                    ScrollView {
                        if let selected = page.results.first(where: { $0.id == selectedID }) {
                            FieldIncidentSearchDetailView(result: selected, onFindAsset: { asset = $0 }) {
                                text = ""
                                status = nil
                                asset = nil
                                filteringDates = false
                                ticketReference = selected.incident.ticketReference
                                excludingCaseID = selected.id
                            }
                        } else {
                            Text(t("Select an incident to review its saved timeline.")).foregroundStyle(.secondary).padding()
                        }
                    }
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(model.isImporting)
                }
                HStack {
                    Text(tf("%d files · %d matching incidents", model.sources.count, page.total)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Previous page")) { pageIndex -= 1 }.disabled(pageIndex == 0 || model.isImporting)
                    Text(String(pageIndex + 1)).monospacedDigit()
                    Button(t("Next page")) { pageIndex += 1 }
                        .disabled(pageIndex * 25 + page.results.count >= page.total || model.isImporting)
                }
            } else { Spacer() }
        }
        .padding(20)
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 640, idealHeight: 740)
        .onAppear { model.reload(query, pageIndex: pageIndex) }
        .onChange(of: query) { _, _ in pageIndex = 0; selectedID = nil; model.reload(query, pageIndex: 0) }
        .onChange(of: pageIndex) { _, _ in selectedID = nil; model.reload(query, pageIndex: pageIndex) }
        .onDisappear { model.cancel() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [FieldProjectDocument.contentType], allowsMultipleSelection: true) { result in
            do { importFiles(try result.get()) }
            catch { errorMessage = error.localizedDescription }
        }
        .fieldProjectError($errorMessage)
        .alert(t("Remove local source?"), isPresented: Binding(get: { removingSource != nil }, set: { if !$0 { removingSource = nil } }), presenting: removingSource) { source in
            Button(t("Remove local copy"), role: .destructive) {
                pageIndex = 0
                selectedID = nil
                model.removeSource(source, query: query)
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: { source in
            Text(tf("Remove the saved library copy of %@ and its observations? The source project file is kept.", source.label))
        }
    }

    private var importedSources: some View {
        DisclosureGroup(tf("%d imported sources · %d observations", model.sources.count, model.sources.reduce(0) { $0 + $1.observationCount })) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.sources) { source in
                        HStack {
                            Text(source.label).lineLimit(1)
                            Text(Fmt.dateTime(source.loadedAt)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(t("Refresh source snapshot")) {
                                if let url = URL(string: source.id) { importFiles([url]) }
                            }.disabled(model.isLoading || model.isImporting)
                            Button(t("Remove local copy"), systemImage: "trash", role: .destructive) { removingSource = source }
                                .labelStyle(.iconOnly)
                                .disabled(model.isLoading || model.isImporting)
                        }
                        .help(URL(string: source.id)?.path ?? source.id)
                    }
                }
            }.frame(maxHeight: 100)
        }.font(.caption)
    }

    private func importFiles(_ urls: [URL]) {
        pageIndex = 0
        selectedID = nil
        model.importFiles(urls, query: query)
    }
}
