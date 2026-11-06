import SwiftUI
import AppKit

// MARK: - Appearance

public enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return t("System default")
        case .light: return t("Light")
        case .dark: return t("Dark")
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

public enum AppAccent: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue, teal, cyan, green, lime, amber, orange, red, pink, purple, indigo, slate

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }

    public var color: Color {
        switch self {
        case .blue: return Color(red: 0.13, green: 0.47, blue: 0.85)
        case .teal: return Color(red: 0.00, green: 0.59, blue: 0.60)
        case .cyan: return Color(red: 0.00, green: 0.60, blue: 0.75)
        case .green: return Color(red: 0.11, green: 0.60, blue: 0.30)
        case .lime: return Color(red: 0.42, green: 0.64, blue: 0.11)
        case .amber: return Color(red: 0.94, green: 0.65, blue: 0.05)
        case .orange: return Color(red: 0.90, green: 0.47, blue: 0.05)
        case .red: return Color(red: 0.80, green: 0.20, blue: 0.20)
        case .pink: return Color(red: 0.85, green: 0.25, blue: 0.51)
        case .purple: return Color(red: 0.55, green: 0.30, blue: 0.80)
        case .indigo: return Color(red: 0.29, green: 0.31, blue: 0.78)
        case .slate: return Color(red: 0.35, green: 0.40, blue: 0.47)
        }
    }
}

// MARK: - Palette

/// Semantic color palette resolved for a given appearance.
public struct NMPalette {
    public let isDark: Bool
    public let background: Color
    public let sidebar: Color
    public let card: Color
    public let cardAlt: Color
    public let border: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let accent: Color
    public let success: Color
    public let warning: Color
    public let danger: Color
    public let info: Color

    public static func resolve(dark: Bool, accent: Color) -> NMPalette {
        if dark {
            return NMPalette(
                isDark: true,
                background: Color(red: 0.09, green: 0.10, blue: 0.11),
                sidebar: Color(red: 0.12, green: 0.13, blue: 0.15),
                card: Color(red: 0.145, green: 0.155, blue: 0.175),
                cardAlt: Color(red: 0.175, green: 0.185, blue: 0.21),
                border: Color.white.opacity(0.09),
                textPrimary: Color(white: 0.95),
                textSecondary: Color(white: 0.62),
                accent: accent,
                success: Color(red: 0.35, green: 0.78, blue: 0.45),
                warning: Color(red: 0.95, green: 0.72, blue: 0.25),
                danger: Color(red: 0.92, green: 0.38, blue: 0.38),
                info: Color(red: 0.40, green: 0.68, blue: 0.95)
            )
        }
        return NMPalette(
            isDark: false,
            background: Color(red: 0.96, green: 0.965, blue: 0.975),
            sidebar: Color(red: 0.925, green: 0.93, blue: 0.94),
            card: Color.white,
            cardAlt: Color(red: 0.965, green: 0.97, blue: 0.978),
            border: Color.black.opacity(0.10),
            textPrimary: Color(white: 0.11),
            textSecondary: Color(white: 0.42),
            accent: accent,
            success: Color(red: 0.13, green: 0.60, blue: 0.28),
            warning: Color(red: 0.80, green: 0.55, blue: 0.02),
            danger: Color(red: 0.78, green: 0.20, blue: 0.20),
            info: Color(red: 0.16, green: 0.45, blue: 0.80)
        )
    }
}

// MARK: - Theme store

public final class Theme: ObservableObject {
    public static let shared = Theme()

    @Published public var appearance: AppAppearance {
        didSet {
            SettingsStore.shared.appearance = appearance
            Self.applyAppearance(appearance)
        }
    }

    @Published public var accent: AppAccent {
        didSet { SettingsStore.shared.accent = accent }
    }

    public init() {
        let store = SettingsStore.shared
        appearance = store.appearance ?? .system
        accent = store.accent ?? .blue
    }

    public var palette: NMPalette {
        NMPalette.resolve(dark: NSApp?.effectiveAppearance.isDark ?? false, accent: accent.color)
    }

    public var accentColor: Color { accent.color }

    /// Force the whole application into the selected appearance (or back to the
    /// system appearance when `appearance == .system`).
    public static func applyAppearance(_ appearance: AppAppearance) {
        guard let app = NSApp else { return }
        app.appearance = appearance.nsAppearance
        for window in app.windows {
            window.appearance = appearance.nsAppearance
        }
    }
}

public extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: NMPalette = NMPalette.resolve(dark: false, accent: AppAccent.blue.color)
}

public extension EnvironmentValues {
    var palette: NMPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Root modifier that keeps the palette in sync with the appearance/accent settings.
public struct ThemedRoot: ViewModifier {
    // Theme is a process-wide settings store. Using an observed singleton here
    // keeps the Settings scene and command-line-launched app bundle safe even
    // when SwiftUI constructs a scene before environment propagation.
    @ObservedObject private var theme = Theme.shared
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public func body(content: Content) -> some View {
        let palette = NMPalette.resolve(dark: scheme == .dark, accent: theme.accent.color)
        content
            .environment(\.palette, palette)
            .tint(theme.accent.color)
            .preferredColorScheme(theme.appearance == .system ? nil
                                 : (theme.appearance == .dark ? .dark : .light))
    }
}

public extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}
