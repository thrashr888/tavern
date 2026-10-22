import AppKit
import SwiftUI
import TavernCore

/// A hosted party member (ChatGPT, Grok, Instinct, Claude cloud…), laid out like a Pi agent's
/// page: the conversation fills the middle (iMessage when the member has a handle, otherwise
/// their party threads), and the side panel holds who they are, their tasks and their threads.
struct MemberView: View {
    let memberID: String
    @Binding var selection: Page?
    @EnvironmentObject private var model: AppModel
    @SceneStorage("tavern.inspector") private var showInspector = true

    var body: some View {
        if let member = model.roster.member(id: memberID) {
            Group {
                if let handle = member.imessage {
                    IMessageConversation(member: member, handle: handle, lastSeen: model.lastSeen[member.id])
                } else if let relayID = member.relay, let relay = model.roster.member(id: relayID) {
                    // Reached through another member: point there, and still show their mail.
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            AvatarView(member: relay, size: 28)
                            Text("\(member.name) is reached through \(relay.name).").tavernFont(.callout)
                            Spacer()
                            Button("Message \(relay.name)") { selection = .forMember(relay) }
                                .buttonStyle(PillButtonStyle())
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .padding([.horizontal, .top], 24)
                        if let mail = model.mail {
                            ScrollView {
                                MemberThreads(mail: mail, member: member, selection: $selection, pageSize: 25, title: "\(model.roster.party) threads")
                                    .padding(24)
                            }
                        }
                    }
                } else if let mail = model.mail {
                    ScrollView {
                        MemberThreads(mail: mail, member: member, selection: $selection, pageSize: 25, title: "\(model.roster.party) threads")
                            .padding(24)
                    }
                } else {
                    Text("\(member.name) is reachable by mail only.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(member.name)
            .hidingWindowTitle()
            .onReceive(NotificationCenter.default.publisher(for: .tavernToggleInspector)) { _ in showInspector.toggle() }
            .inspectorToggle($showInspector)
            .inspector(isPresented: $showInspector) {
                MemberInspector(member: member, selection: $selection)
                    .inspectorClose($showInspector)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
        } else {
            Text("No party member \(memberID)").foregroundStyle(.secondary)
        }
    }
}

/// Avatar, Write in Gmail, tasks, identity and the latest threads (five at a time).
private struct MemberInspector: View {
    let member: RosterMember
    @Binding var selection: Page?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    AvatarView(member: member, size: 140)
                    Text(member.name).tavernFont(.title2, weight: .semibold)
                    Text([member.partyClass, member.animal].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    if let address = lastAddress {
                        Button {
                            var parts = URLComponents(string: "https://mail.google.com/mail/")!
                            parts.queryItems = [.init(name: "view", value: "cm"), .init(name: "to", value: address),
                                                .init(name: "su", value: "The \(model.roster.party): ")]
                            if let url = parts.url { NSWorkspace.shared.open(url) }
                        } label: { Label("Write in Gmail", systemImage: "square.and.pencil") }
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)

                AgentTasksSection(agent: member)
                AgentSpellCasts(member: member, book: model.spellbook)
                AgentSpellsSection(member: member, book: model.spellbook)

                InfoCard(title: "Identity") {
                    InfoRow(label: "Class", value: member.partyClass ?? "–")
                    if let animal = member.animal { InfoRow(label: "Animal", value: animal) }
                    InfoRow(label: "Reach", value: member.relay.flatMap { model.roster.member(id: $0)?.name }.map { "Through \($0)" }
                            ?? (member.imessage == nil ? "\(model.roster.party) mail" : "iMessage, mail"))
                    if let seen = model.lastSeen[member.id] {
                        InfoRow(label: "Last mail", value: seen.formatted(.relative(presentation: .named)))
                    }
                    if let summary = member.summary { InfoRow(label: "About", value: summary) }
                }

                if member.imessage != nil, let mail = model.mail {
                    MemberThreads(mail: mail, member: member, selection: $selection, pageSize: 5, title: "Recent threads", compact: true)
                }
            }
            .padding(16)
        }
    }

    /// The address their latest party mail came from.
    private var lastAddress: String? {
        let messages = (model.mail?.threads ?? []).flatMap(\.messages).filter { $0.author == member.id }
        guard let from = messages.max(by: { $0.date < $1.date })?.from else { return nil }
        if let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
            return String(from[from.index(after: open)..<close])
        }
        return from.contains("@") ? from : nil
    }
}

