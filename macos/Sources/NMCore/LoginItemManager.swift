import Combine
import Foundation
import ServiceManagement

/// User-visible state for the app's system-managed login item.
public enum LoginItemState: String, CaseIterable, Sendable {
    case unavailable
    case disabled
    case enabled
    case requiresApproval
    case notFound
    case error

    public var isEnabled: Bool { self == .enabled }
}

/// Owns the macOS login-item registration for the visible application.
///
/// The app is registered as `SMAppService.mainApp`; no helper executable or
/// background collector is installed. The legacy per-user LaunchAgent is only
/// removed when it belongs to this app's historical label.
@available(macOS 13.0, *)
public final class LoginItemManager: ObservableObject {
    public static let shared = LoginItemManager()

    public static let legacyLabel = "com.networkmanager.mac.launcher"

    @Published public private(set) var state: LoginItemState = .unavailable
    @Published public private(set) var lastError: String?
    @Published public private(set) var legacyAgentFound = false

    private let service = SMAppService.mainApp

    private init() {
        refresh()
    }

    public var legacyPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.legacyLabel).plist")
    }

    /// Refresh the state reported by ServiceManagement and the migration flag.
    public func refresh() {
        legacyAgentFound = FileManager.default.fileExists(atPath: legacyPlistURL.path)
        switch service.status {
        case .notRegistered:
            state = .disabled
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .notFound
        @unknown default:
            state = .error
        }
    }

    /// Registers or unregisters the visible app with macOS.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        migrateLegacyAgentIfNeeded()

        let result: Bool
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            result = true
        } catch {
            result = false
            lastError = error.localizedDescription
        }
        refresh()
        return result
    }

    /// Opens the exact System Settings pane needed to approve a login item.
    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Removes only the historical NETworkManager LaunchAgent. This is called
    /// before registration so the old plist cannot start a second app instance.
    public func migrateLegacyAgentIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else {
            legacyAgentFound = false
            return
        }

        let uid = getuid()
        let domain = "gui/\(uid)"
        _ = Shell.runSync("/bin/launchctl", ["bootout", domain, legacyPlistURL.path])
        _ = Shell.runSync("/bin/launchctl", ["unload", "-w", legacyPlistURL.path])
        do {
            try FileManager.default.removeItem(at: legacyPlistURL)
            legacyAgentFound = false
        } catch {
            lastError = "Could not remove the legacy login item: \(error.localizedDescription)"
            legacyAgentFound = true
        }
    }
}

