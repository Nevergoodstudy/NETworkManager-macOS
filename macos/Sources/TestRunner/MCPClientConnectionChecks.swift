import Foundation
@testable import NMCore

/// Exercises the GUI connection model against real child processes without
/// reading or changing the operator's Codex configuration or preferences.
enum MCPClientConnectionChecks {
    @MainActor
    static func run() async throws {
        let fixture = try MCPClientCLIFixture()
        defer { fixture.remove() }
        let connection = MCPClientConnection(helperURL: fixture.helperURL,
                                             codexURL: fixture.codexURL,
                                             environment: fixture.environment)

        try check(connection.allowNetwork && connection.canConnect,
                  "MCP connection presents the network option before explicit registration")
        await connection.refresh()
        try check(!connection.hasRegistration && !connection.isConnected && connection.lastError == nil,
                  "MCP refresh decodes an empty Codex list without registering a server")
        try fixture.checkInvocations([["mcp", "list", "--json"]],
                                     "MCP opening settings only reads the isolated client configuration")

        let offline = fixture.entry(args: [])
        try fixture.setEntries([
            ["name": "another-server", "enabled": true,
             "transport": ["type": "http", "url": "https://example.invalid/mcp"]],
            offline
        ])
        await connection.refresh()
        try check(connection.hasRegistration && connection.isConnected && connection.canDisconnect,
                  "MCP list decoding finds this app among unrelated transports")
        try check(!connection.allowNetwork,
                  "MCP refresh reflects an existing registration with network diagnostics disabled")

        connection.allowNetwork = true
        try check(!connection.isConnected && connection.hasRegistration,
                  "MCP changing the network option marks the existing registration for update")
        try fixture.setAddEntries([fixture.entry(args: ["--allow-network"])])
        try fixture.clearInvocations()
        await connection.connect()
        try check(connection.isConnected && connection.lastError == nil,
                  "MCP reports a connection only after Codex confirms the matching registration")
        try fixture.checkInvocations([
            ["mcp", "add", "networkmanager", "--", fixture.helperURL.path, "--allow-network"],
            ["mcp", "list", "--json"]
        ], "MCP passes a helper path containing spaces and shell characters as one literal argument")

        connection.allowNetwork = false
        try fixture.setAddEntries([offline])
        try fixture.clearInvocations()
        await connection.connect()
        try check(connection.isConnected && !connection.allowNetwork && connection.lastError == nil,
                  "MCP network diagnostics can be disabled by updating the registered arguments")
        try fixture.checkInvocations([
            ["mcp", "add", "networkmanager", "--", fixture.helperURL.path],
            ["mcp", "list", "--json"]
        ], "MCP excludes the network flag when its option is off")

        try fixture.setEntries([fixture.entry(args: ["--allow-network"])])
        await connection.refresh()
        try check(connection.allowNetwork && connection.isConnected,
                  "MCP refresh reloads a network option changed outside the GUI")

        try fixture.setEntries([fixture.entry(args: ["--allow-network"], enabled: false)])
        await connection.refresh()
        try check(connection.hasRegistration && !connection.isConnected,
                  "MCP does not display a disabled Codex registration as connected")
        try fixture.setEntries([fixture.entry(args: ["--allow-network", "--unexpected-option"])])
        await connection.refresh()
        try check(!connection.isConnected,
                  "MCP requires the complete registered argument list to match the chosen permissions")

        let external = fixture.entry(command: fixture.helperURL.path + "-other-installation", args: [])
        try fixture.setEntries([external])
        await connection.refresh()
        try check(connection.hasRegistration && !connection.isConnected && !connection.canDisconnect,
                  "MCP distinguishes another installation's connection from this app's helper")
        try fixture.clearInvocations()
        await connection.disconnect()
        try fixture.checkInvocations([], "MCP refuses to remove a registration owned by another installation")

        try fixture.setEntries([offline])
        await connection.refresh()
        try check(connection.canDisconnect, "MCP fixture starts with this app's removable registration")
        try fixture.setEntries([external])
        try fixture.clearInvocations()
        await connection.disconnect()
        try check(connection.hasRegistration && !connection.isConnected && !connection.canDisconnect,
                  "MCP reloads ownership if another client replaces the entry after the GUI refresh")
        try fixture.checkInvocations([["mcp", "list", "--json"]],
                                     "MCP stale ownership never removes another installation's new connection")

        try fixture.fail(command: "add")
        await connection.connect()
        try check(!connection.isConnected && connection.lastError != nil,
                  "MCP a failing add command never reports a successful connection")
        try fixture.fail(command: nil)
        try fixture.setAddEntries([external])
        await connection.connect()
        try check(!connection.isConnected && connection.lastError != nil,
                  "MCP a zero-exit add still requires the expected command and arguments to be confirmed")

        try fixture.setEntries([offline])
        await connection.refresh()
        try check(connection.isConnected, "MCP fixture restores a confirmed offline registration")
        try fixture.setRawList("{ not a valid Codex list")
        await connection.refresh()
        try check(!connection.hasRegistration && !connection.isConnected && connection.lastError != nil,
                  "MCP malformed client output clears stale success and shows a readable error")
        try fixture.setEntries([offline])
        await connection.refresh()
        try fixture.fail(command: "list")
        await connection.refresh()
        try check(!connection.hasRegistration && !connection.isConnected && connection.lastError != nil,
                  "MCP a failed refresh clears stale connection status")
        try fixture.fail(command: nil)

        try fixture.setEntries([offline])
        await connection.refresh()
        try fixture.setRemoveEntries([offline])
        await connection.disconnect()
        try check(connection.hasRegistration && connection.lastError != nil,
                  "MCP a zero-exit remove must report an error if Codex still lists this helper")
        try fixture.fail(command: "remove")
        await connection.disconnect()
        try check(connection.hasRegistration && connection.lastError != nil,
                  "MCP preserves the actual registration and reports a failed removal")
        try fixture.fail(command: nil)
        try fixture.setRemoveEntries([])
        try fixture.clearInvocations()
        await connection.disconnect()
        try check(!connection.hasRegistration && !connection.isConnected && connection.lastError == nil,
                  "MCP reports disconnected after Codex confirms removal")
        try fixture.checkInvocations([
            ["mcp", "list", "--json"], ["mcp", "remove", "networkmanager"], ["mcp", "list", "--json"]
        ], "MCP removes only the named networkmanager connection and verifies the result")

        let mounted = MCPClientConnection(helperURL: URL(fileURLWithPath: "/Volumes/Test Installer/NETworkManager.app/Contents/Helpers/NMCP"),
                                           codexURL: fixture.codexURL, environment: fixture.environment)
        try check(mounted.requiresInstallation && !mounted.canConnect,
                  "MCP does not register a durable helper path on a mounted installer")
        let translocated = MCPClientConnection(helperURL: URL(fileURLWithPath: "/private/var/folders/fixture/AppTranslocation/id/d/NETworkManager.app/Contents/Helpers/NMCP"),
                                                codexURL: fixture.codexURL, environment: fixture.environment)
        try check(translocated.requiresInstallation && !translocated.canConnect,
                  "MCP requires installation before registering an app-translocated helper")
        let missing = MCPClientConnection(helperURL: nil, codexURL: fixture.codexURL,
                                           environment: fixture.environment)
        try fixture.clearInvocations()
        await missing.connect()
        let missingInvocations = try fixture.invocations()
        try check(!missing.canConnect && !missing.isConnected && missingInvocations.isEmpty,
                  "MCP a build without the bundled helper cannot change the client configuration")

        let selectedApp = fixture.root.appendingPathComponent("Chosen Codex.app")
        let selectedExecutable = selectedApp.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try fixture.installExecutable(at: selectedExecutable)
        try check(MCPClientConnection.executable(in: selectedApp) == selectedExecutable,
                  "MCP app selection resolves the current nested Codex CLI layout")
        try check(MCPClientConnection.executable(in: fixture.codexURL) == fixture.codexURL,
                  "MCP app selection also accepts a directly selected executable")
        let notExecutable = fixture.root.appendingPathComponent("ordinary file")
        try Data().write(to: notExecutable)
        try check(MCPClientConnection.executable(in: notExecutable) == nil,
                  "MCP rejects a selected file that cannot execute")
    }
}

