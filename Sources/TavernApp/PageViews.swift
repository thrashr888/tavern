import AppKit
import Charts
import SwiftUI
import TavernCore

/// The party at a glance (plan 4 and step 10): portrait, stat tiles, mail per member, Pi agents
/// and the busiest threads, all counted from the local event log.
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: Page?
    private var stats: DashboardStats { model.dashboardStats ?? DashboardStats() }
    private var containersRunning: Int? { model.containersRunning }

    /// Distinct open tickets that some party member is on.
    private var agentTicketCount: Int {
        Set(model.roster.members.flatMap { model.tasks(for: $0) }.filter { $0.state != nil }.map(\.identifier)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The party, edge to edge, running under the (title-less) toolbar.
                PortraitView()

                VStack(alignment: .leading, spacing: 24) {
                if let error = model.storeError {
                    Label("Event store unavailable: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let mail = model.mail {
                    NeedsYouSection(mail: mail, selection: $selection)
                }

                // Every tile opens the page behind its number.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "Open goals", value: model.openIssues.isEmpty ? "–" : "\(model.openIssues.count)",
                             symbol: "checklist") { selection = .goals }
                    // Open tickets an agent is on: sent from Tavern, or labeled agent:<id> in Linear.
                    StatTile(title: "With agents", value: model.openIssues.isEmpty ? "–" : "\(agentTicketCount)",
                             symbol: "paperplane") { selection = .goals }
                    StatTile(title: "Containers up", value: containersRunning.map(String.init) ?? "–",
                             symbol: "shippingbox") { selection = .services }
                    StatTile(title: "\(model.roster.party) threads", value: "\(stats.threadCount)", symbol: "tray.full") { selection = .mail(project: nil) }
                    StatTile(title: "Mail this week", value: "\(stats.mailThisWeek)", symbol: "envelope") { selection = .mail(project: nil) }
                    StatTile(title: "Pi messages this week", value: "\(stats.piThisWeek)", symbol: "bubble.left.and.bubble.right") {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    ActivityChart(title: "\(model.roster.party) mail · 14 days", counts: stats.mailDaily, roster: model.roster) {
                        selection = .mail(project: nil)
                    }
                    ActivityChart(title: "Pi messages · 14 days", counts: stats.piDaily, roster: model.roster) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    section("Mail per member · 7 days") {
                        if stats.mailByMember.isEmpty {
                            Text("No \(model.roster.party) mail stored yet.").foregroundStyle(.secondary)
                        }
                        ForEach(stats.mailByMember) { row in
                            let member = model.roster.member(id: row.id)
                            Button {
                                selection = member?.kind == .pi ? .agent(id: row.id) : .mail(project: nil)
                            } label: {
                                MemberBar(member: member, name: row.id, count: row.count,
                                          maximum: stats.mailByMember.first?.count ?? 1)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    section("Busiest threads · 7 days") {
                        if stats.busiest.isEmpty {
                            Text("Nothing yet.").foregroundStyle(.secondary)
                        }
                        ForEach(stats.busiest, id: \.threadKey) { row in
                            Button {
                                model.focusedMailThread = row.threadID
                                selection = .mail(project: nil)
                            } label: {
                                HStack {
                                    Text(row.subject).lineLimit(1)
                                    Spacer()
                                    Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // One card per member: who they are, whether they're around, what they're on.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Party").tavernFont(.headline, weight: .semibold)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                        ForEach(model.roster.members) { member in
                            PartyCard(member: member, session: model.session(for: member.id),
                                      lastSeen: member.kind == .pi ? stats.lastPiActivity[member.id] : model.lastSeen[member.id],
                                      task: model.tasks(for: member).first { $0.state != nil }) {
                                selection = .forMember(member)
                            }
                        }
                    }
                }
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
        .hidingWindowTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { _ = try? await model.loadOpenIssues() }
        .task {
            while !Task.isCancelled {
                await model.refreshContainers(maxAge: 30)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            while !Task.isCancelled {
                model.dashboardStats = DashboardStats(store: model.store, mail: model.mail, roster: model.roster)
                // Mail loads a moment after launch; check again soon until it has.
                try? await Task.sleep(for: .seconds(stats.threadCount == 0 ? 3 : 30))
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).tavernFont(.headline)
            content()
        }
        .tavernFont(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Counts from the event log. Recomputed every 30 seconds while the Dashboard is open.
struct DashboardStats {
    struct Busy { var threadKey: String; var threadID: String; var subject: String; var count: Int }

    var storedEvents = 0
    var threadCount = 0
    var mailThisWeek = 0
    var piThisWeek = 0
    struct MemberCount: Identifiable { var id: String; var count: Int }
    var mailByMember: [MemberCount] = []
    var busiest: [Busy] = []
    var lastPiActivity: [String: Date] = [:]
    /// Per day and member (mail by author, Pi by agent), for the charts.
    var mailDaily: [DailyCount] = []
    var piDaily: [DailyCount] = []

    init() {}

    @MainActor
    init(store: EventStore?, mail: MailFeed?, roster: Roster, now: Date = Date()) {
        guard let store else { return }
        let week = now.addingTimeInterval(-7 * 86_400)
        storedEvents = (try? store.eventCount()) ?? 0
        let byAuthor = (try? store.countsByAuthor(source: EventSource.gmail, since: week)) ?? [:]
        mailByMember = byAuthor.map { MemberCount(id: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        mailThisWeek = ((try? store.countsByThread(source: EventSource.gmail, since: week)) ?? [:]).values.reduce(0, +)
        piThisWeek = ((try? store.countsByThread(source: EventSource.pi, since: week)) ?? [:]).values.reduce(0, +)
        let threads = mail?.threads ?? []
        threadCount = threads.count
        let subjects = Dictionary(threads.map { (MailItem.threadKey($0.threadID), $0) }, uniquingKeysWith: { a, _ in a })
        busiest = ((try? store.countsByThread(source: EventSource.gmail, since: week)) ?? [:])
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { pair in
                let thread = subjects[pair.key]
                return Busy(threadKey: pair.key, threadID: thread?.threadID ?? String(pair.key.split(separator: ":").last ?? ""),
                            subject: thread?.subject ?? "Thread", count: pair.value)
            }
        let fortnight = Calendar.current.startOfDay(for: now.addingTimeInterval(-13 * 86_400))
        mailDaily = ((try? store.dailyCounts(source: EventSource.gmail, since: fortnight)) ?? []).filter { !$0.key.isEmpty }
        piDaily = ((try? store.dailyCounts(source: EventSource.pi, byThread: true, since: fortnight)) ?? []).map {
            DailyCount(day: $0.day, key: $0.key.replacingOccurrences(of: "pi:", with: ""), count: $0.count)
        }
        for agent in roster.piAgents {
            lastPiActivity[agent.id] = (try? store.events(threadKey: PiEntries.threadKey(agentID: agent.id)))?.last?.sourceTS
        }
    }
}

/// Everything waiting on the owner, first: Pi agents blocked on a dialog, and party mail whose
/// latest message says "Needs from <owner>: …" (the party's convention) in the last three days.
private struct NeedsYouSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var mail: MailFeed
    @Binding var selection: Page?

    var body: some View {
        let asks = model.mailAsks.prefix(6)
        let unanswered = model.unansweredIMessages
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs you").tavernFont(.headline, weight: .semibold)
            VStack(spacing: 0) {
                ForEach(model.roster.piAgents) { agent in
                    if let session = model.session(for: agent.id) {
                        WaitingRow(agent: agent, session: session) { selection = .agent(id: agent.id) }
                    }
                }
                ForEach(model.roster.members) { member in
                    ForEach(model.openIssues.isEmpty ? [] : model.tasks(for: member).filter(\.isNewlyFinished)) { task in
                        HStack(spacing: 0) {
                            Button {
                                model.focusedGoal = task.identifier
                                NotificationCenter.default.post(name: .tavernOpenGoals, object: nil)
                            } label: {
                                NeedsRow(member: member, title: "\(member.name) finished \(task.identifier)",
                                         detail: "\(task.title) · closed in Linear", symbol: "checkmark.seal")
                            }
                            .buttonStyle(.plain)
                            Button("Clear") { model.acknowledgeTask(task.identifier) }
                                .buttonStyle(PillButtonStyle())
                                .padding(.trailing, 12)
                        }
                    }
                }
                ForEach(unanswered) { item in
                    Button { selection = .member(id: item.member.id) } label: {
                        NeedsRow(member: item.member, title: "\(item.member.name) is waiting on your reply",
                                 detail: "iMessage · \(item.message.text.prefix(90)) · \(item.message.date.formatted(.relative(presentation: .named)))",
                                 symbol: "message")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(asks)) { thread in
                    let author = thread.messages.last?.author.flatMap { model.roster.member(id: $0) }
                    Button {
                        model.focusedMailThread = thread.threadID
                        selection = .mail(project: nil)
                    } label: {
                        NeedsRow(member: author, title: thread.ask(of: model.roster.owner) ?? thread.subject,
                                 detail: "\(author?.name ?? "Mail") · \(thread.subject) · \(thread.lastDate.formatted(.relative(presentation: .named)))")
                    }
                    .buttonStyle(.plain)
                }
                if asks.isEmpty && unanswered.isEmpty && !needsFromAgents {
                    Label("Nothing is waiting on you.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension NeedsYouSection {
    /// Anything from the agents themselves: a dialog, a failed connection or turn, or finished work.
    var needsFromAgents: Bool {
        model.roster.piAgents.contains { agent in
            guard let session = model.session(for: agent.id) else { return false }
            if session.dialog != nil || session.lastError != nil { return true }
            if case .failed = session.presence { return true }
            return false
        } || (!model.openIssues.isEmpty && model.roster.members.contains { !model.tasks(for: $0).filter(\.isNewlyFinished).isEmpty })
    }
}

private struct WaitingRow: View {
    let agent: RosterMember
    @ObservedObject var session: PiAgentSession
    let open: () -> Void

    var body: some View {
        if let dialog = session.dialog {
            Button(action: open) {
                NeedsRow(member: agent, title: dialog.title, detail: "\(agent.name) is waiting on you")
            }
            .buttonStyle(.plain)
        } else if case .failed(let reason) = session.presence {
            Button(action: open) {
                NeedsRow(member: agent, title: "\(agent.name) can't connect", detail: reason, symbol: "bolt.horizontal.circle")
            }
            .buttonStyle(.plain)
        } else if let error = session.lastError {
            Button(action: open) {
                NeedsRow(member: agent, title: ModelError.parse(error).title, detail: "\(agent.name) · \(ModelError.parse(error).message)",
                         symbol: "exclamationmark.triangle")
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NeedsRow: View {
    let member: RosterMember?
    let title: String
    let detail: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 12) {
            if let member { AvatarView(member: member, size: 32) } else {
                Image(systemName: "envelope").frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.orange) }
                    Text(title).tavernFont(.callout, weight: .semibold).lineLimit(2)
                }
                Text(detail).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The party portrait, `portrait.png` in Application Support; nothing when there isn't one.
/// It appears only on the Dashboard (the user: the image is global).
private struct PortraitView: View {
    var body: some View {
        if let image = PartyArt.portrait {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    // Soften the edge into the page.
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.9)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
        }
    }
}

private struct PartyCard: View {
    let member: RosterMember
    let session: PiAgentSession?
    let lastSeen: Date?
    let task: AgentTask?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(member: member, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(member.name).tavernFont(.callout, weight: .semibold)
                        if let session { PresenceDot(session: session) }
                    }
                    Text(subtitle).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(task.map { "\($0.identifier) · \($0.title)" } ?? "No task")
                        .tavernFont(.caption)
                        .foregroundStyle(task == nil ? .tertiary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let model = session?.config.model?.shortName
        let seen = lastSeen.map { (member.kind == .pi ? "active " : "mail ") + $0.formatted(.relative(presentation: .named)) }
        return [member.partyClass, member.host, model, seen].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Green while working, orange when waiting on the user, red when it can't connect.
private struct PresenceDot: View {
    @ObservedObject var session: PiAgentSession

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        if session.dialog != nil { return .orange }
        switch session.presence {
        case .working: return .green
        case .idle: return .secondary
        case .failed: return .red
        default: return .yellow
        }
    }
}

/// Bars per day, stacked by member in their avatar colors. Clicking opens the related page.
private struct ActivityChart: View {
    let title: String
    let counts: [DailyCount]
    let roster: Roster
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).tavernFont(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if counts.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary).frame(height: 140)
                } else {
                    Chart(counts, id: \.self) { row in
                        BarMark(x: .value("Day", row.day, unit: .day), y: .value("Count", row.count))
                            .foregroundStyle(by: .value("Member", name(row.key)))
                            .cornerRadius(2)
                    }
                    .chartForegroundStyleScale(domain: members.map(\.name), range: members.map { Color(hex: $0.avatarColor) })
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 160)
                }
            }
            .tavernFont(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var members: [RosterMember] {
        let keys = Set(counts.map(\.key))
        return roster.members.filter { keys.contains($0.id) }
    }

    private func name(_ key: String) -> String { roster.member(id: key)?.name ?? key }
}

private struct MemberBar: View {
    let member: RosterMember?
    let name: String
    let count: Int
    let maximum: Int

    var body: some View {
        HStack(spacing: 8) {
            if let member { AvatarView(member: member, size: 26) }
            Text(member?.name ?? name).frame(width: 70, alignment: .leading)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: member?.avatarColor ?? "#888888"))
                    .frame(width: max(4, proxy.size.width * CGFloat(count) / CGFloat(max(maximum, 1))))
            }
            .frame(height: 10)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
        }
    }
}

private func lastText(_ date: Date?) -> String {
    date?.formatted(.relative(presentation: .named)) ?? "–"
}

@MainActor
private func nameButton(_ agent: RosterMember, _ open: @escaping () -> Void) -> AnyView {
    AnyView(Button(action: open) {
        HStack(spacing: 6) { AvatarView(member: agent, size: 26); Text(agent.name) }
    }
    .buttonStyle(.plain))
}
/// A number that opens the page behind it. Every tile is the same height.
struct StatTile: View {
    let title: String
    let value: String
    var symbol: String?
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(value).tavernFont(.title, weight: .semibold).monospacedDigit()
                    Spacer()
                    if let symbol { Image(systemName: symbol).foregroundStyle(.tertiary) }
                }
                Text(title).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct AgentThreadView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("tavern.inspector") private var showInspector = true
    let agentID: String

    var body: some View {
        let agent = model.roster.member(id: agentID)
        Group {
            if let session = model.session(for: agentID) {
                PiThreadView(session: session, agent: agent)
            } else {
                VStack(spacing: 12) {
                    if let agent { AvatarView(member: agent, size: 96) }
                    Text(agent?.name ?? agentID).tavernFont(.title2, weight: .semibold)
                    Text("\(agent?.name ?? agentID) has no Pi connection yet. It connects once a durable host runs on \(agent?.host ?? "its machine") and its endpoint is in the roster.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The header pill already names the agent; the window title would repeat it.
        .navigationTitle(agent?.name ?? agentID)
        .hidingWindowTitle()
        .focusedSceneValue(\.currentAgent, model.session(for: agentID))
        .onReceive(NotificationCenter.default.publisher(for: .tavernToggleInspector)) { _ in showInspector.toggle() }
        .inspector(isPresented: $showInspector) {
            if let agent {
                AgentInspectorView(agent: agent)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 400)
            }
        }
        .toolbar {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }
}

extension View {
    /// No "Tavern" in the toolbar: the Dashboard's portrait is the header.
    @ViewBuilder func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbar(removing: .title)
        } else {
            self.navigationTitle("")
        }
    }
}
