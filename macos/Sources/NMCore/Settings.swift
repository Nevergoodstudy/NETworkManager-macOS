import Foundation

/// Simple JSON backed settings store.
///
/// Core application preferences are typed properties; feature modules that only
/// need to remember a value or two can use the `extra` string dictionary, which
/// avoids inventing new settings surfaces for every tool.
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    // MARK: Persistence

    public static var supportDirectory: URL {
        let dir = resolvedSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func resolvedSupportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["NETWORKMANAGER_SUPPORT_DIRECTORY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NETworkManager", isDirectory: true)
    }

    private static var fileURL: URL { supportDirectory.appendingPathComponent("settings.json") }

    private struct Payload: Codable {
        var language: String?
        var appearance: String?
        var accent: String?
        var extra: [String: String]?
        var launchAtLogin: Bool?
        var showStatusBar: Bool?
        var lastTool: String?
        var windowWidth: Double?
        var windowHeight: Double?
    }

    private let storageURL: URL
    private let managesLoginItem: Bool
    private var isLoading = true

    private enum RecoveryFailure {
        case readFailed(String)
        case invalidData
    }

    @Published private var recoveryFailure: RecoveryFailure?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var preservedCorruptFileURL: URL?

    /// Defer localization until after initialization: Loc.shared itself loads
    /// SettingsStore.shared to obtain the selected language.
    public var recoveryError: String? {
        switch recoveryFailure {
        case .readFailed(let message):
            return tf("Settings could not be read. The original file was preserved. Reset settings to recover. (%@)", message)
        case .invalidData:
            return t("Settings data is damaged or from an unsupported format. The original file was preserved. Reset settings to recover.")
        case nil:
            return nil
        }
    }

    // MARK: Core values

    @Published public var language: AppLanguage? {
        didSet { persistIfReady() }
    }

    @Published public var appearance: AppAppearance? {
        didSet { persistIfReady() }
    }

    @Published public var accent: AppAccent? {
        didSet { persistIfReady() }
    }

    @Published public var launchAtLogin: Bool = false {
        didSet {
            persistIfReady()
            guard !isLoading else { return }
            _ = LoginItemManager.shared.setEnabled(launchAtLogin)
        }
    }

    @Published public var showStatusBar: Bool = true {
        didSet { persistIfReady() }
    }

    @Published public var lastTool: String? {
        didSet { persistIfReady() }
    }

    @Published public var extra: [String: String] = [:] {
        didSet { persistIfReady() }
    }

    public var windowWidth: Double = 1280
    public var windowHeight: Double = 820

    // MARK: Init

    public init(storageURL: URL? = nil, managesLoginItem: Bool = true) {
        self.storageURL = storageURL ?? Self.fileURL
        self.managesLoginItem = managesLoginItem
        load()
        isLoading = false
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            launchAtLogin = managesLoginItem ? LoginItemManager.shared.state.isEnabled : false
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            recoveryFailure = .readFailed(error.localizedDescription)
            return
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            recoveryFailure = .invalidData
            return
        }
        language = payload.language.flatMap(AppLanguage.init(rawValue:))
        appearance = payload.appearance.flatMap(AppAppearance.init(rawValue:))
        accent = payload.accent.flatMap(AppAccent.init(rawValue:))
        extra = payload.extra ?? [:]
        launchAtLogin = payload.launchAtLogin ?? (managesLoginItem ? LoginItemManager.shared.state.isEnabled : false)
        showStatusBar = payload.showStatusBar ?? true
        lastTool = payload.lastTool
        windowWidth = payload.windowWidth ?? 1280
        windowHeight = payload.windowHeight ?? 820
    }

    private func persistIfReady() {
        guard !isLoading else { return }
        persist()
    }

    public func persist() {
        guard recoveryFailure == nil else { return }
        let payload = Payload(
            language: language?.rawValue,
            appearance: appearance?.rawValue,
            accent: accent?.rawValue,
            extra: extra,
            launchAtLogin: launchAtLogin,
            showStatusBar: showStatusBar,
            lastTool: lastTool,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = tf("Settings could not be saved: %@", error.localizedDescription)
        }
    }

    /// Reset user preferences while leaving profile data intact, matching the
    /// Windows `--reset-settings` behaviour.
    public func reset() {
        if recoveryFailure != nil, FileManager.default.fileExists(atPath: storageURL.path) {
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let preservedURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(timestamp)")
            do {
                try FileManager.default.copyItem(at: storageURL, to: preservedURL)
                preservedCorruptFileURL = preservedURL
            } catch {
                persistenceError = tf("Damaged settings could not be preserved: %@", error.localizedDescription)
                return
            }
        }
        isLoading = true
        recoveryFailure = nil
        language = nil
        appearance = nil
        accent = nil
        extra = [:]
        launchAtLogin = false
        showStatusBar = true
        lastTool = nil
        windowWidth = 1280
        windowHeight = 820
        isLoading = false
        persist()
        if managesLoginItem { _ = LoginItemManager.shared.setEnabled(launchAtLogin) }
    }

    /// Preserve the legacy startup option for healthy settings files. A damaged
    /// file requires the user to review and confirm recovery in Settings.
    @discardableResult
    public func resetFromCommandLine() -> Bool {
        guard recoveryFailure == nil else { return false }
        reset()
        return true
    }

    // MARK: Feature helper

    public func string(_ key: String, default def: String) -> String {
        extra[key] ?? def
    }

    public func setString(_ key: String, _ value: String) {
        extra[key] = value
    }
}

// MARK: - Launch at login compatibility

/// Compatibility facade for callers that used the pre-macOS-port name.
/// Registration is delegated to the system-managed `SMAppService.mainApp`
/// implementation; this facade never writes a LaunchAgent plist.
public enum LaunchAgent {
    public static var label: String { LoginItemManager.legacyLabel }
    public static var isEnabled: Bool { LoginItemManager.shared.state.isEnabled }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        LoginItemManager.shared.setEnabled(enabled)
    }
}
