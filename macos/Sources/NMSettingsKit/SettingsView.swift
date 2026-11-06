import SwiftUI
import NMCore

public struct SettingsView: View {
    @ObservedObject private var theme = Theme.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var loginItem = LoginItemManager.shared
    @ObservedObject private var localization = Loc.shared
    @NMStateCompat private var language: AppLanguage
    @NMStateCompat private var showingResetConfirmation = false

    public init() { _language = NMStateCompat(wrappedValue: SettingsStore.shared.language ?? .system) }

    public var body: some View {
        Form {
            Section(t("Appearance")) {
                Picker(t("Theme"), selection: $theme.appearance) { ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) } }
                Picker(t("Accent color"), selection: $theme.accent) { ForEach(AppAccent.allCases) { Text($0.displayName).tag($0) } }
            }
            Section(t("General")) {
                if let recoveryError = settings.recoveryError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(t("Settings recovery required"), systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(recoveryError).font(.callout).textSelection(.enabled)
                        if let preservedURL = settings.preservedCorruptFileURL {
                            Text(tf("Damaged data copy: %@", preservedURL.path))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        Button(t("Reset settings and recover"), role: .destructive) {
                            showingResetConfirmation = true
                        }
                    }
                    .padding(.vertical, 6)
                }
                if let persistenceError = settings.persistenceError {
                    Text(persistenceError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Picker(t("Language"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) } }
                    .onChange(of: language) { _, value in localization.language = value }
                    .disabled(settings.recoveryError != nil)
                Toggle(t("Start with macOS"), isOn: $settings.launchAtLogin)
                    .disabled(settings.recoveryError != nil)
                Text(t("This opens the visible app at login. It does not keep a background worker running."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(loginItem.state == .enabled ? Color.green : (loginItem.state == .requiresApproval ? Color.orange : Color.secondary))
                        .frame(width: 7, height: 7)
                    Text(loginItemStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loginItem.state == .requiresApproval {
                        Button(t("Open Login Items")) { loginItem.openSystemSettings() }
                            .buttonStyle(.borderless)
                    }
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if loginItem.legacyAgentFound {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(t("A legacy login item was found and will be removed when this setting is changed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(t("Show status bar"), isOn: $settings.showStatusBar)
                    .disabled(settings.recoveryError != nil)
            }
            Section(t("About")) {
                LabeledContent(t("Version"), value: "macOS preview")
                LabeledContent(t("Platform"), value: "macOS 14+")
                Text(t("NETworkManager runs as a visible app and exits when its last window closes. It does not install a separate daemon."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 680)
        .alert(t("Reset settings and recover?"), isPresented: $showingResetConfirmation) {
            Button(t("Cancel"), role: .cancel) {}
            Button(t("Reset settings and recover"), role: .destructive) { settings.reset() }
        } message: {
            Text(t("This restores default preferences and keeps a copy of the damaged settings file."))
        }
    }

    private var loginItemStatus: String {
        switch loginItem.state {
        case .enabled: return t("Login item enabled")
        case .requiresApproval: return t("Approval required in System Settings")
        case .disabled: return t("Login item disabled")
        case .notFound: return t("Login item unavailable for this app bundle")
        case .unavailable: return t("Login item status unavailable")
        case .error: return t("Login item error")
        }
    }
}
