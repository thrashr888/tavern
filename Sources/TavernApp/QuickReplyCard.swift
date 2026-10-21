import AppKit
import SwiftUI
import TavernCore

extension View {
    /// Hovering a sidebar row opens a card with the member's info, their latest message, any
    /// approval waiting on you, and a reply box, so you can answer without leaving the page.
    func memberQuickCard(_ member: RosterMember) -> some View {
        modifier(QuickCardModifier(member: member))
    }
}

/// The one quick card in the sidebar: which member it's for, and the hover rules every row
/// shares. The first hover waits like a tooltip; while a card is open (or just closed), moving to
/// another row switches to it at once. Leaving both the row and the card closes it, unless a
/// reply is being written. A click on a row closes it and keeps it closed until the pointer leaves.
@MainActor
final class QuickCardController: ObservableObject {
    static let shared = QuickCardController()

    @Published private(set) var active: String?
    private var overRow: String?
    private var overCard = false
    var writing = false
    private var clicked: String?
    private var lastClosed = Date.distantPast
    private var generation = 0
    /// While ⌘K (or anything else on top) is open: no cards.
    private var suspended = false

    func setSuspended(_ value: Bool) {
        suspended = value
        generation += 1
        if value { close() }
    }

    func enterRow(_ id: String) {
        overRow = id
        generation += 1
        guard clicked != id, !suspended else { return }
        if writing, active != nil, active != id { return }
        // Already showing one, or one just closed: switch now.
        if active != nil || Date().timeIntervalSince(lastClosed) < 0.6 {
            active = id
            return
        }
        let mine = generation
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard mine == generation, overRow == id, clicked != id, !suspended else { return }
            active = id
        }
    }

    func leaveRow(_ id: String) {
        if overRow == id { overRow = nil }
        if clicked == id { clicked = nil }
        closeSoon()
    }

    func enterCard() {
        overCard = true
        generation += 1
    }

    func leaveCard() {
        overCard = false
        closeSoon()
    }

    func click(_ id: String) {
        clicked = id
        generation += 1
        close()
    }

    func stoppedWriting() {
        writing = false
        closeSoon()
    }

    /// Closes unless the pointer reaches the card (or another row) within a moment.
    private func closeSoon() {
        generation += 1
        let mine = generation
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard mine == generation, !overCard, !writing else { return }
            if let row = overRow, row != clicked, !suspended { active = row } else { close() }
        }
    }

    private func close() {
        if active != nil { lastClosed = Date() }
        active = nil
    }
}

private struct QuickCardModifier: ViewModifier {
    let member: RosterMember
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var controller = QuickCardController.shared
    @State private var writing = false
    @State private var overRow = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                overRow = inside
                if inside { controller.enterRow(member.id) } else { controller.leaveRow(member.id) }
            }
            .background(
                NonModalPopover(isPresented: Binding(get: { controller.active == member.id }, set: { _ in })) {
                    QuickReplyCard(member: member, writing: $writing)
                        .environmentObject(model)
                        .onHover { inside in
                            if inside { controller.enterCard() } else { controller.leaveCard() }
                        }
                }
            )
            .onChange(of: writing) { _, now in
                if now { controller.writing = true } else { controller.stoppedWriting() }
            }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    if overRow { controller.click(member.id) }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// The card's window: a borderless panel beside the row, attached to the main window. Unlike a
/// popover it doesn't take keyboard focus when it appears (so the sidebar keeps tracking the
/// pointer, and hovering the next row or leaving still works), it doesn't swallow clicks outside
/// it, and it becomes key only when you click into its message box.
private struct NonModalPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        if isPresented, let window = anchor.window {
            coordinator.show(content(), beside: anchor, in: window)
        } else {
            coordinator.hide()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?
        private var host: NSHostingController<AnyView>?

        func show(_ content: Content, beside anchor: NSView, in window: NSWindow) {
            let root = AnyView(
                content
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            )
            let panel = self.panel ?? makePanel()
            if let host { host.rootView = root } else {
                // The panel follows the card's size as its content loads.
                let host = NSHostingController(rootView: root)
                host.sizingOptions = .preferredContentSize
                panel.contentViewController = host
                self.host = host
            }
            let size = host?.view.fittingSize ?? NSSize(width: 360, height: 200)
            let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            var origin = NSPoint(x: row.maxX + 8, y: row.maxY - size.height)
            if let screen = window.screen?.visibleFrame {
                origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - size.height - 8))
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        }

        func hide() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func makePanel() -> NSPanel {
            let panel = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            self.panel = panel
            return panel
        }
    }
}

