import AppKit
import SwiftUI
import TavernCore

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
    /// Text on the accent, such as the selected sidebar row.
    var onAccent: Color

    static let parchment = ThemePalette(
        page: Color(red: 0.953, green: 0.910, blue: 0.812),
        sidebar: Color(red: 0.882, green: 0.812, blue: 0.659),
        ink: Color(red: 0.231, green: 0.165, blue: 0.102),
        accent: Color(red: 0.545, green: 0.290, blue: 0.110),
        onAccent: Color(red: 0.980, green: 0.953, blue: 0.890))
    static let hearth = ThemePalette(
        page: Color(red: 0.165, green: 0.118, blue: 0.086),
        sidebar: Color(red: 0.118, green: 0.082, blue: 0.059),
        ink: Color(red: 0.933, green: 0.878, blue: 0.784),
        accent: Color(red: 0.882, green: 0.588, blue: 0.247),
        onAccent: Color(red: 0.165, green: 0.098, blue: 0.051))
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
        .background(ThemedWindow(page: theme.palette.map { NSColor($0.page) }))
        .id(stored)
        .onAppear {
            if stored == "sepia" { stored = Theme.parchment.rawValue }
            Theme.apply(Theme.current)
        }
        .onChange(of: stored) { _, _ in Theme.apply(Theme.current) }
    }
}

/// A floating surface (palette, popover, sheet, hover card) in a party theme: page color, ink
/// and accent. Unlike `themed()`, it doesn't redraw itself or set the app's appearance.
struct ThemedSurface: ViewModifier {
    func body(content: Content) -> some View {
        if let palette = Theme.current.palette {
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
}

extension View {
    func themed() -> some View { modifier(ThemedContent()) }
    func themedSurface() -> some View { modifier(ThemedSurface()) }

    /// The sidebar's own darker color in a party theme; the system sidebar otherwise.
    @ViewBuilder func themedSidebar(_ theme: Theme) -> some View {
        if let palette = theme.palette {
            self.scrollContentBackground(.hidden).background(palette.sidebar)
        } else {
            self
        }
    }
}

/// The window under a themed view: in a party theme its title bar and toolbar (Settings' tabs)
/// take the page color too.
struct ThemedWindow: NSViewRepresentable {
    let page: NSColor?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = page ?? .windowBackgroundColor
            window.titlebarAppearsTransparent = page != nil
        }
    }
}

/// A sidebar link whose selected row, in a party theme, is the theme's accent with its own
/// text color instead of the system's blue.
struct SidebarLink<Label: View>: View {
    let selection: Page?
    let value: Page
    @ViewBuilder let label: () -> Label

    init(selection: Page?, value: Page, @ViewBuilder label: @escaping () -> Label) {
        self.selection = selection
        self.value = value
        self.label = label
    }

    var body: some View {
        let link = NavigationLink(value: value, label: label)
        if let palette = Theme.current.palette, selection == value {
            link
                .foregroundStyle(palette.onAccent)
                .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(palette.accent).padding(.horizontal, 10))
        } else {
            link
        }
    }
}

/// Turns off the sidebar's system selection color in a party theme, so `SidebarLink` draws its own.
struct SidebarHighlight: NSViewRepresentable {
    let custom: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var node: NSView? = view
            while let current = node, !(current is NSSplitView) { node = current.superview }
            guard let root = node else { return }
            for table in Self.tables(in: root) {
                table.selectionHighlightStyle = custom ? .none : .sourceList
            }
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap(tables(in:))
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
