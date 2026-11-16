import SwiftUI
import Combine
import TavernCore

/// Injectable owner boundary so the actual dispatcher can be exercised without live accounts.
@MainActor
protocol ProjectChatSessionProvider: AnyObject {
    var roster: Roster { get }
    func session(for agentID: String) -> PiAgentSession?
}

extension AppModel: ProjectChatSessionProvider {}

@MainActor
final class ProjectChatsModel: ObservableObject {
    @Published var chats: [ProjectChat] = []
    @Published var messages: [ProjectChatMessage] = []
    @Published var error: String? { didSet { errorRequestID = nil } }
    private var errorRequestID: String?
    private let store: ProjectChatStore?
    private weak var model: (any ProjectChatSessionProvider)?
    private var watchers: [String: AnyCancellable] = [:]
    private var liveRequests: Set<String> = []
    private var inFlightRequests: Set<String> = []
    private var dispatchedHistoryRevisions: [String: Int] = [:]
    private var draining: Set<String> = []
    init(store: EventStore?, model: any ProjectChatSessionProvider) {
        self.store = store.map(ProjectChatStore.init)
        self.model = model
        reload()
        // A durable claim proves an attempt, not that it survived the previous process.
        // Retain the claim, but never present a recovered attempt as actively sending.
        do {
            for var request in messages where [.dispatching, .waiting].contains(request.state) {
                request.state = .uncertain
                request.failureReason = "Tavern restarted before tracking completed. Delivery is unverified; review the individual agent chat before closing tracking or sending again."
                try self.store?.save(request)
            }
            reload()
        } catch { self.error = "Could not recover interrupted requests: \(error)" }
        for agent in Set(messages.compactMap(\.recipient)) { watch(agent) }
    }
    private func recordRequestError(_ reason: String, requestID: String) {
        error = reason
        errorRequestID = requestID
    }
    private func finishTracking(_ requestID: String) {
        liveRequests.remove(requestID)
        dispatchedHistoryRevisions[requestID] = nil
        // A resolved delivery must not erase an unrelated routing or handoff warning.
        if errorRequestID == requestID { error = nil }
    }
    private var allowed: Set<String> { Set(model?.roster.piAgents.filter { $0.endpoint != nil }.map(\.id) ?? []) }
    func reload() {
        do {
            _ = try store?.ensureHome(participants: model?.roster.piAgents.filter { $0.endpoint != nil }.map(\.id) ?? [])
            chats = try store?.chats() ?? []
            for chat in chats where chat.lead == nil {
                if let first = model?.roster.piAgents.first(where: { chat.participants.contains($0.id) }) {
                    try store?.setLead(chat, first.id)
                }
            }
            chats = try store?.chats() ?? []
            messages = try store?.messages() ?? []
        }
        catch { self.error = "Project chats could not be read: \(error)" }
    }
    func create(title: String, participants: Set<String>, lead: String?) -> String? {
        do {
            guard let store else { error = "Local event store is unavailable."; return nil }
            let chat = try store.create(title: title, participants: model?.roster.piAgents.map(\.id).filter { participants.contains($0) } ?? Array(participants), lead: lead, allowedPiIDs: allowed)
            reload(); error = nil; return chat.id
        } catch { self.error = "Choose a title, at least two configured Pi agents, and a lead from those participants."; return nil }
    }
    func makeLead(_ chat: ProjectChat, _ agent: String) {
        do { try store?.setLead(chat, agent); reload() }
        catch { self.error = "Could not change the lead: \(error)" }
    }
    func archive(_ chat: ProjectChat, _ archived: Bool) {
        do { try store?.setArchived(chat, archived); reload() }
        catch { self.error = "Could not update the conversation: \(error)" }
    }
    func rename(_ chat: ProjectChat, title: String) -> Bool {
        do {
            guard let store else { error = "Local event store is unavailable."; return false }
            try store.rename(chat, title: title); reload(); error = nil; return true
        } catch { self.error = "Use a name between 1 and 120 characters."; return false }
    }
    func setParticipants(_ chat: ProjectChat, _ participants: Set<String>) -> Bool {
        do {
            guard let store else { return false }
            let ordered = model?.roster.piAgents.map(\.id).filter { participants.contains($0) } ?? Array(participants)
            try store.setParticipants(chat, participants: ordered, allowedPiIDs: allowed)
            reload(); error = nil; return true
        } catch { self.error = "Could not update participants: \(error)"; return false }
    }
    func setCoordination(_ chat: ProjectChat, _ enabled: Bool) {
        do { try store?.setCoordinationEnabled(chat, enabled); reload() }
        catch { self.error = "Could not update agent handoffs: \(error)" }
    }
    func send(chat: ProjectChat, recipient: String?, text: String) async -> Bool {
        guard let target = recipient ?? chat.lead else { error = "Select a configured Pi participant."; return false }
        return await sendGroup(chat: chat, text: text, addressed: [target])
    }
    func sendAll(chat: ProjectChat, text: String) async -> Bool {
        await sendGroup(chat: chat, text: text, addressed: nil)
    }
    func sendAddressed(chat: ProjectChat, text: String) async -> Bool {
        let mentions = ProjectChatStore.leadingMentions(in: text)
        guard !mentions.isEmpty else { return await sendAll(chat: chat, text: text) }
        var targets: [String] = []
        for mention in mentions {
            let matches = model?.roster.piAgents.filter {
                chat.participants.contains($0.id) && ($0.id.lowercased() == mention || $0.name.lowercased() == mention)
            } ?? []
            guard matches.count == 1 else {
                error = "Nothing sent. @\(mention) is not a unique configured participant in this thread."
                return false
            }
            targets.append(matches[0].id)
        }
        return await sendGroup(chat: chat, text: text, addressed: targets)
    }
    private func sendGroup(chat: ProjectChat, text: String, addressed: [String]?) async -> Bool {
        guard let store else { error = "Local event store is unavailable."; return false }
        do {
            let requests = try store.enqueue(chat: chat, recipients: addressed ?? chat.participants,
                                             text: text, allowedPiIDs: allowed, group: addressed == nil)
            reload(); error = nil
            for request in requests {
                guard let target = request.recipient else { continue }
                watch(target)
                scheduleDrain(target)
            }
            // The composer clears only after durable enqueue, not after waiting for network/agent work.
            return true
        } catch { self.error = "Could not queue message: \(error)"; return false }
    }
    private func scheduleDrain(_ agent: String) {
        guard draining.insert(agent).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var progressed = false
            defer {
                self.draining.remove(agent)
                if progressed, self.model?.session(for: agent)?.presence == .idle,
                   self.model?.session(for: agent)?.dialog == nil,
                   self.messages.contains(where: { $0.recipient == agent && $0.state == .queued }),
                   !self.messages.contains(where: { $0.recipient == agent && [.dispatching, .waiting, .uncertain].contains($0.state) }) {
                    self.scheduleDrain(agent)
                }
            }
            guard let store = self.store, let session = self.model?.session(for: agent),
                  session.presence == .idle, session.dialog == nil else { return }
            do {
                let request = try store.claimNextQueued(recipient: agent, allowedPiIDs: self.allowed)
                self.reload()
                if let request {
                    await self.dispatch(request)
                    // A local readiness failure leaves the same item queued. Wait for
                    // the session's next readiness update rather than spinning on it.
                    progressed = self.messages.first(where: { $0.id == request.id })?.state != .queued
                }
            } catch { self.error = "Could not deliver queued message: \(error)" }
        }
    }
    func cancelQueued(_ request: ProjectChatMessage) {
        do { try store?.cancelQueued(request.id); reload() }
        catch { self.error = "Could not cancel queued message: \(error)" }
    }
    private func dispatch(_ original: ProjectChatMessage) async {
        guard let target = original.recipient, let store else { return }
        do {
            let current = try store.chats().first { $0.id == original.chatID }
            let removed = current?.archived == true || current?.participants.contains(target) != true
            let handoffDisabled = original.parentMessageID != nil && (
                current?.coordinationEnabled != true || original.author.map({ current?.participants.contains($0) == true }) != true)
            guard !removed, !handoffDisabled else {
                var canceled = original; canceled.state = .closed; canceled.prompt = nil
                try store.save(canceled); reload()
                error = "Request to \(target) was not sent because the project's participants or handoff settings changed."
                return
            }
        } catch { self.error = "Could not check project routing: \(error)"; return }
        guard let session = model?.session(for: target), session.presence == .idle,
              session.dialog == nil, let prompt = original.prompt else {
            // No transport call occurred. Preserve the unattempted request instead of blocking
            // the queue with a false "uncertain" delivery after a local readiness race.
            var queued = original; queued.state = .queued; queued.prompt = nil
            do { try store.save(queued); reload() }
            catch { self.error = "Could not preserve queued message: \(error)" }
            return
        }
        liveRequests.insert(original.id)
        inFlightRequests.insert(original.id)
        dispatchedHistoryRevisions[original.id] = session.historyRevision
        watch(target)
        let outcome = await session.sendProjectRequestOutcome(prompt)
        inFlightRequests.remove(original.id)
        do {
            if var current = try store.messages().first(where: { $0.id == original.id }), [.dispatching, .waiting, .uncertain].contains(current.state) {
                switch outcome {
                case .accepted: current.state = .waiting
                case .notSent:
                    current.state = .queued
                    current.prompt = nil
                    current.failureReason = nil
                    finishTracking(current.id)
                case .uncertain:
                    current.state = .uncertain
                    current.failureReason = "The delivery acknowledgement was lost or interrupted. Review the individual agent chat before closing tracking or sending again."
                case .rejected(let reason):
                    current.state = .closed
                    current.failureReason = reason
                    // No accepted invocation exists to contribute to subsequent agent context.
                    current.prompt = nil
                    finishTracking(current.id)
                }
                try store.save(current)
            }
            reload()
            switch outcome {
            case .accepted, .notSent: break
            case .rejected(let reason): error = "Request to \(target) was rejected: \(reason)"
            case .uncertain:
                recordRequestError("Delivery to \(target) is uncertain or was interrupted. Check its individual chat before resending; Tavern will not retry automatically.", requestID: original.id)
            }
            if let session = model?.session(for: target) { reconcile(agent: target, transcript: session.transcript) }
        } catch { self.error = "Could not track delivery: \(error)" }
    }
    private func watch(_ agent: String) {
        guard watchers[agent] == nil, let session = model?.session(for: agent) else { return }
        watchers[agent] = session.$transcript.combineLatest(session.$presence, session.$dialog, session.$historyRevision).sink { [weak self, weak session] _, presence, _, _ in
            // Published values arrive before storage updates; defer until presence/transcript agree.
            guard presence != .working else { return }
            Task { @MainActor [weak self, weak session] in
                guard let session else { return }
                self?.reconcile(agent: agent, transcript: session.transcript)
            }
        }
    }
    private func reconcile(agent: String, transcript: [TranscriptItem]) {
        guard let store, let session = model?.session(for: agent) else { return }
        let idle = session.presence == .idle
        let interrupted: Bool
        switch session.presence {
        case .disconnected, .reconnecting, .failed: interrupted = true
        default: interrupted = false
        }
        guard idle || interrupted else { return }
        if idle && !session.verifiedIdleHistory { return }
        do {
            for request in try store.messages() where request.recipient == agent && [.dispatching, .waiting, .uncertain].contains(request.state) {
                // Initial observer callbacks can overlap the transport acknowledgement.
                // Let dispatch finish before interpreting an idle snapshot as interruption.
                guard !inFlightRequests.contains(request.id) else { continue }
                if idle, let item = ProjectChatStore.response(to: request, transcript: transcript) {
                    if try store.consumeSilentResponse(to: request, item: item) {
                        finishTracking(request.id)
                        continue
                    }
                    let reply = try store.reply(to: request, item: item)
                    // Restart recovery may record a reply, but never wakes agents or replays handoffs.
                    let wasLive = liveRequests.contains(request.id)
                    finishTracking(request.id)
                    if !wasLive, !ProjectChatStore.handoffDirectives(in: reply.text).isEmpty {
                        var recovered = request
                        recovered.state = .replied
                        recovered.failureReason = "Agent handoffs in this recovered reply were not sent after Tavern restarted. Send a new request if they are still needed."
                        try store.save(recovered)
                        error = recovered.failureReason
                    }
                    if wasLive,
                       let chat = try store.chats().first(where: { $0.id == request.chatID && $0.archived != true }) {
                        let idle = Set(chat.participants.filter { model?.session(for: $0)?.presence == .idle })
                        let result = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: allowed, availablePiIDs: idle)
                        if !result.notices.isEmpty { error = result.notices.joined(separator: " ") }
                        for handoff in result.requests {
                            if let target = handoff.recipient {
                                watch(target)
                                scheduleDrain(target)
                            }
                        }
                    }
                } else if idle, let failure = ProjectChatStore.failure(to: request, transcript: transcript) {
                    var failed = request
                    failed.state = .closed
                    failed.failureReason = failure
                    try store.save(failed)
                    finishTracking(request.id)
                } else {
                    // An acknowledgement can precede busy publication. Only a newer durable
                    // history read makes an idle/no-answer conclusion authoritative.
                    if idle, let sentAt = dispatchedHistoryRevisions[request.id], session.historyRevision <= sentAt { continue }
                    let reason = idle
                        ? "The agent is idle, but no final reply can be safely attributed to this request. Its history may be missing or a later private message may have changed the turn. Review the individual agent chat, then close tracking manually if appropriate."
                        : "The connection was interrupted before a final reply was verified. Review the individual agent chat before closing tracking or sending again."
                    if request.state != .uncertain || request.failureReason == nil {
                        var uncertain = request
                        uncertain.state = .uncertain
                        uncertain.failureReason = reason
                        try store.save(uncertain)
                        recordRequestError(reason, requestID: request.id)
                    }
                }
            }
            reload()
            if idle { scheduleDrain(agent) }
        } catch { self.error = "Could not save the agent reply: \(error)" }
    }
    /// Only a human can release an uncertain attempt after inspecting the individual transcript.
    func closeAttempt(_ message: ProjectChatMessage) {
        do {
            var closed = message; closed.state = .closed; closed.failureReason = nil
            try store?.save(closed); reload()
            finishTracking(message.id)
            if let agent = message.recipient { scheduleDrain(agent) }
        } catch { self.error = "Could not close the request: \(error)" }
    }
}

