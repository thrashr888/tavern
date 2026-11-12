import SwiftUI
import TavernCore

/// Project-scoped context. Never presents an agent's unrelated private transcript as group work.
struct ProjectInspectorView: View {
    enum Tab: String, CaseIterable { case pinned = "Pinned", activity = "Activity", links = "Links", about = "About" }
    let chat: ProjectChat
    @ObservedObject var chats: ProjectChatsModel
    @ObservedObject var model: AppModel
    @ObservedObject private var pins = PinnedCards.shared
    @Binding var tab: Tab
    var manageParticipants: () -> Void
    var close: () -> Void
    private var requests: [ProjectChatMessage] { chats.messages.filter { $0.chatID == chat.id && $0.recipient != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thread details").tavernFont(.headline, weight: .semibold)
                Spacer()
                Button(action: close) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.plain).help("Hide thread details").accessibilityLabel("Hide thread details")
            }.padding(16)
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { value in
                    Button { tab = value } label: {
                        Text(value.rawValue).tavernFont(.caption, weight: tab == value ? .semibold : nil)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(tab == value ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .pinned: pinned
                    case .activity: activity
                    case .links: links
                    case .about: about
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 290, idealWidth: 340, maxWidth: 480)
    }

    private var pinned: some View {
        let selected = pins.pins.filter { $0.projectID == chat.id }
        return VStack(alignment: .leading, spacing: 16) {
            if selected.isEmpty {
                Label("Keep useful widgets here", systemImage: "pin")
                    .tavernFont(.headline)
                Text("Choose Pin above a widget in this conversation, or right-click its header. Pin live follows new revisions when supported; snapshots keep the original result.")
                    .tavernFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(Set(selected.map(\.agentID))).sorted(), id: \.self) { agentID in
                Text(model.roster.member(id: agentID)?.name ?? agentID).tavernFont(.caption, weight: .semibold)
                if let session = model.session(for: agentID) {
                    PinnedSessionWidgets(session: session, selected: selected.filter { $0.agentID == agentID })
                } else {
                    ForEach(selected.filter { $0.agentID == agentID }) { pin in
                        UnavailablePinnedWidget(pin: pin, explanation: "The source agent is unavailable. Your pin is preserved.")
                    }
                }
            }
            if let error = pins.error { Text(error).foregroundStyle(.red).tavernFont(.caption) }
        }
    }

    private var activity: some View {
        let active = requests.filter { [.queued, .dispatching, .waiting, .uncertain].contains($0.state) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Now").tavernFont(.headline)
            if active.isEmpty { Text("No pending work in this thread.").foregroundStyle(.secondary) }
            ForEach(Array(Set(chat.participants + active.compactMap(\.recipient))).sorted(), id: \.self) { id in
                if let session = model.session(for: id) {
                    ProjectSidebarAgentActivity(session: session, name: model.roster.member(id: id)?.name ?? id,
                                                requests: active.filter { $0.recipient == id })
                } else if active.contains(where: { $0.recipient == id }) {
                    Label("\(agentName(id)): source agent unavailable", systemImage: "exclamationmark.triangle")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                    Text("Pending request tracking is preserved. Open the original request in the conversation to review it.")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Recent history") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(requests.filter { ![.queued, .dispatching, .waiting, .uncertain].contains($0.state) }.suffix(10).reversed())) { request in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agentName(request.recipient))
                                .tavernFont(.caption, weight: .semibold)
                            Text(historyStatus(request))
                                .tavernFont(.caption).foregroundStyle(.secondary)
                            Text(request.date, style: .time).tavernFont(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }

    private func agentName(_ id: String?) -> String {
        guard let id else { return "Agent" }
        return model.roster.member(id: id)?.name ?? id
    }
    private func historyStatus(_ request: ProjectChatMessage) -> String {
        if let failure = request.failureReason { return "Stopped: \(failure)" }
        if request.declinedResponse == true { return "Seen" }
        if request.state == .replied { return "Replied" }
        return request.prompt == nil ? "Cancelled before sending" : "Tracking closed"
    }

    private var links: some View {
        let messages = chats.messages.filter { $0.chatID == chat.id }
        let transcript = messages.map { TranscriptItem(id: $0.id, role: $0.author == nil ? .user : .assistant, text: $0.text, date: $0.date) }
        let links = LinksSection.links(in: transcript)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Shared links").tavernFont(.headline)
            if links.isEmpty { Text("Links shared in this thread appear here.").foregroundStyle(.secondary) }
            ForEach(links, id: \.url) { link in
                Link(destination: link.url) {
                    Label(link.url.host ?? link.url.absoluteString, systemImage: "link")
                        .lineLimit(2)
                }
                .help(link.url.absoluteString)
                Text(link.url.absoluteString).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chat.title).tavernFont(.headline)
            Text("Participants").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            ForEach(chat.participants, id: \.self) { id in
                HStack {
                    Text(model.roster.member(id: id)?.name ?? id)
                    if id == chat.lead { Text("Lead").tavernFont(.caption).foregroundStyle(.secondary) }
                }
            }
            Button("Manage participants…", action: manageParticipants)
            Divider()
            Text(chat.coordinationEnabled == true ? "Agent handoffs enabled" : "Agent handoffs disabled")
                .tavernFont(.callout, weight: .medium)
            Text("All invites relevant replies from the participants. @mention a participant to address them directly. Agent handoffs use explicit requests and queue while a participant is busy.")
                .tavernFont(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProjectSidebarAgentActivity: View {
    @ObservedObject var session: PiAgentSession
    let name: String
    let requests: [ProjectChatMessage]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Approval state belongs to the durable agent; do not imply it came from this project.
            if session.dialog != nil {
                Text("\(name) needs attention (agent-wide)").tavernFont(.caption, weight: .semibold)
                InspectorPendingApproval(session: session)
            }
            ForEach(requests) { request in
                HStack(alignment: .top) {
                    Text(name).tavernFont(.caption, weight: .semibold)
                    Spacer()
                    Text(request.state == .queued ? "Queued" : request.state == .uncertain ? "Check delivery" : "In progress")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
                Button("Open agent chat") {
                    NotificationCenter.default.post(name: .tavernOpenPage, object: Page.agent(id: session.agentID).storageKey)
                }.buttonStyle(.borderless).tavernFont(.caption)
            }
        }
    }
}

/// Only cards from this request's exact prompt are visible here, including while streaming.
struct ProjectRequestWidgets: View {
    let request: ProjectChatMessage
    @ObservedObject var session: PiAgentSession
    let onPin: () -> Void
    var body: some View {
        ForEach(ProjectChatStore.cardRows(for: [request], agentID: session.agentID, transcript: session.transcript)) { row in
            if case .card(_, let card) = row {
                PinnableCardView(card: card, rowID: row.id, projectID: request.chatID, onPin: onPin, session: session)
            }
        }
    }
}
