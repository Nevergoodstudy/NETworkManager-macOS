import Foundation
import Darwin
import MCP
import NMMCPTools

@main
enum NMMCPMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let supported: Set<String> = ["--allow-network", "--help", "-h", "--version"]
        guard arguments.allSatisfy({ supported.contains($0) }) else {
            FileHandle.standardError.write(Data("Unknown option. Use NMCP --help.\n".utf8))
            exit(2)
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Usage: NMCP [--allow-network] [--help] [--version]

            NETworkManager MCP server over stdio (macOS 14+).
            --allow-network  Enable Ping, DNS and single-port TCP diagnostics.
                             Default tools only inspect local interfaces and
                             bundled reference data or calculate IPv4 subnets.
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

        // A disconnected client should produce an I/O error, not SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let networkEnabled = arguments.contains("--allow-network")
        let service = MCPToolService(networkEnabled: networkEnabled)
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
        await server.withMethodHandler(ListResources.self) { _ in .init(resources: ServerResources.list) }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in .init(templates: []) }
        await server.withMethodHandler(ReadResource.self) { params in
            try ServerResources.read(params.uri, service: service, networkEnabled: networkEnabled)
        }

        do {
            try await server.start(transport: StdioTransport())
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
