import AppKit
import SwiftUI

/// Tavern's look: follow the system, light, dark (the default), or one of the party's own:
/// Parchment (a scroll, light) and Hearth (burnt umber and dark oak by candlelight).
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark, parchment, hearth

    static let storageKey = "tavern.theme"
    static let standard = Theme.dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .parchment: "Parchment"
        case .hearth: "Hearth"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        case .parchment: "scroll"
        case .hearth: "flame"
        }
    }

    /// The party themes sit on the matching system appearance, so controls, cards and code
    /// stay legible.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .parchment: NSAppearance(named: .aqua)
        case .dark, .hearth: NSAppearance(named: .darkAqua)
        }
    }

    var palette: ThemePalette? {
        switch self {
        case .parchment: .parchment
        case .hearth: .hearth
        default: nil
        }
    }

    /// The stored theme; "sepia" was Parchment's first name.
    static var current: Theme {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return Theme(rawValue: raw == "sepia" ? "parchment" : raw) ?? standard
    }

    /// Applies the appearance to every window, sheet and panel.
    static func apply(_ theme: Theme) {
        NSApp.appearance = theme.appearance
    }
}

/// A party theme's colors: page, panels, the sidebar, text and the accent.
struct ThemePalette {
    var page: Color
    var sidebar: Color
    var ink: Color
    var accent: Color

    static let parchment = ThemePalette(
        page: Color(red: 0.953, green: 0.910, blue: 0.812),
        sidebar: Color(red: 0.882, green: 0.812, blue: 0.659),
        ink: Color(red: 0.231, green: 0.165, blue: 0.102),
        accent: Color(red: 0.545, green: 0.290, blue: 0.110))
    static let hearth = ThemePalette(
        page: Color(red: 0.165, green: 0.118, blue: 0.086),
        sidebar: Color(red: 0.118, green: 0.082, blue: 0.059),
        ink: Color(red: 0.933, green: 0.878, blue: 0.784),
        accent: Color(red: 0.882, green: 0.588, blue: 0.247))
}

extension Color {
    /// The theme's accent (leather or candlelight), else the system's.
    static var tavernAccent: Color { Theme.current.palette?.accent ?? .accentColor }
}

/// The theme on a window's content: its appearance, and for a party theme the page, ink and
/// accent. Changing the theme redraws the window.
struct ThemedContent: ViewModifier {
    @AppStorage(Theme.storageKey) private var stored = Theme.standard.rawValue

    func body(content: Content) -> some View {
        let theme = Theme.current
        Group {
            if let palette = theme.palette {
                content
                    .backgroundStyle(palette.page)
                    .foregroundStyle(palette.ink)
                    .tint(palette.accent)
                    .scrollContentBackground(.hidden)
                    .background(palette.page)
            } else {
                content
            }
        }
        .id(stored)
        .onAppear {
            if stored == "sepia" { stored = Theme.parchment.rawValue }
            Theme.apply(Theme.current)
        }
        .onChange(of: stored) { _, _ in Theme.apply(Theme.current) }
    }
}

extension View {
    func themed() -> some View { modifier(ThemedContent()) }

    /// The sidebar's own darker color in a party theme; the system sidebar otherwise.
    @ViewBuilder func themedSidebar(_ theme: Theme) -> some View {
        if let palette = theme.palette {
            self.scrollContentBackground(.hidden).background(palette.sidebar)
        } else {
            self
        }
    }
}

/// View > Theme.
struct ThemeCommands: Commands {
    @AppStorage(Theme.storageKey) private var theme = Theme.standard

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Theme", selection: $theme) {
                ForEach(Theme.allCases) { Text($0.label).tag($0) }
            }
        }
    }
}

/// The theme picker for Settings.
struct ThemePicker: View {
    @AppStorage(Theme.storageKey) private var theme = Theme.standard

    var body: some View {
        Picker("Theme", selection: $theme) {
            ForEach(Theme.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.inline)
    }
}
