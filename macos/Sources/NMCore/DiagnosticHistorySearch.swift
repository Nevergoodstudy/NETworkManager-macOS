import Foundation

public enum DiagnosticHistorySearch {
    package struct Filter: Equatable, Sendable {
        package let workspaceID: UUID?
        package let kind: DiagnosticKind?
        package let days: Int?
        package let text: String

        package init(workspaceID: UUID?, kind: DiagnosticKind?, days: Int?, text: String) {
            self.workspaceID = workspaceID
            self.kind = kind
            self.days = days
            self.text = text
        }

        var usesIndex: Bool { kind == nil && days == nil && text.isEmpty }

        func matchingRuns(in snapshot: AssetSnapshot) -> [DiagnosticRun] {
            let cutoff = days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            let sites = Dictionary(uniqueKeysWithValues: snapshot.sites.map { ($0.id, $0) })
            let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
            let devices = Dictionary(uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0) })
            return snapshot.diagnosticRuns.filter { run in
                guard kind.map({ run.kind == $0 }) ?? true,
                      cutoff.map({ run.startedAt >= $0 }) ?? true else { return false }
                let device = run.deviceID.flatMap { devices[$0] }
                let site = device.flatMap { sites[$0.siteID] }
                guard workspaceID.map({ site?.workspaceID == $0 }) ?? true else { return false }
                guard !text.isEmpty else { return true }
                let workspace = site.flatMap { workspaces[$0.workspaceID] }
                return [device?.name ?? "", device?.address ?? "", site?.name ?? "", workspace?.name ?? "",
                        run.target ?? "", run.summary, run.detail]
                    .contains { $0.localizedCaseInsensitiveContains(text) }
                    || DiagnosticHistorySearch.matches(run, query: text)
            }.sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
            }
        }
    }

    public static func matches(_ run: DiagnosticRun, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [run.source, run.parameters["eventID"] ?? "", run.parameters["triggerID"] ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