/// Threads a member wrote in, newest first, a page at a time with "Show more".
private struct MemberThreads: View {
    @ObservedObject var mail: MailFeed
    let member: RosterMember
    @Binding var selection: Page?
    let pageSize: Int
    let title: String
    var compact = false
    @EnvironmentObject private var model: AppModel
    @State private var shown: Int?
    @State private var query = ""
    /// Shared with the Mail page: threads archived in Gmail stay hidden unless asked for.
    @AppStorage("tavern.mail.showArchived") private var showArchived = false

    var body: some View {
        let involved = mail.threads.involving(member.id).filter { !$0.isHeartbeat }
        let archived = involved.filter(mail.isArchived).count
        let all = involved
            .filter { showArchived || !mail.isArchived($0) }
            .filter { $0.matches(query, roster: model.roster) }
        let limit = shown ?? pageSize
        let visible = all.prefix(limit)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).tavernFont(compact ? .caption : .headline, weight: .semibold)
                    .foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                if !all.isEmpty { CountBadge(count: all.count) }
            }
            if !compact, !involved.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(member.name)'s threads", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
                    }
                    if archived > 0 {
                        Toggle(isOn: $showArchived) { Text(showArchived ? "Hide archived" : "Show \(archived) archived") }
                            .toggleStyle(.button).buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if involved.isEmpty {
                Text("\(member.name) hasn't written to the \(model.roster.party) yet.").foregroundStyle(.secondary)
            } else if all.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Every thread with \(member.name) is archived."
                     : "No threads match “\(query)”.").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(visible)) { thread in
                        Button {
                            model.focusedMailThread = thread.threadID
                            selection = .mail(project: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(thread.subject).tavernFont(.callout, weight: .semibold).lineLimit(compact ? 2 : 1)
                                    Spacer()
                                    Text(thread.lastDate.formatted(.relative(presentation: .named)))
                                        .tavernFont(.caption).foregroundStyle(.secondary).fixedSize()
                                }
                                if !compact {
                                    HStack(spacing: 4) {
                                        ForEach(thread.authors.compactMap(model.roster.member(id:))) { author in
                                            AvatarView(member: author, size: 22)
                                        }
                                        Text(thread.messages.last(where: { $0.author == member.id })?.snippet ?? "")
                                            .tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .padding(.horizontal, compact ? 10 : 14)
                            .padding(.vertical, compact ? 8 : 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if thread.id != visible.last?.id { Divider().padding(.leading, compact ? 10 : 14) }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                if all.count > limit {
                    Button("Show \(min(pageSize, all.count - limit)) more") { shown = limit + pageSize }
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: compact ? .infinity : 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
    }
}

/// A member's iMessage conversation, full height, read and sent through cider. Refreshes every
/// 15 seconds; a message goes out only when the user presses Send.
private struct IMessageConversation: View {
    let member: RosterMember
    let handle: String
    let lastSeen: Date?
    @EnvironmentObject private var model: AppModel
    @State private var messages: [IMessage] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var needsDiskAccess = false
    @State private var sending = false
    @State private var images: [DraftImage] = []
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    private let cider = CiderMessages()

    /// Ids of messages matching the find query, oldest first.
    private var findMatchIDs: [String] {
        guard finding, !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return messages.suffix(200).filter { findMatches($0.text, findQuery) }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if finding {
                FindBar(query: $findQuery, current: $findIndex, matchCount: findMatchIDs.count) {
                    finding = false
                    findQuery = ""
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: scrolling to the end needs every bubble's real height.
                    VStack(alignment: .leading, spacing: 8) {
                        if messages.isEmpty && error == nil && !needsDiskAccess {
                            Text("No messages with \(member.name) in the last week.").foregroundStyle(.secondary).padding(8)
                        }
                        let matches = findMatchIDs
                        let currentMatch = matches.indices.contains(findIndex) ? matches[findIndex] : nil
                        // Tapbacks ("Liked “…”") show on the message they point to, not as bubbles.
                        ForEach(IMessage.withReactions(Array(messages.suffix(200)))) { row in
                            bubble(row.message, reactions: row.reactions)
                                .findHighlight(matched: matches.contains(row.id), current: row.id == currentMatch)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: findQuery) { _, _ in
                    findIndex = max(findMatchIDs.count - 1, 0)
                    if let id = findMatchIDs.last { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: findIndex) { _, index in
                    let ids = findMatchIDs
                    if ids.indices.contains(index) { withAnimation { proxy.scrollTo(ids[index], anchor: .center) } }
                }
                // New messages (sent or received) scroll into view once laid out.
                .onChange(of: messages.count) { old, _ in
                    DispatchQueue.main.async {
                        if old == 0 { proxy.scrollTo("bottom", anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                }
            }
            composer
        }
        .task(id: handle) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFocusComposer)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFind)) { _ in finding = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(member: member, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name).tavernFont(.callout, weight: .semibold)
                Text(["iMessage", handle].joined(separator: " · ")).tavernFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .contentShape(Capsule())
        .onTapGesture { NotificationCenter.default.post(name: .tavernToggleInspector, object: nil) }
        .help("Show or hide \(member.name)'s panel")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func bubble(_ message: IMessage, reactions: [Reaction] = []) -> some View {
        HStack {
            if message.fromMe { Spacer(minLength: 80) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                if !message.images.isEmpty { InlineImages(paths: message.images) }
                if !message.displayText.isEmpty {
                    // Plain text: an iMessage is not Markdown, and a [label](url) must not hide where it goes.
                    // Web addresses open in the default browser.
                    Text(LinkedText.attributed(message.displayText))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.fromMe ? AnyShapeStyle(Color.tavernAccent.opacity(0.85)) : AnyShapeStyle(.quaternary.opacity(0.7)),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(message.fromMe ? Color.white : Color.primary)
                }
                if !reactions.isEmpty { ReactionChips(reactions: reactions) }
            }
            .help(message.date.formatted(date: .abbreviated, time: .shortened))
            if !message.fromMe { Spacer(minLength: 80) }
        }
        .id(message.id)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if needsDiskAccess {
                HStack(spacing: 10) {
                    Label("Tavern needs Full Disk Access to read your Messages history. Sending works without it.",
                          systemImage: "lock.shield")
                        .tavernFont(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(PillButtonStyle())
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                AddImageButton(images: $images).padding(.bottom, 8)
                EmojiDraftButton(draft: $draft).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    AttachmentTray(images: $images)
                    TextField("iMessage \(member.name)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                    dropTargeted ? Color.tavernAccent : (focused ? Color.tavernAccent.opacity(0.5) : Color.secondary.opacity(0.25)),
                    lineWidth: dropTargeted ? 2 : 1))
                .acceptsImageDrops(into: $images, targeted: $dropTargeted)
                .onPasteCommand(of: [.image, .fileURL]) { _ in images += DraftImage.fromPasteboard() }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.tavernAccent : Color.secondary.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send with iMessage (Return)")
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool { !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    private func load() async {
        // The conversation as last read shows at once; the fresh read replaces it.
        if messages.isEmpty, let cached = model.imessageHistory[handle] { messages = cached }
        do {
            messages = try await cider.history(with: handle)
            model.imessageHistory[handle] = messages
            error = nil
            needsDiskAccess = false
        } catch {
            // macOS guards chat.db; reading it needs Full Disk Access for Tavern itself.
            needsDiskAccess = String(describing: error).contains("authorization denied")
            self.error = "Couldn't read Messages: \(error)"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sending = true
        let attached = images
        Task {
            do {
                for image in attached {
                    try await cider.sendImage(image.data, fileExtension: image.mimeType == "image/png" ? "png" : "jpg", to: handle)
                }
                images = []
                if !text.isEmpty { try await cider.send(text, to: handle) }
                draft = ""
                error = nil
                // Show it right away; the next read replaces it with the stored copy.
                attached.forEach { AttachmentCache.store($0.piImage) }
                messages.append(IMessage(id: "pending-\(UUID())", text: text.isEmpty ? "[Attachment]" : text, fromMe: true, date: Date(),
                                         attachments: attached.compactMap { AttachmentCache.localPath(for: $0.piImage) }))
                try? await Task.sleep(for: .seconds(2))
                await load()
            } catch {
                self.error = "Couldn't send: \(error)"
            }
            sending = false
        }
    }
}
