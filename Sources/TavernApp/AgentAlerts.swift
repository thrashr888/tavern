import AppKit
import Combine
import TavernCore
import UserNotifications

/// Tells the user when a Pi agent is waiting on him or finished a turn while Tavern is in the
/// background: a notification when Tavern runs as an app bundle, a Dock bounce otherwise
/// (`swift run` has no bundle, so the notification center isn't available), and a Dock badge
/// counting agents waiting on him.
@MainActor
final class AgentAlerts {
    private var watchers: [String: AnyCancellable] = [:]
    private var waiting: Set<String> = []
    private var lastPresence: [String: PiAgentSession.Presence] = [:]

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func watch(_ session: PiAgentSession, name: String) {
        let agentID = session.agentID
        lastPresence[agentID] = session.presence
        watchers[agentID] = session.$dialog.combineLatest(session.$presence)
            .sink { [weak self] dialog, presence in
                Task { @MainActor in self?.update(agentID: agentID, name: name, dialog: dialog, presence: presence) }
            }
    }

    private func update(agentID: String, name: String, dialog: PiDialog?, presence: PiAgentSession.Presence) {
        if let dialog, !waiting.contains(agentID) {
            waiting.insert(agentID)
            alert(title: "\(name) is waiting on you", body: dialog.title, id: "dialog-\(agentID)", critical: true)
        } else if dialog == nil {
            waiting.remove(agentID)
        }
        if lastPresence[agentID] == .working, presence == .idle, !NSApp.isActive {
            alert(title: "\(name) finished", body: "The turn settled.", id: "settled-\(agentID)", critical: false)
        }
        lastPresence[agentID] = presence
        NSApp.dockTile.badgeLabel = waiting.isEmpty ? nil : "\(waiting.count)"
    }

    private func alert(title: String, body: String, id: String, critical: Bool) {
        if !NSApp.isActive {
            NSApp.requestUserAttention(critical ? .criticalRequest : .informationalRequest)
        }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
