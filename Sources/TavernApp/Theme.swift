import AppKit
import SwiftUI

/// Tavern's look: follow the system, light, dark (the default), or sepia, a parchment-and-wood
/// light theme for the party.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark, sepia

    static let storageKey = "tavern.theme"
    static let standard = Theme.dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        case .sepia: "scroll"
        }
    }

    /// Sepia is drawn on the light appearance, so controls, cards and code stay legible.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? standard }

    /// Applies the appearance to every window, sheet and panel.
    static func apply(_ theme: Theme) {
        NSApp.appearance = theme.appearance
    }
}

/// Sepia's palette: parchment pages, a darker scroll for the sidebar, ink text and leather accents.
enum Sepia {
    static let paper = Color(red: 0.953, green: 0.910, blue: 0.812)
    static let panel = Color(red: 0.918, green: 0.859, blue: 0.733)
    static let sidebar = Color(red: 0.882, green: 0.812, blue: 0.659)
    static let ink = Color(red: 0.231, green: 0.165, blue: 0.102)
    static let accent = Color(red: 0.545, green: 0.290, blue: 0.110)
}

/// The theme on a window's content: its appearance, and for sepia the paper, ink and accent.
struct ThemedContent: ViewModifier {
    @AppStorage(Theme.storageKey) private var theme = Theme.standard

    func body(content: Content) -> some View {
        Group {
            if theme == .sepia {
                content
                    .backgroundStyle(Sepia.paper)
                    .foregroundStyle(Sepia.ink)
                    .tint(Sepia.accent)
                    .background(Sepia.paper)
            } else {
                content
            }
        }
        .onAppear { Theme.apply(theme) }
        .onChange(of: theme) { _, new in Theme.apply(new) }
    }
}

extension View {
    func themed() -> some View { modifier(ThemedContent()) }

    /// The sidebar's own scroll color in sepia; the system sidebar otherwise.
    @ViewBuilder func sepiaSidebar(_ theme: Theme) -> some View {
        if theme == .sepia {
            self.scrollContentBackground(.hidden).background(Sepia.sidebar)
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
