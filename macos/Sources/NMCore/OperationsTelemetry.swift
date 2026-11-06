import Foundation
import OSLog

/// Small, privacy-conscious operational logger. Event names and durations are
/// recorded, while hostnames, addresses, credentials, and response bodies are
/// deliberately excluded.
public enum OperationsTelemetry {
    private static let logger = Logger(subsystem: "net.borntoberoot.networkmanager", category: "operations")

    public static func diagnosticStarted(kind: DiagnosticKind, runID: UUID) {
        logger.info("Diagnostic started kind=\(kind.rawValue, privacy: .public) run=\(runID.uuidString, privacy: .public)")
    }

    public static func diagnosticFinished(kind: DiagnosticKind, status: DiagnosticRunStatus, runID: UUID, duration: TimeInterval) {
        logger.info("Diagnostic finished kind=\(kind.rawValue, privacy: .public) status=\(status.rawValue, privacy: .public) run=\(runID.uuidString, privacy: .public) duration_ms=\(Int(duration * 1000), privacy: .public)")
    }

    public static func netBoxSyncFinished(deviceCount: Int, siteCount: Int, succeeded: Bool) {
        logger.info("NetBox sync finished succeeded=\(succeeded, privacy: .public) devices=\(deviceCount, privacy: .public) sites=\(siteCount, privacy: .public)")
    }
}
