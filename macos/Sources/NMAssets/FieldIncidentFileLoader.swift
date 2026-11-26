import Foundation
import NMCore

struct FieldIncidentFileRead: Sendable {
    let url: URL
    let project: FieldProject?
    let error: String?
}

enum FieldIncidentFileLoader {
    /// At most 40 × 512 KB, with each file size checked during the read itself.
    static func read(_ urls: [URL]) -> [FieldIncidentFileRead] {
        guard urls.count <= FieldIncidentCatalog.maximumSources else {
            return urls.first.map { [FieldIncidentFileRead(url: $0, project: nil, error: FieldIncidentSearchError.sourceLimit.localizedDescription)] } ?? []
        }
        return urls.map { url in
            guard !Task.isCancelled else { return FieldIncidentFileRead(url: url, project: nil, error: t("Cancelled")) }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: FieldProject.fileSizeLimit + 1) ?? Data()
                let project = try FieldProject.decode(data)
                return FieldIncidentFileRead(url: url, project: project, error: nil)
            } catch {
                return FieldIncidentFileRead(url: url, project: nil, error: error.localizedDescription)
            }
        }
    }
}
