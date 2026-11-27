import NMCore
import SwiftUI

/// A session-scoped, read-only catalog of explicitly selected project files.
struct FieldIncidentCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @NMStateCompat private var catalog = FieldIncidentCatalog()
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
    @NMStateCompat private var loadTask: Task<[FieldIncidentFileRead], Never>?
    @NMStateCompat private var errors: [String] = []
    @NMStateCompat private var errorMessage = ""

    private var query: FieldIncidentQuery {
        FieldIncidentQuery(text: text, status: status, asset: asset,
                           occurredFrom: filteringDates ? from : nil,
                           occurredThrough: filteringDates ? through : nil,
                           ticketReference: ticketReference, excludingCaseID: excludingCaseID)
    }

    private var page: FieldIncidentSearchPage? { try? catalog.search(query, offset: pageIndex * 25) }
    private var selected: FieldIncidentSearchResult? { page?.results.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Search project incidents")).font(.title2.bold())
                Spacer()
                Button(t("Choose project files…")) { choosingFiles = true }
                    .disabled(loadTask != nil)
                    .accessibilityIdentifier("fieldCatalogChooseFiles")
                Button(t("Refresh loaded files")) {
                    load(catalog.sources.compactMap { URL(string: $0.id) })
                }
                .disabled(loadTask != nil || catalog.sources.isEmpty)
                Button(t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(t("Choose up to 40 project files. Search uses saved snapshots in this window only; unsaved edits and files you did not choose are excluded."))
                .font(.caption).foregroundStyle(.secondary)
            FieldIncidentSearchFilters(text: $text, status: $status, asset: $asset, filteringDates: $filteringDates,
                                       from: $from, through: $through, ticketReference: ticketReference) {
                ticketReference = nil
                excludingCaseID = nil
            }
            if loadTask != nil { ProgressView(t("Reading selected project files…")) }
            if !errors.isEmpty {
                DisclosureGroup(tf("%d files could not be loaded; previous snapshots are retained", errors.count)) {
                    ScrollView { Text(errors.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 80)
                }
                .font(.caption).foregroundStyle(.orange)
            }
            if let page {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(page.results) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.incident.title).lineLimit(1)
                                Text("\(result.source.label) · \(t(result.incident.status.title))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(result.id)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                    .accessibilityIdentifier("fieldCatalogResults")
                    ScrollView {
                        if let selected {
                            FieldIncidentSearchDetailView(result: selected, onFindAsset: { asset = $0 }) {
                                text = ""
                                status = nil
                                asset = nil
                                filteringDates = false
                                ticketReference = selected.incident.ticketReference
                                excludingCaseID = selected.id
                            }
                        }
                        else { Text(t("Select an incident to review its saved timeline.")).foregroundStyle(.secondary).padding() }
                    }
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Text(tf("%d files · %d matching incidents", catalog.sources.count, page.total))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Previous page")) { pageIndex -= 1 }
                        .disabled(pageIndex == 0)
                    Text(String(pageIndex + 1)).monospacedDigit()
                    Button(t("Next page")) { pageIndex += 1 }
                        .disabled(pageIndex * 25 + page.results.count >= page.total)
                }
            } else {
                Text(t("Check the search length and occurrence date range.")).foregroundStyle(.orange)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 600, idealHeight: 700)
        .onChange(of: query) { _, _ in pageIndex = 0; selectedID = nil }
        .onChange(of: pageIndex) { _, _ in selectedID = nil }
        .onDisappear { loadTask?.cancel() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [FieldProjectDocument.contentType], allowsMultipleSelection: true) { result in
            do { load(try result.get()) }
            catch { errorMessage = error.localizedDescription }
        }
        .fieldProjectError($errorMessage)
    }

    private func load(_ urls: [URL]) {
        let unique = Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
        let sourceIDs = Set(catalog.sources.map(\.id)).union(unique.map(\.absoluteString))
        guard sourceIDs.count <= FieldIncidentCatalog.maximumSources else {
            errorMessage = FieldIncidentSearchError.sourceLimit.localizedDescription
            return
        }
        errors = []
        let task = Task.detached(priority: .userInitiated) { FieldIncidentFileLoader.read(unique) }
        loadTask = task
        Task { @MainActor in
            let reads = await task.value
            guard !task.isCancelled else { loadTask = nil; return }
            for read in reads {
                do {
                    if let project = read.project {
                        try catalog.upsert(project: project, sourceID: read.url.absoluteString, label: read.url.lastPathComponent)
                    } else if let error = read.error { errors.append("\(read.url.lastPathComponent): \(error)") }
                } catch { errors.append("\(read.url.lastPathComponent): \(error.localizedDescription)") }
            }
            pageIndex = 0
            selectedID = nil
            loadTask = nil
        }
    }

}