/// Borderless panels can't become key by default; the card's message box needs to.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickReplyCard: View {
    let member: RosterMember
    @Binding var writing: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemberHoverCard(member: member)
            Divider()
            Group {
                if member.kind == .pi, let session = model.session(for: member.id) {
                    PiQuickReply(member: member, session: session, writing: $writing)
                } else if let handle = member.imessage {
                    IMessageQuickReply(member: member, handle: handle, writing: $writing)
                } else {
                    MailQuickView(member: member)
                }
            }
            .padding(14)
        }
        .frame(width: 360, alignment: .leading)
    }
}

/// A Pi agent: the approval or question waiting on you, the latest reply (or what it's writing
/// now), and a box that sends, or queues while it works.
private struct PiQuickReply: View {
    let member: RosterMember
    @ObservedObject var session: PiAgentSession
    @Binding var writing: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let dialog = session.dialog {
                DialogBanner(dialog: dialog) { answer in
                    Task { await session.answer(answer) }
                }
            }
            if let latest {
                LatestMessage(who: latest.who, text: latest.text, date: latest.date)
            } else {
                Text("No messages yet.").tavernFont(.caption).foregroundStyle(.secondary)
            }
            ReplyBox(placeholder: session.presence == .working ? "Queue a message for \(member.name)" : "Message \(member.name)",
                     draft: $draft, writing: $writing) { text in
                if session.presence == .working { await session.followUp(text) } else { await session.send(text) }
                return nil
            }
        }
    }

    private var latest: (who: String, text: String, date: Date?)? {
        if !session.streamingText.isEmpty { return (member.name, session.streamingText, nil) }
        if let pending = session.pendingMessages.last { return ("You", pending.text, pending.date) }
        guard let item = session.transcript.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty })
        else { return nil }
        return (item.role == .user ? "You" : member.name, item.text, item.date)
    }
}

/// A member on iMessage: their latest message and a reply sent through cider.
private struct IMessageQuickReply: View {
    let member: RosterMember
    let handle: String
    @Binding var writing: Bool
    @EnvironmentObject private var model: AppModel
    @State private var latest: IMessage?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let latest {
                LatestMessage(who: latest.fromMe ? "You" : member.name, text: latest.displayText, date: latest.date)
            } else {
                Text("No iMessages this week.").tavernFont(.caption).foregroundStyle(.secondary)
            }
            ReplyBox(placeholder: "iMessage \(member.name)", draft: $draft, writing: $writing) { text in
                do {
                    try await CiderMessages().send(text, to: handle)
                    await load()
                    return nil
                } catch {
                    return "Couldn't send: \(error)"
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if latest == nil { latest = model.imessageHistory[handle]?.last(where: { $0.tapback == nil }) }
        guard let history = try? await CiderMessages().history(with: handle, days: 7) else { return }
        model.imessageHistory[handle] = history
        latest = history.last(where: { $0.tapback == nil })
    }
}

/// A member reached only by mail (or through another member): their latest party mail.
private struct MailQuickView: View {
    let member: RosterMember
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let relay = member.relay.flatMap({ model.roster.member(id: $0) }) {
                Text("Reached through \(relay.name).").tavernFont(.caption).foregroundStyle(.secondary)
            }
            if let message = (model.mail?.threads ?? []).flatMap(\.messages).filter({ $0.author == member.id }).max(by: { $0.date < $1.date }) {
                LatestMessage(who: member.name, text: "\(message.subject)\n\(message.body.isEmpty ? message.snippet : message.body)",
                              date: message.date)
            } else {
                Text("\(member.name) hasn't written to the \(model.roster.party) yet.").tavernFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LatestMessage: View {
    let who: String
    let text: String
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(who).tavernFont(.caption, weight: .semibold)
                Spacer()
                if let date {
                    Text(date.formatted(.relative(presentation: .named))).tavernFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text("writing…").tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(LinkedText.attributed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .tavernFont(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A one-to-four-line box; Return sends, Option-Return makes a new line. `send` returns an error
/// to show, or nil.
private struct ReplyBox: View {
    let placeholder: String
    @Binding var draft: String
    @Binding var writing: Bool
    let send: (String) async -> String?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(submit)
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.tavernAccent : Color.secondary)
                    .disabled(!canSend)
                    .help("Send")
            }
            if let error { Text(error).tavernFont(.caption).foregroundStyle(.orange) }
        }
        // Typing keeps the card open: the box focused with something in it.
        .onChange(of: focused) { _, now in writing = now && !draft.isEmpty }
        .onChange(of: draft) { _, now in writing = focused && !now.isEmpty }
        .onDisappear { writing = false }
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            error = await send(text)
            if error == nil { draft = "" }
            sending = false
        }
    }
}
