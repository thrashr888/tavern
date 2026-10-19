import AppKit
import Combine
import TavernCore
import UserNotifications

/// Something on the Dashboard's "Needs you" list, as a notification: what it is, and where
/// clicking it goes.
struct AttentionItem: Equatable {
    /// Stable while the item stands; a new dialog or a new mail ask gets a new id.
    var id: String
    var title: String
    var body: String
    var page: Page
    var mailThread: String? = nil
    var goal: String? = nil
    /// Connection failures and errors can be momentary (sleep, a reconnect); notify only when
    /// they're still there on the next check.
    var settles = false
}

/// Tells the user when something needs them: a notification for each new "Needs you" item
/// (clicking it opens the right page), a Dock bounce while Tavern is in the background, and a
/// Dock badge with the count. Without an app bundle (`swift run`) only the bounce and badge work.
@MainActor
final class AgentAlerts: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var watchers: [String: AnyCancellable] = [:]
    private var lastPresence: [String: PiAgentSession.Presence] = [:]
    /// Items already notified, kept across launches so a relaunch doesn't repeat them.
    private var notified: Set<String>
    /// Settling items seen once, waiting for a second look.
    private var seenOnce: Set<String> = []
    private static let notifiedKey = "tavern.attention.notified"

    override init() {
        notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedKey) ?? [])
        super.init()
    }

    /// A separate TAVERN_HOME (a demo) shares the app's notifications, so it stays quiet.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && TavernPaths.separateHome == nil }

    func requestPermission() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Re-checks on a dialog or presence change, and notes finished turns.
    func watch(_ session: PiAgentSession, name: String) {
        let agentID = session.agentID
        lastPresence[agentID] = session.presence
        watchers[agentID] = session.$dialog.combineLatest(session.$presence)
            .sink { [weak self] _, presence in
                Task { @MainActor in self?.presenceChanged(agentID: agentID, name: name, presence: presence) }
            }
    }

    private func presenceChanged(agentID: String, name: String, presence: PiAgentSession.Presence) {
        if lastPresence[agentID] == .working, presence == .idle, !NSApp.isActive {
            post(AttentionItem(id: "settled-\(agentID)-\(Date().timeIntervalSince1970)", title: "\(name) finished",
                               body: "The turn settled.", page: .agent(id: agentID)), sound: false)
        }
        lastPresence[agentID] = presence
        model?.checkAttention()
    }

    /// Notifies each item not notified before, and keeps the Dock badge at the count.
    func update(_ items: [AttentionItem]) {
        let ids = Set(items.map(\.id))
        for item in items where !notified.contains(item.id) {
            if item.settles && !seenOnce.contains(item.id) {
                seenOnce.insert(item.id)
                continue
            }
            notified.insert(item.id)
            post(item, sound: true)
        }
        // Forget what's gone, so it notifies again if it comes back.
        notified.formIntersection(ids)
        seenOnce.formIntersection(ids)
        UserDefaults.standard.set(Array(notified), forKey: Self.notifiedKey)
        NSApp.dockTile.badgeLabel = items.isEmpty ? nil : "\(items.count)"
    }

    private func post(_ item: AttentionItem, sound: Bool) {
        if !NSApp.isActive {
            NSApp.requestUserAttention(sound ? .criticalRequest : .informationalRequest)
        }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = sound ? .default : nil
        var info: [String: String] = ["page": item.page.storageKey]
        info["mailThread"] = item.mailThread
        info["goal"] = item.goal
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shown even while Tavern is in front: the item may be on a page you're not looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking a notification opens its page (and selects the mail thread or issue).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let page = info["page"] as? String
        let thread = info["mailThread"] as? String
        let goal = info["goal"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let thread { self.model?.focusedMailThread = thread }
            if let goal {
                self.model?.focusedGoal = goal
                NotificationCenter.default.post(name: .tavernOpenGoals, object: nil)
            } else if let page {
                NotificationCenter.default.post(name: .tavernOpenPage, object: page)
            }
            completionHandler()
        }
    }
}
