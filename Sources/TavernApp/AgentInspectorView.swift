import SwiftUI
import TavernCore

/// Right inspector for an agent, Muse-style (plan 3d): large avatar and status, then the tabs
/// Activity, Approvals, Schedule and Identity, then the Tailscale machine and the Pi connection.
struct AgentInspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case activity = "Activity", links = "Links", services = "Services", about = "About"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    // AppStorage, not SceneStorage: SceneStorage inside the inspector column stored clicks without redrawing.
    @AppStorage("tavern.inspectorTab") private var tab: Tab = .activity
    let agent: RosterMember

    var body: some View {
        VStack(spacing: 0) {
            // The header and tabs stay put; only the tab content scrolls. With the tabs inside the
            // ScrollView, switching to a shorter tab left clicks landing ~40pt off the drawn controls.
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 8) {
                    AvatarView(member: agent, size: 140)
                    Text(agent.name).tavernFont(.title2, weight: .semibold)
                    let subtitle = [agent.partyClass, agent.host].compactMap { $0 }.joined(separator: " · ")
                    if !subtitle.isEmpty {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    if model.roster.homeAgentID == agent.id {
                        Label("Home · this Mac", systemImage: "house.fill")
                            .tavernFont(.caption, weight: .medium)
                            .foregroundStyle(Color.tavernAccent)
                            .help("This agent can set up Tavern with Tavern's own tools; each change asks you first.")
                    }
                    if let session = model.session(for: agent.id) {
                        StatusLine(session: session)
                    }
                }
                .frame(maxWidth: .infinity)

                TabBar(selection: $tab)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .activity:
                        // What the agent did, then what it asked the user. Waiting dialogs also show in the thread.
                        AgentTasksSection(agent: agent)
                        AgentSpellCasts(member: agent, book: model.spellbook)
                        if let session = model.session(for: agent.id) {
                            ActivitySection(session: session)
                            if let store = model.store {
                                ApprovalsSection(session: session, store: store)
                            }
                        } else {
                            placeholder("No activity until \(agent.name) is connected.")
                        }
                    case .links:
                        if let session = model.session(for: agent.id) {
                            LinksSection(session: session, agentName: agent.name)
                        } else {
                            placeholder("No links until \(agent.name) is connected.")
                        }
                    case .services:
                        if let host = DockerHost.hosts(for: model.roster).first(where: { $0.id == agent.tailscaleName }) {
                            AgentServices(host: host)
                        } else {
                            placeholder("No machine is known for \(agent.name).")
                        }
                    case .about:
                        IdentitySection(agent: agent, projects: model.roster.mailProjects,
                                        session: model.session(for: agent.id))
                        if let session = model.session(for: agent.id) { MachineSection(session: session) }
                        AgentSpellsSection(member: agent, book: model.spellbook)
                        InfoCard(title: "Schedule") {
                            if let heartbeat = model.session(for: agent.id)?.config.heartbeat {
                                InfoRow(label: "Heartbeat", value: heartbeat.summary)
                                if let last = heartbeat.last {
                                    InfoRow(label: "Last beat", value: last.formatted(.relative(presentation: .named)))
                                }
                            } else if agent.kind == .pi {
                                InfoRow(label: "Heartbeat", value: "None (add HEARTBEAT.md to the agent's folder)")
                            }
                            if let schedule = agent.schedule { InfoRow(label: "Also", value: schedule) }
                            if agent.mailEvents == true { InfoRow(label: "Events", value: "New \(model.roster.party) mail for \(agent.name)") }
                            if agent.kind != .pi && agent.schedule == nil { InfoRow(label: "Runs", value: "When asked") }
                        }
                        TailscaleSection(agent: agent, status: model.tailscale, error: model.tailscaleError)
                        InfoCard(title: "Pi connection") {
                            InfoRow(label: "Endpoint", value: agent.endpoint?.summary ?? "Not configured", monospaced: agent.endpoint != nil)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(agent.id)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).tavernFont(.callout).foregroundStyle(.secondary)
    }
}