struct ProjectChatsView: View {
    @ObservedObject var chats: ProjectChatsModel
    @ObservedObject var model: AppModel
    @Binding var selected: String?
    @Binding var creating: Bool
    @State private var recipient = "__all__"
    @ObservedObject private var draftStore = MessageDraftStore.shared
    private var draftKey: String { "project:\(selected ?? ProjectChatStore.homeID):composer" }
    private var draft: String {
        get { draftStore.text(for: draftKey) }
        nonmutating set { draftStore.set(newValue, for: draftKey) }
    }
    @State private var sending = false
    @State private var closing: ProjectChatMessage?
    @State private var managingParticipants = false
    @State private var renaming = false
    @AppStorage("tavern.projectInspectorVisible") private var inspectorVisible = true
    @State private var inspectorTab: ProjectInspectorView.Tab = .pinned
    @FocusState private var composerFocused: Bool
    private static let allRecipients = "__all__"
    private var chat: ProjectChat? { chats.chats.first { $0.id == (selected ?? ProjectChatStore.homeID) && $0.archived != true } }
    private var agents: [RosterMember] { model.roster.piAgents.filter { $0.endpoint != nil } }
    private func name(_ id: String?) -> String { id.flatMap { model.roster.member(id: $0)?.name ?? $0 } ?? "You" }
    private func rows(_ chat: ProjectChat) -> [[ProjectChatMessage]] {
        var groups: [[ProjectChatMessage]] = []
        var roots: [String: Int] = [:]
        for message in chats.messages where message.chatID == chat.id {
            if message.author == nil, let root = message.rootRequestID {
                if let index = roots[root] { groups[index].append(message); continue }
                roots[root] = groups.count
            }
            groups.append([message])
        }
        return groups
    }
    var body: some View {
        HSplitView {
            conversation.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if inspectorVisible, let chat {
                ProjectInspectorView(chat: chat, chats: chats, model: model, tab: $inspectorTab,
                                     manageParticipants: { managingParticipants = true },
                                     close: { inspectorVisible = false })
            }
        }
    }
    private var conversation: some View {
        VStack(spacing: 0) {
            if let chat {
                header(chat)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(rows(chat), id: \.first!.id) { group in messageRow(group) }
                            Color.clear.frame(height: 1).id("project-bottom")
                        }
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: chats.messages.count) { _, _ in proxy.scrollTo("project-bottom") }
                    .onChange(of: selected) { _, _ in proxy.scrollTo("project-bottom") }
                }
                composer(chat)
            } else {
                ContentUnavailableView("Home", systemImage: "bubble.left.and.bubble.right", description: Text("Connect a Pi agent to start your main conversation."))
            }
        }
        .onChange(of: selected) { old, new in
            recipient = Self.allRecipients
        }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFocusComposer)) { _ in composerFocused = true }
        .sheet(isPresented: $creating) {
            ProjectCreateSheet(agents: agents) { title, participants in
                guard let id = chats.create(title: title, participants: participants, lead: nil) else { return false }
                selected = id; creating = false; return true
            }
        }
        .sheet(isPresented: $renaming) {
            if let chat {
                ProjectRenameSheet(chat: chat) { title in chats.rename(chat, title: title) }
            }
        }
        .sheet(isPresented: $managingParticipants) {
            if let chat {
                ProjectParticipantsSheet(chat: chat, agents: agents) { participants in
                    guard chats.setParticipants(chat, participants) else { return false }
                    if !recipient.isEmpty && recipient != Self.allRecipients && !participants.contains(recipient) { recipient = Self.allRecipients }
                    managingParticipants = false
                    return true
                }
            }
        }
        .confirmationDialog("Close tracking for this request?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("I checked the agent chat; close tracking") { if let message = closing { chats.closeAttempt(message) }; closing = nil }
        } message: { Text("This does not cancel the agent or prove completion. Check its individual chat first. Tavern will not resend this request.") }
    }
    private func header(_ chat: ProjectChat) -> some View {
        HStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Color.tavernAccent)
                VStack(alignment: .center, spacing: 5) {
                    Text(chat.title).tavernFont(.callout, weight: .semibold)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 5) {
                        ForEach(agents.filter { chat.participants.contains($0.id) }) { agent in
                            AvatarView(member: agent, size: 24, hoverCard: false)
                                .overlay(Circle().strokeBorder(agent.id == chat.lead ? Color.tavernAccent : .clear, lineWidth: 3))
                                .memberHoverCard(agent, role: agent.id == chat.lead ? "Thread lead" : "Participant")
                                .accessibilityLabel("\(agent.name)\(agent.id == chat.lead ? ", thread lead" : "")")
                        }
                    }
                }
                Menu {
                    if chat.id != ProjectChatStore.homeID {
                        Button("Rename thread…") { renaming = true }
                    }
                    Button("Manage participants…") { managingParticipants = true }
                    Divider()
                    Toggle("Allow agent handoffs", isOn: Binding(get: { chat.coordinationEnabled == true }, set: { chats.setCoordination(chat, $0) }))
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Project options")
                .help("Project conversation options")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.quaternary))
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Button { inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).padding(.trailing, 16)
                .accessibilityLabel(inspectorVisible ? "Hide thread details" : "Show thread details")
                .help("Pinned widgets, activity, links and thread details")
        }
        .padding(.vertical, 8)
    }
    private func messageRow(_ group: [ProjectChatMessage]) -> some View {
        let message = group[0]
        return VStack(alignment: message.author == nil ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 6) {
                if message.author == nil { Spacer() }
                if let author = message.author, let member = model.roster.member(id: author) {
                    AvatarView(member: member, size: 24, hoverCard: false)
                }
                Text(name(message.author)).tavernFont(.caption, weight: .semibold)
                if group.contains(where: { $0.recipient != nil }) {
                    Text("→ " + group.compactMap { $0.recipient }.map { name($0) }.joined(separator: ", "))
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
                Text(message.date, style: .time).tavernFont(.caption).foregroundStyle(.tertiary)
            }
            TranscriptRow(item: TranscriptItem(id: message.id, role: message.author == nil ? .user : .assistant,
                text: message.text, thinking: "", date: message.date))
            ForEach(group.filter { $0.recipient != nil }) { request in
                if let agent = request.recipient, let session = model.session(for: agent) {
                    ProjectRequestWidgets(request: request, session: session) {
                        inspectorVisible = true; inspectorTab = .pinned
                    }
                }
                HStack(spacing: 8) {
                    if message.author == nil { Spacer() }
                    if let agent = request.recipient, let session = model.session(for: agent),
                       [.dispatching, .waiting, .uncertain].contains(request.state) {
                        ProjectRequestActivity(session: session, name: name(agent), request: request)
                    } else {
                        Text("\(name(request.recipient)): \(stateLabel(request))")
                            .tavernFont(.caption).foregroundStyle(.secondary)
                    }
                    if request.state == .queued {
                        if let agent = request.recipient, let session = model.session(for: agent) {
                            ProjectQueueStatus(session: session, blocked: chats.messages.first {
                                $0.recipient == agent && [.dispatching, .waiting, .uncertain].contains($0.state)
                            }, chatTitle: { id in chats.chats.first { $0.id == id }?.title ?? "another thread" })
                        }
                        Button("Cancel") { chats.cancelQueued(request) }.buttonStyle(.plain)
                    }
                    if [.dispatching, .waiting, .uncertain].contains(request.state) {
                        Button("Open agent chat") {
                            NotificationCenter.default.post(name: .tavernOpenPage, object: Page.agent(id: request.recipient ?? "").storageKey)
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Open agent chat") { NotificationCenter.default.post(name: .tavernOpenPage, object: Page.agent(id: request.recipient ?? "").storageKey) }
                            Button("Close tracking…") { closing = request }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if let reason = request.failureReason, request.state == .uncertain || request.state == .replied {
                    Text(reason).tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func composer(_ chat: ProjectChat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(agents.filter { chat.participants.contains($0.id) }) { agent in
                if let session = model.session(for: agent.id) {
                    ProjectParticipantAttention(session: session, name: agent.name)
                }
            }
            if let error = chats.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    Button { chats.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                TextField(recipient == Self.allRecipients ? "Message everyone, or @mention" : "Message \(name(recipient.isEmpty ? chat.lead : recipient))", text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...8).focused($composerFocused)
                    .onSubmit { submit(chat) }.padding(.horizontal, 4)
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button { recipient = Self.allRecipients } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.2.fill")
                                    Text("All")
                                    if recipient == Self.allRecipients {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .frame(minHeight: 32).padding(8)
                                .background(recipient == Self.allRecipients ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Send to all participants")
                                .accessibilityValue(recipient == Self.allRecipients ? "Selected" : "Not selected")
                                .accessibilityAddTraits(recipient == Self.allRecipients ? [.isSelected] : [])
                                .help("Send once to every project participant")
                            ForEach(agents.filter { chat.participants.contains($0.id) }) { agent in
                                Button { recipient = recipient == agent.id ? Self.allRecipients : agent.id } label: {
                                    ProjectAgentChip(agent: agent, selected: recipient == Self.allRecipients || (recipient.isEmpty ? chat.lead : recipient) == agent.id, lead: chat.lead == agent.id)
                                }.buttonStyle(.plain)
                                .accessibilityLabel("Send to \(agent.name)\(chat.lead == agent.id ? ", lead" : "")")
                                .contextMenu { Button("Make lead") { chats.makeLead(chat, agent.id); recipient = Self.allRecipients }.disabled(chat.lead == agent.id) }
                            }
                        }
                    }
                    Button { managingParticipants = true } label: { Image(systemName: "person.badge.plus") }
                        .buttonStyle(.plain).help("Add or remove participants").accessibilityLabel("Manage participants")
                    Button { submit(chat) } label: {
                        Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30).foregroundStyle(.white).background(Color.tavernAccent, in: Circle())
                    }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (Return)").accessibilityLabel("Send message")
                }
            }
            .padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(composerFocused ? Color.tavernAccent.opacity(0.5) : Color.secondary.opacity(0.25)))
        }
        .frame(maxWidth: 760).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity)
    }
    private func submit(_ chat: ProjectChat) {
        guard !sending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        let submitted = draft
        let target = recipient.isEmpty ? nil : recipient
        Task {
            let sent = !ProjectChatStore.leadingMentions(in: submitted).isEmpty || target == Self.allRecipients || target == nil
                ? await chats.sendAddressed(chat: chat, text: submitted)
                : await chats.send(chat: chat, recipient: target, text: submitted)
            if sent {
                draftStore.clear("project:\(chat.id):composer", ifMatching: submitted)
            }
            sending = false
        }
    }
    private func stateLabel(_ request: ProjectChatMessage) -> String {
        if request.state == .closed, let failure = request.failureReason { return "Stopped: \(failure)" }
        if request.declinedResponse == true { return "Seen" }
        switch request.state { case .queued: return "Queued"
        case .dispatching: return "Sending"
        case .waiting: return "Waiting for reply"
        case .uncertain: return "Delivery uncertain; not retried"
        case .replied: return "Replied"
        case .closed: return request.prompt == nil ? "Cancelled before sending" : "Tracking closed" }
    }
}


/// Same session and consent controls as the individual chat, without navigating away.
private struct ProjectParticipantAttention: View {
    @ObservedObject var session: PiAgentSession
    let name: String
    var body: some View {
        if let dialog = session.dialog {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name) needs your input").tavernFont(.caption, weight: .semibold)
                DialogBanner(dialog: dialog) { answer in
                    Task { await session.answer(answer, expectedDialogID: dialog.id) }
                }
                .id(dialog.id)
            }
        }
    }
}

