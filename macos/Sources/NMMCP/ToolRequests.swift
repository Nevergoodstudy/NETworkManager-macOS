import Foundation
import MCP
import NMMCPTools

/// Retains active handlers so EOF cancels the underlying socket/process work.
/// The SDK handles protocol request IDs and notifications/cancelled.
actor ToolRequests {
    private let service: MCPToolService
    private var pending: [UUID: Task<CallTool.Result, Error>] = [:]
    private var stopped = false

    init(service: MCPToolService) { self.service = service }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await service.call(params) }
        pending[id] = task
        defer { pending[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() async {
        stopped = true
        let tasks = Array(pending.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
    }
}
