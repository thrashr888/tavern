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

    /// Distinct open tickets that some party member is on.
    private var agentTicketCount: Int {
        Set(model.roster.members.flatMap { model.tasks(for: $0) }.filter { $0.state != nil }.map(\.identifier)).count
    }

    private var value: ProofOfValue { stats.value }

    private func isOnline(_ agent: RosterMember) -> Bool {
        guard let presence = model.session(for: agent.id)?.presence else { return false }
        return presence == .idle || presence == .working
    }

    private var onlineAgents: Int { model.roster.piAgents.filter(isOnline).count }
    private var offlineNames: String { model.roster.piAgents.filter { !isOnline($0) }.map(\.name).joined(separator: ", ") }

    /// Tasks sent from Tavern that have left Linear's open list.
    private var finishedTasks: Int {
        Set(model.roster.members.flatMap { model.tasks(for: $0) }.filter { $0.state == nil }.map(\.identifier)).count
    }

    /// The oldest mail ask still waiting (agents' dialogs carry no time).
    private var oldestAsk: Date? { model.mailAsks.map(\.lastDate).min() }

    /// Woke and quiet beats this week, from the agents' hosts that count them.
    private var heartbeats: (woke: Int, quiet: Int)? {
        let beats = model.roster.piAgents.compactMap { model.session(for: $0.id)?.config.heartbeat }
            .filter { $0.wokeThisWeek != nil }
        guard !beats.isEmpty else { return nil }
        return (beats.reduce(0) { $0 + ($1.wokeThisWeek ?? 0) }, beats.reduce(0) { $0 + ($1.quietThisWeek ?? 0) })
    }

    private var topSpender: String? {
        let today = Date()
        let top = model.roster.piAgents.map { ($0.name, value.spend(agent: $0.id, on: today)) }.max { $0.1 < $1.1 }
        guard let top, top.1 > 0 else { return nil }
        return "\(top.0) \(dollars(top.1))"
    }

    private var shippedSummary: String? {
        guard !value.shipped.isEmpty else { return nil }
        let kinds: [ProofOfValue.Shipped.Kind] = [.pullRequest, .draft, .edit, .file]
        return kinds.compactMap { kind in
            let count = value.shipped.filter { $0.kind == kind }.count
            return count > 0 ? "\(count) \(kind == .pullRequest ? "PR" : kind.rawValue.lowercased())\(count == 1 || kind == .pullRequest ? "" : "s")" : nil
        }.joined(separator: " · ")
    }

    private func dollars(_ amount: Double) -> String { amount.formatted(.currency(code: "USD")) }

    /// The last 7 days, oldest first.
    private func dailySeries(_ value: (Date) -> Double) -> [Double] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).reversed().map { value(today.addingTimeInterval(-Double($0) * 86_400)) }
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

                SetupBanner()

                if let mail = model.mail {
                    NeedsYouSection(mail: mail, selection: $selection)
                }

                // Proof of value: is the party working, and what needs you. Every tile opens
                // the page behind its number.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "Agents online", value: "\(onlineAgents)/\(model.roster.piAgents.count)", symbol: "person.3",
                             detail: offlineNames.isEmpty ? nil : "Down: \(offlineNames)") {
                        if let down = model.roster.piAgents.first(where: { !isOnline($0) }) { selection = .agent(id: down.id) }
                    }
                    StatTile(title: "Goals open · with agents", value: model.openIssues.isEmpty ? "–" : "\(model.openIssues.count) · \(agentTicketCount)",
                             symbol: "checklist", detail: finishedTasks > 0 ? "\(finishedTasks) finished by agents" : nil) { selection = .goals }
                    StatTile(title: "Agent turns · 7 days", value: "\(value.turnsThisWeek)", symbol: "bubble.left.and.bubble.right",
                             spark: dailySeries { day in Double(value.turnsDaily.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + $1.count }) }) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                    StatTile(title: "Approvals · 7 days", value: "\(value.approved + value.declined)", symbol: "hand.raised",
                             detail: "\(value.approved) allowed · \(value.declined) denied") {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                    StatTile(title: "Waiting on you", value: "\(model.attention.count)", symbol: "exclamationmark.bubble",
                             detail: oldestAsk.map { "oldest \($0.formatted(.relative(presentation: .numeric)))" }) {
                        if let waiting = model.roster.piAgents.first(where: { model.session(for: $0.id)?.dialog != nil }) { selection = .agent(id: waiting.id) }
                        else { selection = .mail(project: nil) }
                    }
                    StatTile(title: "Heartbeats · 7 days", value: heartbeats.map { "\($0.woke) woke" } ?? "\(value.heartbeatWakes) woke",
                             symbol: "waveform.path.ecg", detail: heartbeats.map { "\($0.quiet) quiet, no model turn" }) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                    StatTile(title: "Spend today", value: dollars(value.spend(on: Date())), symbol: "dollarsign.circle",
                             detail: topSpender.map { "most: \($0)" },
                             spark: dailySeries { value.spend(on: $0) }) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                    StatTile(title: "Shipped · 7 days", value: "\(value.shipped.count)", symbol: "shippingbox.and.arrow.backward",
                             detail: shippedSummary) {
                        if let agent = value.shipped.first?.agentID ?? model.roster.piAgents.first?.id { selection = .agent(id: agent) }
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    ActivityChart(title: "Agent turns · 14 days", counts: value.turnsDaily, roster: model.roster) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                    ActivityChart(title: "Spend · 14 days", spend: value.spendDaily, roster: model.roster) {
                        if let first = model.roster.piAgents.first { selection = .agent(id: first.id) }
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    section("Shipped · 7 days") {
                        if value.shipped.isEmpty { Text("Nothing shipped yet this week.").foregroundStyle(.secondary) }
                        ForEach(value.shipped.prefix(8)) { item in
                            Button { selection = .agent(id: item.agentID) } label: {
                                HStack(spacing: 8) {
                                    if let agent = model.roster.member(id: item.agentID) { AvatarView(member: agent, size: 20, hoverCard: false) }
                                    Text(item.kind.rawValue).tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                                    Text(item.title).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(item.date.formatted(.relative(presentation: .numeric))).tavernFont(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    section("Tools and cards · 7 days") {
                        if value.tools.isEmpty { Text("No tool calls yet.").foregroundStyle(.secondary) }
                        ForEach(value.tools.prefix(6)) { tool in
                            HStack {
                                Text(tool.name).lineLimit(1)
                                Spacer()
                                Text("\(tool.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    section("Mail threads handled · 7 days") {
                        if stats.handled.isEmpty { Text("No agent replies this week.").foregroundStyle(.secondary) }
                        ForEach(stats.handled, id: \.threadKey) { row in
                            Button {
                                model.focusedMailThread = row.threadID
                                selection = .mail(project: nil)
                            } label: {
                                HStack {
                                    Text(row.subject).lineLimit(1)
                                    Spacer()
                                    Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
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
    /// What the agents got done and what it cost.
    var value = ProofOfValue()
    /// Party mail threads an agent wrote in this week.
    var handled: [Busy] = []

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
        value = ProofOfValue(store: store, now: now)
        let agents = Set(roster.members.map(\.id))
        handled = threads
            .filter { $0.lastDate >= week && $0.messages.contains { $0.date >= week && ($0.author.map(agents.contains) ?? false) } }
            .sorted { $0.lastDate > $1.lastDate }
            .prefix(6)
            .map { Busy(threadKey: MailItem.threadKey($0.threadID), threadID: $0.threadID, subject: $0.subject,
                        count: $0.messages.filter { $0.date >= week }.count) }
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

/// "Found Ember on M3. Add?" for each pi-bundle agent discovery turned up, and on a first launch
/// (no roster.json yet) a pointer to Settings.
private struct SetupBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasRosterFile {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    Text(model.discovered.isEmpty
                         ? "This is an example party. Name yours and add its members in Settings."
                         : "This is an example party. Add the agents Tavern found, or set it up in Settings.")
                    Spacer()
                    Button("Open Settings") { openSettings() }.buttonStyle(PillButtonStyle())
                }
            }
            if let feed = model.mail {
                ProxyBannerRow(feed: feed)
            }
            ForEach(model.discovered) { agent in
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: agent.card.avatarColor ?? "#6b5b95")).frame(width: 26, height: 26)
                        .overlay(Text(String(agent.card.name.prefix(1))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                    Text("Found **\(agent.card.name)** on \(agent.machine).") + Text(agent.answering == false ? " Its host isn't answering yet." : "")
                    Spacer()
                    Button("Not Now") { model.dismiss(agent) }.buttonStyle(.borderless)
                    Button("Add") { Task { await model.add(agent) } }.buttonStyle(PillButtonStyle(selected: true))
                }
            }
        }
        .padding(quiet ? 0 : 14)
        .background(quiet ? Color.clear : Color.tavernAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .task { if model.discovered.isEmpty { await model.discoverAgents() } }
    }
}

extension SetupBanner {
    /// Nothing to set up: no example party, no found agents, no sign-in waiting.
    private var quiet: Bool {
        model.hasRosterFile && model.discovered.isEmpty && model.mail?.state != .signedOut
    }
}

/// "Sign in to Personal Agent Proxy for party mail and Linear", until it's done.
private struct ProxyBannerRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feed: MailFeed

    var body: some View {
        if feed.state == .signedOut || feed.state == .signingIn {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key").foregroundStyle(.tint)
                Text("Sign in to Personal Agent Proxy for \(model.roster.party) mail and Linear.")
                Spacer()
                Button(feed.state == .signingIn ? "Waiting…" : "Sign In") { Task { await model.signInToProxy() } }
                    .buttonStyle(PillButtonStyle(selected: true))
                    .disabled(feed.state == .signingIn)
            }
        }
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
    @EnvironmentObject private var model: AppModel
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
                        if model.roster.homeAgentID == member.id { HomeBadge() }
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
    struct Point: Hashable { var day: Date; var key: String; var value: Double }

    let title: String
    let counts: [Point]
    let roster: Roster
    var dollars = false
    let open: () -> Void

    init(title: String, counts: [DailyCount], roster: Roster, open: @escaping () -> Void) {
        self.title = title
        self.counts = counts.map { Point(day: $0.day, key: $0.key, value: Double($0.count)) }
        self.roster = roster
        self.open = open
    }

    init(title: String, spend: [ProofOfValue.DailySpend], roster: Roster, open: @escaping () -> Void) {
        self.title = title
        counts = spend.map { Point(day: $0.day, key: $0.key, value: $0.dollars) }
        self.roster = roster
        dollars = true
        self.open = open
    }

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
                        BarMark(x: .value("Day", row.day, unit: .day), y: .value(dollars ? "Spend" : "Count", row.value))
                            .foregroundStyle(by: .value("Member", name(row.key)))
                            .cornerRadius(2)
                    }
                    .chartForegroundStyleScale(domain: members.map(\.name), range: members.map { Color(hex: $0.avatarColor) })
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if dollars, let v = value.as(Double.self) { Text(v, format: .currency(code: "USD").precision(.fractionLength(0))) } else if let v = value.as(Double.self) { Text("\(Int(v))") } }
                        }
                    }
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
    /// A second line under the title, such as "oldest 3h" or "2 declined".
    var detail: String? = nil
    /// The last few days, oldest first, as a small line.
    var spark: [Double] = []
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
                if let detail { Text(detail).tavernFont(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                if spark.count > 1 {
                    Chart(Array(spark.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("Day", point.offset), y: .value("Value", point.element))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.tavernAccent)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 22)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
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
        .inspectorToggle($showInspector)
        .inspector(isPresented: $showInspector) {
            if let agent {
                AgentInspectorView(agent: agent)
                    .inspectorClose($showInspector)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 400)
                    .splitAutosave("inspector")
            }
        }
    }
}

/// The right panel's open button, in the window's top right corner while the panel is closed.
/// (The page's header pill opens it too; the open panel closes with its own X.)
private struct InspectorToggle: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if !isPresented {
                CornerButton(systemImage: "sidebar.right", help: "Show the info panel") { isPresented = true }
            }
        }
    }
}

/// The open panel's X, in its top right corner, on the same glass as the sidebar (macOS's
/// sidebars and inspectors are both glass panes), tinted in a party theme.
private struct InspectorClose: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
        .background {
            ZStack {
                PaneGlass()
                if let palette = Theme.current.palette { palette.sidebar.opacity(0.6) }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            CornerButton(systemImage: "xmark", help: "Hide the info panel") { isPresented = false }
        }
    }
}

/// The sidebar's material, behind the window, for the inspector pane.
private struct PaneGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A small icon button on the title bar's line, flush in the top right corner.
private struct CornerButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .padding(.top, 2)
        .padding(.trailing, 6)
        .ignoresSafeArea(edges: .top)
    }
}

extension View {
    func inspectorToggle(_ isPresented: Binding<Bool>) -> some View { modifier(InspectorToggle(isPresented: isPresented)) }
    func inspectorClose(_ isPresented: Binding<Bool>) -> some View { modifier(InspectorClose(isPresented: isPresented)) }
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
