import AppKit
import Combine
import Foundation

/// Connects the bundled stdio server using Codex's own configuration commands.
/// Merely opening Settings never changes another application's configuration.
@MainActor
public final class MCPClientConnection: ObservableObject {
    @Published public var allowNetwork = true
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var codexURL: URL?
    @Published private var registration: CodexMCPRegistration?

    public let helperURL: URL?
    private let environment: [String: String]?
    private static let selectedClientKey = "mcp.codexExecutable"

    public convenience init() {
        let bundledHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NMCP")
        self.init(helperURL: FileManager.default.isExecutableFile(atPath: bundledHelper.path) ? bundledHelper : nil,
                  codexURL: Self.findCodex(), environment: nil)
    }

    // Explicit dependencies keep connection checks isolated from the user's real config in tests.
    init(helperURL: URL?, codexURL: URL?, environment: [String: String]?) {
        self.helperURL = helperURL
        self.codexURL = codexURL
        self.environment = environment
    }

    public var requiresInstallation: Bool {
        guard let path = helperURL?.path else { return false }
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    public var canConnect: Bool { helperURL != nil && codexURL != nil && !requiresInstallation && !isBusy }
    public var canDisconnect: Bool { registration?.uses(helperURL) == true && !isBusy }
    public var hasRegistration: Bool { registration != nil }
    public var isConnected: Bool {
        registration?.matches(helperURL, allowNetwork: allowNetwork) == true
    }

    public var availabilityMessage: String {
        if helperURL == nil { return t("This build does not include MCP. Install a current NETworkManager app.") }
        if requiresInstallation { return t("Move NETworkManager to Applications and open it there before connecting MCP.") }
        return t("MCP included and ready")
    }

    public var connectionMessage: String {
        if isBusy { return t("Updating Codex connection…") }
        if codexURL == nil { return t("Choose your Codex app to connect without using Terminal.") }
        if isConnected { return t("Configured. Open a new Codex chat to use networkmanager.") }
        if registration != nil { return t("Update the existing networkmanager connection to use this app and these options.") }
        return t("Connect once. Codex will start MCP automatically when needed, even after this app closes.")
    }

    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        guard codexURL != nil else { return }
        await readRegistration(loadOptions: true)
    }

    public func connect() async {
        guard canConnect, let codexURL, let helperURL else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        let arguments = ["mcp", "add", "networkmanager", "--", helperURL.path] + (allowNetwork ? ["--allow-network"] : [])
        let result = await Shell.run(codexURL.path, arguments, timeout: 10, environment: commandEnvironment)
        guard result.succeeded else { lastError = failureMessage(result); return }
        await readRegistration(loadOptions: false)
        if lastError == nil && !isConnected { lastError = t("Codex did not confirm the MCP connection. Try Refresh.") }
    }

    public func disconnect() async {
        // Never remove an entry that points to a different installation or server.
        guard canDisconnect, let codexURL else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        // Recheck before removal in case another client changed this entry.
        await readRegistration(loadOptions: false)
        guard lastError == nil, registration?.uses(helperURL) == true else { return }
        let result = await Shell.run(codexURL.path, ["mcp", "remove", "networkmanager"],
                                     timeout: 10, environment: commandEnvironment)
        guard result.succeeded else { lastError = failureMessage(result); return }
        await readRegistration(loadOptions: false)
        if lastError == nil && registration?.uses(helperURL) == true {
            lastError = t("Codex did not confirm removal of the MCP connection. Try Refresh.")
        }
    }

    public func selectCodex(_ selectedURL: URL) async {
        guard !isBusy else { return }
        guard let executable = Self.executable(in: selectedURL) else {
            lastError = t("The selected app does not contain Codex. Choose the Codex app or its executable.")
            return
        }
        codexURL = executable
        UserDefaults.standard.set(executable.path, forKey: Self.selectedClientKey)
        await refresh()
    }

    static func executable(in url: URL) -> URL? {
        let candidates = url.pathExtension.lowercased() == "app" ? [
            url.appendingPathComponent("Contents/Resources/codex"),
            url.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            url.appendingPathComponent("Contents/MacOS/codex")
        ] : [url]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func findCodex() -> URL? {
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: selectedClientKey) {
            candidates.append(URL(fileURLWithPath: saved))
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app)
        }
        candidates += ["/Applications/Codex.app", "/Applications/ChatGPT.app",
                       NSHomeDirectory() + "/Applications/Codex.app", NSHomeDirectory() + "/Applications/ChatGPT.app",
                       "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                       NSHomeDirectory() + "/.local/bin/codex", NSHomeDirectory() + "/.local/opt/node/bin/codex"]
            .map { URL(fileURLWithPath: $0) }
        for candidate in candidates {
            if let executable = executable(in: candidate) { return executable }
        }
        return nil
    }

    private var commandEnvironment: [String: String] {
        var values = environment ?? [:]
        let existing = values["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        values["PATH"] = [existing, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          NSHomeDirectory() + "/.local/opt/node/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        return values
    }

    private func readRegistration(loadOptions: Bool) async {
        guard let codexURL else { return }
        let result = await Shell.run(codexURL.path, ["mcp", "list", "--json"],
                                     timeout: 10, environment: commandEnvironment)
        guard result.succeeded else { registration = nil; lastError = failureMessage(result); return }
        do {
            let entries = try JSONDecoder().decode([CodexMCPRegistration].self, from: Data(result.stdout.utf8))
            registration = entries.first { $0.name == "networkmanager" }
            if loadOptions, let registration, registration.uses(helperURL) {
                allowNetwork = registration.transport.args?.contains("--allow-network") == true
            }
        } catch {
            registration = nil
            lastError = t("Could not read Codex MCP settings. Choose a current Codex app and try again.")
        }
    }

    private func failureMessage(_ result: CommandResult) -> String {
        if result.timedOut { return t("Codex did not respond in time. Try again or choose a current Codex app.") }
        return tf("Codex connection failed: %@", String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800)))
    }
}

struct CodexMCPRegistration: Decodable {
    let name: String
    let enabled: Bool?
    let transport: Transport
    struct Transport: Decodable {
        let type: String
        let command: String?
        let args: [String]?
    }

    func uses(_ helperURL: URL?) -> Bool {
        guard transport.type == "stdio", let command = transport.command, let helperURL else { return false }
        return URL(fileURLWithPath: command).standardizedFileURL.path == helperURL.standardizedFileURL.path
    }

    func matches(_ helperURL: URL?, allowNetwork: Bool) -> Bool {
        uses(helperURL) && enabled != false && (transport.args ?? []) == (allowNetwork ? ["--allow-network"] : [])
    }
}
