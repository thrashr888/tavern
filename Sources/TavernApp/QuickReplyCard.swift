import SwiftUI
import TavernCore

extension View {
    /// Hovering a sidebar row opens a card with the member's info, their latest message, any
    /// approval waiting on you, and a reply box, so you can answer without leaving the page.
    func memberQuickCard(_ member: RosterMember) -> some View {
        modifier(QuickCardModifier(member: member))
    }
}

/// Opens after a short hover and stays while the pointer is over the row or the card, or while
/// a reply is being written.
private struct QuickCardModifier: ViewModifier {
    let member: RosterMember
    @State private var overRow = false
    @State private var overCard = false
    @State private var writing = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                overRow = inside
                settle()
            }
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                QuickReplyCard(member: member, writing: $writing)
                    .onHover { inside in
                        overCard = inside
                        settle()
                    }
            }
    }

    private func settle() {
        let wantsOpen = overRow || overCard
        Task {
            try? await Task.sleep(for: .milliseconds(wantsOpen ? 500 : 350))
            if wantsOpen, overRow || overCard { showing = true }
            if !wantsOpen, !overRow, !overCard, !writing { showing = false }
        }
    }
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
        latest = try? await CiderMessages().history(with: handle, days: 7).last(where: { !$0.text.hasPrefix("Reacted ") })
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
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .help("Send")
            }
            if let error { Text(error).tavernFont(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: focused) { _, now in writing = now || !draft.isEmpty }
        .onChange(of: draft) { _, now in writing = focused || !now.isEmpty }
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
