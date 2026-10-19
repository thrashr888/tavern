import AppKit
import SwiftUI
import TavernCore

/// The Pi agent whose page is open, so the Agent menu can act on it.
struct CurrentAgentKey: FocusedValueKey {
    typealias Value = PiAgentSession
}

extension FocusedValues {
    var currentAgent: PiAgentSession? {
        get { self[CurrentAgentKey.self] }
        set { self[CurrentAgentKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Focus the message field on the open agent page (File > New Message).
    static let tavernFocusComposer = Notification.Name("tavern.focusComposer")
    /// Reload the open page's data (File > Refresh).
    static let tavernRefresh = Notification.Name("tavern.refresh")
    /// Show or hide the agent side panel (View > Show Inspector).
    static let tavernToggleInspector = Notification.Name("tavern.toggleInspector")
}

/// File, View, Agent and Help menu items, so Tavern behaves like a regular Mac app.
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.currentAgent) private var agent
    @AppStorage("tavern.mail.showHeartbeats") private var showHeartbeats = false
    @AppStorage("tavern.mail.showArchived") private var showArchived = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                if agent == nil, let first = model.roster.piAgents.first {
                    NotificationCenter.default.post(name: .tavernOpenPage, object: Page.agent(id: first.id).storageKey)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(name: .tavernFocusComposer, object: nil)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Ticket…") {
                model.newTicketRequested = true
                NotificationCenter.default.post(name: .tavernOpenPage, object: Page.goals.storageKey)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.linear == nil)
            Divider()
            Button("Refresh") { NotificationCenter.default.post(name: .tavernRefresh, object: nil) }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Show or Hide Inspector") { NotificationCenter.default.post(name: .tavernToggleInspector, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Show Heartbeat Mail", isOn: $showHeartbeats)
            Toggle("Show Archived Mail", isOn: $showArchived)
            Divider()
        }

        CommandMenu("Agent") {
            Button("Message \(agentName)") { NotificationCenter.default.post(name: .tavernFocusComposer, object: nil) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(agent == nil)
            Divider()
            Button("Abort Turn") { if let agent { Task { await agent.abort() } } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(agent?.isWorking != true)
            Button("Compact Context") { if let agent { Task { await agent.compact() } } }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(agent == nil || agent?.isWorking == true)
            Button("Reconnect") { if let agent { Task { await agent.reconnectNow() } } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(agent == nil)
        }

        CommandGroup(replacing: .help) {
            ForEach(model.roster.loreLinks) { link in
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
            Divider()
            Button("Tavern on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/thrashr888/tavern")!)
            }
        }
    }

    private var agentName: String {
        guard let agent else { return "Agent" }
        return model.roster.member(id: agent.agentID)?.name ?? "Agent"
    }
}