private final class MCPClientCLIFixture {
    let root: URL
    let helperURL: URL
    let codexURL: URL
    private let configurationURL: URL

    var environment: [String: String] {
        ["CODEX_HOME": configurationURL.path, "NM_MCP_FIXTURE_HOME": configurationURL.path]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NM MCP client \(UUID().uuidString)")
        helperURL = root.appendingPathComponent("NET work ; $HOME ' Manager.app/Contents/Helpers/NMCP")
        codexURL = root.appendingPathComponent("Codex fixture executable")
        configurationURL = root.appendingPathComponent("isolated Codex config")
        do {
            try FileManager.default.createDirectory(at: configurationURL, withIntermediateDirectories: true)
            try installExecutable(at: helperURL)
            let script = #"""
            #!/bin/sh
            set -eu
            [ "${CODEX_HOME:?}" = "${NM_MCP_FIXTURE_HOME:?}" ] || exit 90
            printf '%s\0' "$@" >> "$CODEX_HOME/argv.log"
            printf '\0' >> "$CODEX_HOME/argv.log"
            if [ -f "$CODEX_HOME/fail-command" ] && [ "$2" = "$(/bin/cat "$CODEX_HOME/fail-command")" ]; then
                printf 'Fixture command failed\n' >&2
                exit 7
            fi
            case "$1 $2" in
                'mcp list') /bin/cat "$CODEX_HOME/list.json" ;;
                'mcp add') /bin/cp "$CODEX_HOME/add.json" "$CODEX_HOME/list.json" ;;
                'mcp remove') /bin/cp "$CODEX_HOME/remove.json" "$CODEX_HOME/list.json" ;;
                *) exit 64 ;;
            esac
            """#
            try Data(script.utf8).write(to: codexURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexURL.path)
            try setEntries([])
            try setAddEntries([])
            try setRemoveEntries([])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func installExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func entry(command: String? = nil, args: [String], enabled: Bool = true) -> [String: Any] {
        ["name": "networkmanager", "enabled": enabled,
         "transport": ["type": "stdio", "command": command ?? helperURL.path, "args": args]]
    }

    func setEntries(_ entries: [[String: Any]]) throws { try write(entries, to: "list.json") }
    func setAddEntries(_ entries: [[String: Any]]) throws { try write(entries, to: "add.json") }
    func setRemoveEntries(_ entries: [[String: Any]]) throws { try write(entries, to: "remove.json") }

    func setRawList(_ value: String) throws {
        try Data(value.utf8).write(to: configurationURL.appendingPathComponent("list.json"))
    }

    func fail(command: String?) throws {
        let path = configurationURL.appendingPathComponent("fail-command")
        if let command { try Data(command.utf8).write(to: path) }
        else if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    func clearInvocations() throws {
        try Data().write(to: configurationURL.appendingPathComponent("argv.log"))
    }

    func invocations() throws -> [[String]] {
        let path = configurationURL.appendingPathComponent("argv.log")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(decoding: Data(contentsOf: path), as: UTF8.self)
            .components(separatedBy: "\0\0")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\0") }
    }

    func checkInvocations(_ expected: [[String]], _ message: String) throws {
        let actual = try invocations()
        try check(actual == expected, message + ": " + String(describing: actual))
    }

    private func write(_ entries: [[String: Any]], to name: String) throws {
        try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            .write(to: configurationURL.appendingPathComponent(name))
    }
}
