import Foundation
import NMCore
import SwiftUI

/// Window-owned presentation state; file reads and database work run off MainActor.
@MainActor
final class FieldCaseLibraryModel: ObservableObject {
    @Published private(set) var sources: [FieldCaseSource] = []
    @Published private(set) var page: FieldIncidentSearchPage?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var loadError = ""
    private let library = FieldCaseLibrary()
    private var task: Task<Void, Never>?

    func reload(_ query: FieldIncidentQuery, pageIndex: Int) {
        guard !isImporting else { return }
        task?.cancel()
        page = nil
        loadError = ""
        isLoading = true
        let library = library
        task = Task {
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { (try library.sources(), try library.search(query, offset: pageIndex * 25)) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let (sources, page)): self.sources = sources; self.page = page
            case .failure(let error): loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    func importFiles(_ urls: [URL], query: FieldIncidentQuery) {
        guard !isImporting else { return }
        let urls = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.absoluteString < $1.absoluteString }
        guard urls.count <= FieldIncidentCatalog.maximumSources else {
            errors = [FieldIncidentSearchError.sourceLimit.localizedDescription]
            return
        }
        let revisions = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.revision) })
        task?.cancel()
        isLoading = false
        isImporting = true
        errors = []
        let library = library
        task = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                for read in FieldIncidentFileLoader.read(urls) {
                    do {
                        if let project = read.project {
                            try library.importProject(project, from: read.url, expectedRevision: revisions[read.url.absoluteString])
                        } else if let error = read.error { failures.append("\(read.url.lastPathComponent): \(error)") }
                    } catch { failures.append("\(read.url.lastPathComponent): \(error.localizedDescription)") }
                }
                return failures
            }.value
            guard !Task.isCancelled else { return }
            errors = failures
            isImporting = false
            reload(query, pageIndex: 0)
        }
    }

    func cancel() { task?.cancel() }

    func removeSource(_ source: FieldCaseSource, query: FieldIncidentQuery) {
        guard !isImporting else { return }
        task?.cancel()
        isLoading = false
        isImporting = true
        errors = []
        let library = library
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try library.removeSource(id: source.id, expectedRevision: source.revision) }
            }.value
            guard !Task.isCancelled else { return }
            if case .failure(let error) = result { errors = [error.localizedDescription] }
            isImporting = false
            reload(query, pageIndex: 0)
        }
    }
}