/// One observed, single-line status; never estimates progress or infers tool activity.
private struct ProjectRequestActivity: View {
    @ObservedObject var session: PiAgentSession
    let name: String
    let request: ProjectChatMessage
    private var status: String {
        if request.state == .uncertain { return "Delivery uncertain" }
        if session.dialog != nil { return "Needs your input" }
        if session.presence == .disconnected { return "Disconnected" }
        if case .failed = session.presence { return "Connection failed" }
        if session.presence == .connecting || session.presence == .reconnecting { return "Connecting" }
        if request.state == .dispatching { return "Sending" }
        if let tool = session.currentTool { return "Using \(tool)" }
        if !session.streamingText.isEmpty { return "Replying" }
        if session.isThinking { return "Thinking" }
        if session.presence == .working { return "Working" }
        return "Waiting for reply"
    }
    var body: some View {
        Text("\(name): \(status)")
            .tavernFont(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .accessibilityLabel("\(name): \(status)")
    }
}


extension Notification.Name {
    static let tavernNewProject = Notification.Name("tavern.newProject")
}

struct ProjectThreadSidebar: View {
    @ObservedObject var chats: ProjectChatsModel
    @Binding var selection: Page?
    @State private var removing: ProjectChat?
    @State private var renameTarget: ProjectChat?
    var body: some View {
        Section {
            ForEach(chats.chats.filter { $0.archived != true && $0.id != ProjectChatStore.homeID }) { chat in
                Button {
                    selection = .project(id: chat.id)
                } label: {
                    Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(Page.project(id: chat.id))
                .contextMenu {
                    Button("Rename…") { renameTarget = chat }
                    Button("Remove from sidebar…") { removing = chat }
                }
            }
            if chats.chats.contains(where: { $0.archived == true }) {
                Menu("Restore thread") {
                    ForEach(chats.chats.filter { $0.archived == true }) { chat in
                        Button(chat.title) { chats.archive(chat, false) }
                    }
                }
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                Button { NotificationCenter.default.post(name: .tavernNewProject, object: nil) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("New project thread").accessibilityLabel("New project thread")
            }
        }
        .sheet(item: $renameTarget) { chat in
            ProjectRenameSheet(chat: chat) { title in chats.rename(chat, title: title) }
        }
        .confirmationDialog("Remove this thread from the sidebar?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove from sidebar") {
                if let chat = removing {
                    chats.archive(chat, true)
                    if selection == .project(id: chat.id) { selection = .projects }
                }
                removing = nil
            }
        } message: { Text("Messages are kept. Restore it from Projects → Restore thread. This does not cancel any agent work.") }
    }
}


/// A separate presentation owns editing state so sidebar/page refreshes cannot reset the field.
private struct ProjectCreateSheet: View {
    let agents: [RosterMember]
    let create: (String, Set<String>) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var participants: Set<String> = []
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New project").font(.title2)
            TextField("Project name", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityLabel("Project name")
            Text("Choose at least two agents").font(.headline)
            HStack(spacing: 16) {
                ForEach(agents) { agent in
                    Button {
                        if participants.contains(agent.id) { participants.remove(agent.id) }
                        else { participants.insert(agent.id) }
                    } label: {
                        ProjectAgentChip(agent: agent, selected: participants.contains(agent.id),
                            lead: agents.first(where: { participants.contains($0.id) })?.id == agent.id)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(participants.contains(agent.id) ? "Remove" : "Add") \(agent.name)")
                }
            }
            Text("The first onboarded participant leads. You can change the lead from an agent's avatar later.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { _ = create(title, participants) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(participants.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 420)
        .onAppear {
            if let first = agents.first { participants.insert(first.id) }
            nameFocused = true
        }
    }
}

private struct ProjectAgentChip: View {
    let agent: RosterMember
    let selected: Bool
    let lead: Bool
    var body: some View {
        HStack(spacing: 8) {
            AvatarView(member: agent, size: 32, hoverCard: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                if lead { Text("Lead").font(.caption).foregroundStyle(.secondary) }
            }
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }.padding(8)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}

private struct ProjectParticipantsSheet: View {
    let chat: ProjectChat
    let agents: [RosterMember]
    let save: (Set<String>) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var participants: Set<String>
    init(chat: ProjectChat, agents: [RosterMember], save: @escaping (Set<String>) -> Bool) {
        self.chat = chat; self.agents = agents; self.save = save
        _participants = State(initialValue: Set(chat.participants))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Participants").font(.title2)
            Text(chat.title).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                ForEach(agents) { agent in
                    Button {
                        if participants.contains(agent.id) { participants.remove(agent.id) }
                        else { participants.insert(agent.id) }
                    } label: {
                        ProjectAgentChip(agent: agent, selected: participants.contains(agent.id), lead: chat.lead == agent.id)
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(participants.contains(agent.id) ? "Remove" : "Add") \(agent.name)")
                }
            }
            ForEach(chat.participants.filter { id in !agents.contains(where: { $0.id == id }) }, id: \.self) { id in
                Toggle("\(id) (unavailable)", isOn: Binding(get: { participants.contains(id) }, set: { if $0 { participants.insert(id) } else { participants.remove(id) } }))
            }
            Text("New participants receive recent project history when you message them. Removing someone keeps their messages and does not cancel work already running.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { _ = save(participants) }.keyboardShortcut(.defaultAction)
                    .disabled(participants.count < (chat.id == ProjectChatStore.homeID ? 1 : 2))
            }
        }.padding(24).frame(width: 480)
    }
}

private struct ProjectRenameSheet: View {
    let chat: ProjectChat
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var saveError = false
    @FocusState private var focused: Bool
    init(chat: ProjectChat, save: @escaping (String) -> Bool) {
        self.chat = chat; self.save = save
        _title = State(initialValue: chat.title)
    }
    private var valid: Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 120 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename thread").font(.title2)
            TextField("Thread name", text: $title).textFieldStyle(.roundedBorder)
                .focused($focused).accessibilityLabel("Thread name")
            if saveError { Text("Couldn't save the name. Please try again.").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if save(title) { dismiss() } else { saveError = true }
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 360).onAppear { focused = true }
    }
}

/// Explain the next step where the queued message lives, including cross-project blockers.
private struct ProjectQueueStatus: View {
    @ObservedObject var session: PiAgentSession
    let blocked: ProjectChatMessage?
    let chatTitle: (String) -> String
    private var reason: String {
        if session.dialog != nil { return "Needs your input before continuing" }
        if let blocked, blocked.state == .uncertain { return "Review earlier delivery in \(chatTitle(blocked.chatID))" }
        if session.presence == .disconnected { return "Waiting for connection" }
        if case .failed = session.presence { return "Connection failed" }
        if session.presence == .connecting || session.presence == .reconnecting { return "Reconnecting" }
        if let blocked { return "After earlier request in \(chatTitle(blocked.chatID))" }
        return session.presence == .working ? "After current turn" : "Ready to send"
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(reason).foregroundStyle(.secondary)
            if let blocked, blocked.state == .uncertain {
                Button("Review") { NotificationCenter.default.post(name: .tavernOpenPage, object: Page.project(id: blocked.chatID).storageKey) }
                    .buttonStyle(.plain)
            }
            if session.presence == .disconnected || { if case .failed = session.presence { return true }; return false }() {
                Button("Reconnect") { Task { await session.connect() } }.buttonStyle(.plain)
            }
        }.tavernFont(.caption)
    }
}
