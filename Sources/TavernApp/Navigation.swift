import AppKit
import SwiftUI
import TavernCore

/// Keyboard navigation. ⌘1 Dashboard, ⌘2 Goals, ⌘3… the Pi agents, then Services and Mail;
/// ⌥⌘1… the hosted party members. Holding ⌘ (or ⌥⌘) shows each shortcut in the sidebar.
enum Shortcuts {
    struct Entry {
        var page: Page
        var title: String
        var key: Character
        var option: Bool
    }

    static func entries(for roster: Roster) -> [Entry] {
        var fixed: [(Page, String)] = [(.dashboard, "Dashboard"), (.goals, "Goals")]
        fixed += roster.piAgents.map { (Page.agent(id: $0.id), $0.name) }
        fixed += [(.services, "Services"), (.mail(project: nil), "Mail")]
        var entries = fixed.prefix(9).enumerated().map { index, item in
            Entry(page: item.0, title: item.1, key: Character(String(index + 1)), option: false)
        }
        let hosted = roster.members.filter { $0.kind == .hosted }.prefix(9)
        entries += hosted.enumerated().map { index, member in
            Entry(page: .member(id: member.id), title: member.name, key: Character(String(index + 1)), option: true)
        }
        return entries
    }

    static func label(for page: Page, roster: Roster) -> String? {
        entries(for: roster).first { $0.page == page }.map { ($0.option ? "⌥⌘" : "⌘") + String($0.key) }
    }
}

/// Go menu: every shortcut, so they're discoverable in the menu bar too.
struct GoCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(Shortcuts.entries(for: model.roster).enumerated()), id: \.offset) { _, entry in
                Button(entry.title) { NotificationCenter.default.post(name: .tavernOpenPage, object: entry.page.storageKey) }
                    .keyboardShortcut(KeyEquivalent(entry.key), modifiers: entry.option ? [.command, .option] : .command)
            }
            Divider()
            Button("Agent config") { NotificationCenter.default.post(name: .tavernOpenPage, object: Page.settings.storageKey) }
            // ⌘, stays with Tavern > Settings…, as on every Mac app.
            SettingsLink { Text("Settings…") }
        }
    }
}

/// Watches the modifier keys; after a short hold of ⌘ the sidebar shows shortcut hints.
@MainActor
final class ModifierWatcher: ObservableObject {
    enum Held { case none, command, commandOption }
    @Published private(set) var held: Held = .none
    private var monitor: Any?
    private var pending: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            self?.update(event)
            return event
        }
    }

    private func update(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Typing a shortcut (⌘C) shouldn't flash hints; only a deliberate hold does.
        if event.type == .keyDown { pending?.cancel(); held = .none; return }
        // A click without ⌘ means the key isn't down any more, even if its release was missed.
        if event.type == .leftMouseDown { if !flags.contains(.command) { pending?.cancel(); held = .none }; return }
        let next: Held = flags == .command ? .command : (flags == [.command, .option] ? .commandOption : .none)
        pending?.cancel()
        if next == .none { held = .none; return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.held = next
        }
    }
}

/// The small "⌘3" capsule beside a sidebar row while ⌘ is held.
struct ShortcutHint: View {
    let page: Page
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modifiers: ModifierWatcher

    var body: some View {
        if let label = Shortcuts.label(for: page, roster: model.roster),
           (modifiers.held == .command && !label.hasPrefix("⌥")) || (modifiers.held == .commandOption && label.hasPrefix("⌥")) {
            Text(label)
                .tavernFont(.caption, weight: .semibold)
                .monospaced()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .transition(.opacity)
        }
    }
}

extension Notification.Name {
    /// Opens the page whose storage key is the notification's object.
    static let tavernOpenPage = Notification.Name("tavern.openPage")
}