/// The inspector's tabs as plain buttons. A segmented Picker here missed clicks on its first
/// segment, and at narrow inspector widths it overflowed the column; these share the width.
private struct TabBar: View {
    @Binding var selection: AgentInspectorView.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentInspectorView.Tab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.rawValue)
                        .tavernFont(.caption, weight: selection == tab ? .semibold : nil)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == tab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Issues sent to this agent from Goals, plus open issues labelled `agent:<name>` in Linear.
struct AgentTasksSection: View {
    let agent: RosterMember
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let tasks = model.tasks(for: agent)
        VStack(alignment: .leading, spacing: 8) {
            Text("Tasks").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("None yet. Send one from Goals, or label an issue agent:\(agent.id) in Linear.")
                    .tavernFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(tasks) { task in
                Button {
                    model.focusedGoal = task.identifier
                    NotificationCenter.default.post(name: .tavernOpenGoals, object: nil)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(task.state == nil ? Color.green : Color.blue).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).tavernFont(.callout, weight: .medium).lineLimit(2)
                            Text([task.identifier, task.state ?? "Closed", task.fromLabel ? "label" : task.sentAt.map { "sent \($0.formatted(.relative(presentation: .named)))" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .tavernFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task { _ = try? await model.loadOpenIssues() }
    }
}

/// Docker containers on this agent's machine, refreshed every 30 seconds while shown.
private struct AgentServices: View {
    let host: DockerHost
    @EnvironmentObject private var model: AppModel
    private var result: Result<[DockerContainer], DockerError>? { model.containerResults[host.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Docker on \(host.name)").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            switch result {
            case nil:
                ProgressView().controlSize(.small)
            case .failure(let error):
                Text(error.description).tavernFont(.callout).foregroundStyle(.orange)
            case .success(let containers) where containers.isEmpty:
                Text("No containers.").tavernFont(.callout).foregroundStyle(.secondary)
            case .success(let containers):
                ForEach(containers) { container in
                    Button {
                        model.focusedService = "\(host.id)/\(container.id)"
                        NotificationCenter.default.post(name: .tavernOpenPage, object: Page.services.storageKey)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(container.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(container.name).tavernFont(.callout, weight: .medium)
                                Text(container.status).tavernFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).imageScale(.small)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(container.name) in Services")
                }
            }
        }
        .task(id: host.id) {
            while !Task.isCancelled {
                await model.refreshContainers(maxAge: 25)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// Presence under the avatar, loud when the agent is waiting on the user.
private struct StatusLine: View {
    @ObservedObject var session: PiAgentSession

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(session.dialog != nil ? "Waiting on you" : session.presence.label.capitalized)
        }
        .tavernFont(.callout)
        .foregroundStyle(session.dialog != nil ? Color.orange : Color.secondary)
    }

    private var color: Color {
        if session.dialog != nil { return .orange }
        switch session.presence {
        case .working: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        default: return .gray
        }
    }
}

/// Dialogs the user answered in Tavern, newest first, and the one waiting now.
private struct ApprovalsSection: View {
    @ObservedObject var session: PiAgentSession
    let store: EventStore

    var body: some View {
        let entries = ApprovalLog.entries(agentID: session.agentID, store: store)
        VStack(alignment: .leading, spacing: 8) {
            Text("Approvals").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if let dialog = session.dialog {
                Label("Waiting: \(dialog.title)", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            if entries.isEmpty && session.dialog == nil {
                Text("Nothing has asked for approval yet.").foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(20)) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).lineLimit(2)
                    Text("\(entry.answer) · \(entry.date.formatted(.relative(presentation: .named)))")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tavernFont(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(session.approvalsVersion)
    }
}

/// Tavern's roster card for the agent (no protocol supplies identity yet), plus its model.
private struct IdentitySection: View {
    let agent: RosterMember
    let projects: [MailProject]
    let session: PiAgentSession?

    var body: some View {
        InfoCard(title: "Identity") {
            InfoRow(label: "Class", value: agent.partyClass ?? "–")
            if let animal = agent.animal { InfoRow(label: "Animal", value: animal) }
            InfoRow(label: "Kind", value: agent.kind == .pi ? "Pi agent" : "Hosted, mail only")
            if let model = session?.config.model { InfoRow(label: "Model", value: model.shortName) }
            if let usage = session?.config.usage { InfoRow(label: "Spent", value: usage.summary) }
            if let names = projectNames { InfoRow(label: "Projects", value: names) }
            if !agent.skills.isEmpty { InfoRow(label: "Skills", value: agent.skills.joined(separator: ", ")) }
            if let summary = agent.summary { InfoRow(label: "About", value: summary) }
        }
    }

    private var projectNames: String? {
        guard let ids = agent.projects, !ids.isEmpty else { return nil }
        return ids.map { id in projects.first { $0.id == id }?.label ?? id }.joined(separator: ", ")
    }
}

/// What the agent's machine offers, as its host reports it: MCP servers, containers, CLIs.
private struct MachineSection: View {
    @ObservedObject var session: PiAgentSession

    var body: some View {
        if let caps = session.config.capabilities {
            VStack(alignment: .leading, spacing: 10) {
                Text("Machine").tavernFont(.headline, weight: .semibold)
                group("MCP servers", caps.mcp.map { $0.tools > 0 ? "\($0.name) · \($0.tools)" : $0.name }, icon: "puzzlepiece.extension")
                if let docker = caps.docker {
                    group("Docker", docker, icon: "shippingbox", empty: "No containers running")
                }
                group("Tools", caps.clis, icon: "terminal")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.8)))
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [String], icon: String, empty: String? = nil) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                if items.isEmpty, let empty {
                    Text(empty).tavernFont(.caption).foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(items, id: \.self) { item in
                            Text(item)
                                .tavernFont(.caption, weight: .medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

/// The latest turn's steps (live while working), like an Activity panel.
private struct ActivitySection: View {
    @ObservedObject var session: PiAgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if let work = session.liveWork ?? latestWork {
                WorkSummary(work: work).tavernFont(.callout, weight: .semibold)
                if let started = work.started {
                    Text(started.formatted(date: .abbreviated, time: .shortened))
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
                StepList(steps: work.steps)
            } else {
                Text("No tool runs yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var latestWork: PiWork? {
        for row in session.rows.reversed() {
            if case .work(let work) = row { return work }
        }
        return nil
    }
}

private struct TailscaleSection: View {
    let agent: RosterMember
    let status: TailscaleStatus?
    let error: String?

    var body: some View {
        InfoCard(title: "Tailscale") {
            if let status {
                if !status.isRunning {
                    note("Tailscale on this Mac is \(status.backendState.lowercased()).")
                } else if let node = status.node(for: agent) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Circle().fill(node.online ? Color.green : Color.gray).frame(width: 8, height: 8)
                            Text(statusText(node))
                        }
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .tavernFont(.callout)
                    InfoRow(label: "Machine", value: node.isSelf ? "\(node.hostName) (this Mac)" : node.hostName)
                    if let dns = node.dnsName { InfoRow(label: "MagicDNS", value: dns, monospaced: true, copyable: true) }
                    if let url = node.url { InfoRow(label: "URL", value: url.absoluteString, link: url) }
                    if let ip = node.ips.first { InfoRow(label: "IP", value: ip, monospaced: true, copyable: true) }
                    if let os = node.os, !os.isEmpty { InfoRow(label: "OS", value: os) }
                    if let tailnet = status.tailnetName { InfoRow(label: "Tailnet", value: tailnet) }
                } else {
                    note("No tailnet machine named “\(agent.tailscaleName ?? agent.host ?? agent.id)”.")
                }
            } else {
                note(error ?? "Reading Tailscale status…")
            }
        }
    }

    private func statusText(_ node: TailscaleNode) -> String {
        if node.online { return "Online" }
        guard let seen = node.lastSeen, seen > Date(timeIntervalSince1970: 0) else { return "Offline" }
        return "Offline · last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    private func note(_ text: String) -> some View {
        GridRow {
            Text(text).tavernFont(.callout).foregroundStyle(.secondary).gridCellColumns(3)
        }
    }
}
