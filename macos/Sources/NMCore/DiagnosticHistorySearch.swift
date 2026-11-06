import Foundation

public enum DiagnosticHistorySearch {
    public static func matches(_ run: DiagnosticRun, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [run.source, run.parameters["eventID"] ?? "", run.parameters["triggerID"] ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
