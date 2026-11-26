import Foundation

/// Additive history/MCP metadata. Stable codes are independent of display text.
public struct DiagnosticRuntimeEvidence: Codable, Hashable, Sendable {
    public let tcpFailure: TCPProbeFailure?
    public let tcpAttempts: [TCPProbeAttempt]?
    public let process: ProcessExecutionEvidence?
    public let service: ServiceProbeEvidence?

    public init(tcpFailure: TCPProbeFailure? = nil, tcpAttempts: [TCPProbeAttempt]? = nil,
                process: ProcessExecutionEvidence? = nil, service: ServiceProbeEvidence? = nil) {
        self.tcpFailure = tcpFailure
        self.tcpAttempts = tcpAttempts
        self.process = process
        self.service = service
    }
}
