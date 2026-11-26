import Foundation
import Darwin
import Logging
import MCP
import NMMCPTools

@main
enum NMMCPMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let supported: Set<String> = ["--allow-network", "--help", "-h", "--version"]
        let snapshotPrefix = "--case-snapshot="
        let loopbackPrefix = "--approved-loopback-tcp="
        let approvalPrefix = "--approved-tcp="
        let snapshotArguments = arguments.filter { $0.hasPrefix(snapshotPrefix) }
        let approvalArguments = arguments.filter { $0.hasPrefix(approvalPrefix) || $0.hasPrefix(loopbackPrefix) }
        guard snapshotArguments.count <= 1, approvalArguments.count <= 1,
              arguments.allSatisfy({ supported.contains($0) || $0.hasPrefix(snapshotPrefix)
                  || $0.hasPrefix(approvalPrefix) || $0.hasPrefix(loopbackPrefix) }) else {
            FileHandle.standardError.write(Data("Unknown option. Use NMCP --help.\n".utf8))
            exit(2)
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Usage: NMCP [--allow-network] [--case-snapshot=/absolute/path.json]
                        [--approved-tcp=IP,PORT,SECONDS | --approved-loopback-tcp=PORT,SECONDS]
                        [--help] [--version]

            NETworkManager MCP server over stdio (macOS 14+).
            --allow-network  Enable Ping, DNS and single-port TCP diagnostics.
                             Default tools only inspect local interfaces and
                             bundled reference data or calculate IPv4 subnets.
            --case-snapshot  Expose the summary and observations of one Case export.
            --approved-tcp   Approve one TCP check to an exact numeric IP and port.
                             Requires a Case snapshot and replaces --allow-network.
            --approved-loopback-tcp  Shorthand for --approved-tcp=127.0.0.1,PORT,SECONDS.
            --help, -h       Show this help and exit.
            --version        Show the MCP server version and exit.

            Start from an MCP client. Standard input/output carry JSON-RPC.
            See macos/MCP.md for client setup, tool parameters and limits.
            """)
            return
        }
        if arguments.contains("--version") {
            print(ServerResources.version)
            return
        }

        let caseSnapshot: MCPCaseSnapshot?
        do {
            caseSnapshot = try snapshotArguments.first.map {
                try MCPCaseSnapshot(path: String($0.dropFirst(snapshotPrefix.count)))
            }
        } catch {
            FileHandle.standardError.write(Data("Could not read the selected Case JSON export.\n".utf8))
            exit(2)
        }

        // A disconnected client should produce an I/O error, not SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let networkEnabled = arguments.contains("--allow-network")
        var approval: ApprovedTCPTarget?
        if let argument = approvalArguments.first {
            let scope = argument.hasPrefix(loopbackPrefix)
                ? "127.0.0.1," + argument.dropFirst(loopbackPrefix.count)
                : String(argument.dropFirst(approvalPrefix.count))
            guard caseSnapshot != nil, !networkEnabled, let target = ApprovedTCPTarget(scope) else {
                FileHandle.standardError.write(Data("""
                --approved-tcp requires a numeric IP, PORT, SECONDS (1...300), and a Case snapshot in scoped mode.

                """.utf8))
                exit(2)
            }
            approval = target
        }
        let caseSummary = caseSnapshot?.summaryJSON
        let service = MCPToolService(networkEnabled: networkEnabled, caseSnapshot: caseSnapshot,
                                     tcpApproval: approval)
        let requests = ToolRequests(service: service)
        let server = Server(
            name: "networkmanager", version: ServerResources.version,
            instructions: ServerResources.usage,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false),
                                tools: .init(listChanged: false)),
            configuration: .strict
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: service.tools) }
        await server.withMethodHandler(CallTool.self) { params in try await requests.call(params) }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ServerResources.list(caseSummaryAvailable: caseSummary != nil))
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in .init(templates: []) }
        await server.withMethodHandler(ReadResource.self) { params in
            try ServerResources.read(params.uri, service: service, networkEnabled: networkEnabled, caseSummary: caseSummary)
        }

        do {
            let transport = await SerialStdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            await requests.stop()
            await server.stop()
        } catch {
            await requests.stop()
            await server.stop()
            FileHandle.standardError.write(Data("NMCP failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private actor SerialStdioTransport: Transport {
    private let base: StdioTransport
    private let messages: AsyncThrowingStream<Data, Error>
    private var lastSend: Task<Void, Error>?
    private var pending: [UUID: Task<Void, Error>] = [:]
    private var connected = false

    init() async {
        let base = StdioTransport()
        self.base = base
        messages = await base.receive()
    }

    var logger: Logger { base.logger }

    func connect() async throws {
        try await base.connect()
        connected = true
    }

    func disconnect() async {
        connected = false
        for write in pending.values { write.cancel() }
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw POSIXError(.ENOTCONN) }
        let id = UUID()
        let previous = lastSend
        // StdioTransport can suspend after writing only part of a JSON-RPC line.
        let write = Task { [base] in
            _ = await previous?.result
            try Task.checkCancellation()
            try await base.send(data)
        }
        lastSend = write
        pending[id] = write
        defer {
            pending.removeValue(forKey: id)
            if pending.isEmpty { lastSend = nil }
        }
        try await write.value
    }

    func receive() -> AsyncThrowingStream<Data, Error> { messages }
}
