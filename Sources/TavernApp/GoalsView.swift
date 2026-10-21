import AppKit
import SwiftUI
import TavernCore

/// Open PAUL issues (plan 3f), in three columns: filters (status, project, owner) with counts,
/// the matching issues, and the selected issue's details. Read-only toward Linear; an issue can
/// be handed to a Pi agent as a prompt the user reviews before sending.
struct GoalsView: View {
    enum Filter: Hashable {
        case all
        case status(String)
        case project(String)
        case owner(String)
        case agent(String)
    }

    @EnvironmentObject private var model: AppModel
    @Binding var page: Page?
    private var issues: [LinearIssue] { model.openIssues }
    @State private var error: String?
    @State private var loading = false
    @State private var filter: Filter? = .all
    @State private var selection: String?
    @State private var query = ""
    @State private var creating = false
    @AppStorage("tavern.goals.sort") private var sort: Sort = .status

    enum Sort: String, CaseIterable, Identifiable {
        case status = "Status", priority = "Priority", updated = "Recently updated", agent = "Agent", identifier = "ID"
        var id: String { rawValue }
    }

    /// A flat list in the chosen order (Status keeps the grouped sections instead).
    private func sorted(_ issues: [LinearIssue]) -> [LinearIssue] {
        switch sort {
        case .status: return issues
        case .priority:
            // Urgent first; no priority (0) last.
            return issues.sorted { ($0.priority == 0 ? 9 : $0.priority, $1.updatedAt ?? .distantPast) < ($1.priority == 0 ? 9 : $1.priority, $0.updatedAt ?? .distantPast) }
        case .updated: return issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .agent:
            return issues.sorted { (model.agent(for: $0)?.name ?? "~", $0.identifier) < (model.agent(for: $1)?.name ?? "~", $1.identifier) }
        case .identifier:
            // Highest number (newest) first.
            return issues.sorted { Int($0.identifier.split(separator: "-").last ?? "") ?? 0 > Int($1.identifier.split(separator: "-").last ?? "") ?? 0 }
        }
    }

    var body: some View {
        Group {
            if model.linear == nil {
                note("No Linear team yet", "Goals reads a Linear team's open issues through Personal Agent Proxy. Add the team key in Settings > Party.")
            } else if model.mail?.state == .signedOut {
                ProxySignInPrompt(purpose: "to read your Linear goals")
            } else if let error, issues.isEmpty {
                note("Couldn't load Linear", error)
            } else if issues.isEmpty && loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    filters.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                    issueList.frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                    detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Goals")
        .task { await load(refresh: false) }
        .onAppear { takeNewTicketRequest() }
        .onChange(of: model.newTicketRequested) { _, _ in takeNewTicketRequest() }
        .sheet(isPresented: $creating) {
            NewTicketSheet(defaultProject: { if case .project(let name)? = filter { return name } else { return nil } }(),
                           defaultAgent: { if case .agent(let id)? = filter { return id } else { return nil } }()) { identifier in
                selection = identifier
                Task { await load(refresh: true) }
            }
            .environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tavernRefresh)) { _ in Task { await load(refresh: true) } }
    }

    // MARK: Filters

    static let statusOrder: [(type: String, name: String, symbol: String)] = [
        ("started", "In progress", "circle.lefthalf.filled"),
        ("unstarted", "Todo", "circle"),
        ("backlog", "Backlog", "circle.dashed"),
        ("triage", "Triage", "tray"),
    ]

    private var filters: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { creating = true } label: { Label("New Ticket", systemImage: "square.and.pencil") }
                    .buttonStyle(PillButtonStyle())
                    .help("New Linear ticket, optionally for an agent")
                    .disabled(model.linear == nil)
                Spacer()
                Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Refresh from Linear")
                    .disabled(loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            filterList
        }
    }

    private var filterList: some View {
        List(selection: $filter) {
            row("All open", symbol: "square.stack", count: issues.count).tag(Filter.all)
            Section("Status") {
                ForEach(Self.statusOrder, id: \.type) { status in
                    let count = issues.filter { $0.stateType == status.type }.count
                    if count > 0 { row(status.name, symbol: status.symbol, count: count).tag(Filter.status(status.type)) }
                }
            }
            Section("Projects") {
                ForEach(counts(\.project), id: \.name) { item in
                    row(item.name, symbol: "folder", count: item.count).tag(Filter.project(item.name))
                }
            }
            // Agents first (from agent:<id> labels), then people who own issues.
            Section("Agents") {
                ForEach(model.roster.members) { member in
                    let count = issues.filter { model.agent(for: $0)?.id == member.id }.count
                    if count > 0 {
                        HStack {
                            HStack(spacing: 8) { AvatarView(member: member, size: 20); Text(member.name) }
                            Spacer()
                            CountBadge(count: count)
                        }
                        .padding(.vertical, 2)
                        .tag(Filter.agent(member.id))
                    }
                }
            }
            Section("People") {
                ForEach(counts(\.owner).filter { name in model.roster.members.allSatisfy { !GoalsView.matches($0, owner: name.name) } }, id: \.name) { item in
                    row(item.name, symbol: "person", count: item.count).tag(Filter.owner(item.name))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer()
            CountBadge(count: count)
        }
        .padding(.vertical, 2)
    }

    private func counts(_ key: KeyPath<LinearIssue, String?>) -> [(name: String, count: Int)] {
        Dictionary(grouping: issues.compactMap { $0[keyPath: key] }, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    // MARK: Issues

    private var shown: [LinearIssue] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return issues.filter { issue in
            switch filter ?? .all {
            case .all: return true
            case .status(let type): return issue.stateType == type
            case .project(let name): return issue.project == name
            case .owner(let name): return issue.owner == name
            case .agent(let id): return model.agent(for: issue)?.id == id
            }
        }
        .filter { issue in
            guard !q.isEmpty else { return true }
            // "60" or "paul-60" finds PAUL-60 exactly, not PAUL-160; words search titles.
            let number = issue.identifier.split(separator: "-").last.map(String.init) ?? ""
            if q.allSatisfy(\.isNumber) { return number == q || issue.title.lowercased().contains(q) }
            return issue.identifier.lowercased() == q || issue.title.lowercased().contains(q)
                || issue.identifier.lowercased().hasPrefix(q)
        }
    }

    private var issueList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by title or ID (60)", text: $query).textFieldStyle(.plain)
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort issues")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            List(selection: $selection) {
                let shown = self.shown
                if sort != .status {
                    ForEach(sorted(shown)) { issue in
                        GoalRow(issue: issue, agent: model.agent(for: issue), labelled: model.isLabelled(issue)).tag(issue.identifier)
                    }
                } else {
                ForEach(Self.statusOrder, id: \.type) { status in
                    let group = shown.filter { $0.stateType == status.type }
                    if !group.isEmpty {
                        Section(status.name) {
                            ForEach(group) { issue in GoalRow(issue: issue, agent: model.agent(for: issue), labelled: model.isLabelled(issue)).tag(issue.identifier) }
                        }
                    }
                }
                let other = shown.filter { issue in !Self.statusOrder.contains { $0.type == issue.stateType } }
                if !other.isEmpty {
                    Section("Other") { ForEach(other) { issue in GoalRow(issue: issue, agent: model.agent(for: issue), labelled: model.isLabelled(issue)).tag(issue.identifier) } }
                }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let issue = issues.first(where: { $0.identifier == selection }), let linear = model.linear {
            GoalDetail(issue: issue, linear: linear, page: $page).id(issue.identifier)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Select an issue").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func takeNewTicketRequest() {
        guard model.newTicketRequested else { return }
        model.newTicketRequested = false
        creating = true
    }

    private func load(refresh: Bool) async {
        guard model.linear != nil else { return }
        loading = true
        defer { loading = false }
        do {
            try await model.loadOpenIssues(refresh: refresh)
            error = nil
            if let focus = model.focusedGoal {
                selection = focus
                model.focusedGoal = nil
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).tavernFont(.title2, weight: .semibold)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A capsule button with one height everywhere it's used (Open in Linear, Send to an agent).
struct PillButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tavernFont(.callout, weight: .medium)
            .labelStyle(.titleAndIcon)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 32)
            .background(
                selected ? AnyShapeStyle(Color.tavernAccent.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(configuration.isPressed ? 0.9 : 0.55)),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(selected ? Color.tavernAccent.opacity(0.6) : Color.clear))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .tavernFont(.caption, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

private struct GoalRow: View {
    let issue: LinearIssue
    let agent: RosterMember?
    var labelled = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriorityMark(priority: issue.priority)
                    Text(issue.title).tavernFont(.callout, weight: .medium).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(issue.identifier).monospacedDigit()
                    if let project = issue.project { Text("·"); Text(project).lineLimit(1) }
                    if agent == nil, let owner = issue.owner { Text("·"); Text(owner).lineLimit(1) }
                }
                .tavernFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let agent { AgentTag(member: agent, assigned: labelled) }
        }
        .padding(.vertical, 5)
    }
}

/// An agent's avatar and name in a capsule: who an issue belongs to.
/// Filled when the issue carries the agent's label; outlined when it's theirs by project.
struct AgentTag: View {
    let member: RosterMember
    var assigned = true

    var body: some View {
        HStack(spacing: 5) {
            AvatarView(member: member, size: 16)
            Text(member.name).tavernFont(.caption, weight: .medium)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Color(hex: member.avatarColor).opacity(assigned ? 0.28 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(hex: member.avatarColor).opacity(assigned ? 0 : 0.6)))
        .help(assigned ? "Labelled agent:\(member.id)" : "\(member.name) owns this project")
    }
}

extension GoalsView {
    static func matches(_ member: RosterMember, owner: String) -> Bool {
        let lower = owner.lowercased()
        return lower == member.id.lowercased() || lower == member.name.lowercased()
    }
}

/// A new Linear ticket: title, description, project and (optionally) the agent it's for. Can also
/// send it to that agent right away.
private struct NewTicketSheet: View {
    let defaultProject: String?
    let defaultAgent: String?
    let created: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var projects: [LinearProject] = []
    @State private var projectID: String?
    @State private var agentID: String?
    @State private var sendNow = false
    @State private var working = false
    @State private var error: String?

    var body: some View { sheet.themedSurface() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New ticket").tavernFont(.title3, weight: .semibold)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $details)
                .font(.body)
                .frame(minWidth: 520, minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if details.isEmpty {
                        Text("Description (Markdown)").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
            Picker("Project", selection: $projectID) {
                Text("No project").tag(String?.none)
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("For").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                        Button("Nobody") { agentID = nil; sendNow = false }
                            .buttonStyle(PillButtonStyle(selected: agentID == nil))
                        ForEach(model.roster.members) { member in
                            Button { agentID = member.id } label: {
                                HStack(spacing: 6) { AvatarView(member: member, size: 20); Text(member.name) }
                            }
                            .buttonStyle(PillButtonStyle(selected: agentID == member.id))
                        }
                }
                if let agentID, let member = model.roster.member(id: agentID), member.kind == .pi {
                    Toggle("Also send it to \(member.name) now", isOn: $sendNow)
                        .disabled(model.session(for: agentID) == nil)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Creates the issue in Linear and labels it agent:<name>.").tavernFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            agentID = defaultAgent
            projects = (try? await model.linear?.projects()) ?? []
            if let defaultProject { projectID = projects.first { $0.name == defaultProject }?.id }
        }
    }

    private func create() {
        guard let linear = model.linear else { return }
        working = true
        let title = title.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let issue = try await linear.createIssue(title: title, description: details, projectID: projectID, agentID: agentID)
                if sendNow, let agentID, let session = model.session(for: agentID) {
                    let ticket = LinearIssue(identifier: issue.identifier, title: title, url: issue.url, state: "Todo")
                    await session.send(ticket.agentPrompt(description: details))
                    model.recordAssignment(ticket, to: agentID)
                }
                created(issue.identifier)
                dismiss()
            } catch {
                self.error = "Couldn't create it: \(error)"
                working = false
            }
        }
    }
}

/// One issue: its fields, description and comments, with Open in Linear and Send to agent.
private struct GoalDetail: View {
    let issue: LinearIssue
    let linear: LinearSource
    @Binding var page: Page?
    @EnvironmentObject private var model: AppModel
    @State private var detail: LinearIssueDetail?
    @State private var error: String?
    @State private var sendTo: RosterMember?
    @State private var states: [LinearState] = []
    @State private var projects: [LinearProject] = []
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftDescription = ""
    @State private var saving = false
    @State private var comments: [LinearComment] = []
    @State private var commentsCursor: String?
    @State private var commentsLoaded = false
    @State private var loadingComments = false

    /// Labelled agent, or else the project's owner as a suggestion.
    private var owner: RosterMember? { model.agent(for: issue) }
    private var labelled: Bool { model.isLabelled(issue) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let writeError = model.linearWriteError {
                    Label(writeError, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange)
                }
                ownerSection
                sendSection
                fields
                descriptionSection
                discussion
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task {
            // What was read last time shows at once; fresh reads replace it.
            if detail == nil { detail = model.issueDetails[issue.identifier] }
            if states.isEmpty { states = model.linearStates }
            if projects.isEmpty { projects = model.linearProjects }
            async let detailTask = linear.detail(issue.identifier)
            async let statesTask = linear.workflowStates()
            async let projectsTask = linear.projects()
            do {
                let fresh = try await detailTask
                detail = fresh
                model.issueDetails[issue.identifier] = fresh
            } catch {
                if detail == nil { self.error = String(describing: error) }
            }
            await loadComments()
            if let fresh = try? await statesTask { states = fresh; model.linearStates = fresh }
            if let fresh = try? await projectsTask { projects = fresh; model.linearProjects = fresh }
        }
        .sheet(item: $sendTo) { agent in
            SendToAgentSheet(agent: agent, prompt: issue.agentPrompt(description: detail?.description ?? "")) { text in
                guard let session = model.session(for: agent.id) else { return }
                Task { await session.send(text) }
                model.assign(issue, to: agent.id)
                page = .agent(id: agent.id)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(issue.identifier).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                PriorityMark(priority: issue.priority)
            }
            if editing {
                TextField("Title", text: $draftTitle).textFieldStyle(.roundedBorder).tavernFont(.title3)
            } else {
                Text(issue.title).tavernFont(.title2, weight: .semibold).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let url = issue.url {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in Linear", systemImage: "arrow.up.right.square") }
                        .buttonStyle(PillButtonStyle())
                }
                if editing {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .buttonStyle(PillButtonStyle(selected: true))
                        .disabled(saving || draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Cancel") { editing = false }.buttonStyle(PillButtonStyle())
                } else {
                    Button { startEditing() } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(PillButtonStyle())
                        .help("Edit the title and description")
                }
            }
            .padding(.top, 4)
        }
    }

    /// Who owns it: every party member, the labelled one filled, the suggested one marked.
    private var ownerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Owner").tavernFont(.headline, weight: .semibold)
                if let owner, !labelled {
                    Text("Suggested: \(owner.name), who owns \(issue.project ?? "this project")")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(model.roster.members) { member in
                    Button { Task { await model.label(issue, for: member.id) } } label: {
                        HStack(spacing: 6) {
                            AvatarView(member: member, size: 20)
                            Text(member.name)
                            if member.id == owner?.id && !labelled {
                                Text("Suggested").tavernFont(.caption, weight: .semibold)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.tavernAccent.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(PillButtonStyle(selected: labelled && member.id == owner?.id))
                    .help("Label \(issue.identifier) agent:\(member.id) in Linear")
                }
            }
        }
    }

    /// Hand it to a Pi agent now; the suggested owner comes first when they're one.
    private var sendSection: some View {
        let agents = model.roster.piAgents.sorted { a, _ in a.id == owner?.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Send to an agent").tavernFont(.headline, weight: .semibold)
                Spacer()
                if let assigned = model.assignment(for: issue.identifier), let agent = model.roster.member(id: assigned.agentID) {
                    Text("Sent to \(agent.name) \(assigned.sentAt.formatted(.relative(presentation: .named)))")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(agents) { agent in
                    Button { sendTo = agent } label: {
                        HStack(spacing: 8) { AvatarView(member: agent, size: 22); Text(agent.name) }
                    }
                    .buttonStyle(PillButtonStyle(selected: model.assignment(for: issue.identifier)?.agentID == agent.id))
                    .disabled(model.session(for: agent.id) == nil)
                    .help(model.session(for: agent.id) == nil ? "\(agent.name) isn't connected" : "Write a message for \(agent.name) about \(issue.identifier)")
                }
            }
        }
    }

    /// Status, priority and project apply as soon as they change.
    private var fields: some View {
        InfoCard(title: "Details") {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { states.first { $0.name == issue.state }?.id ?? "" },
                                              set: { id in Task { await model.update(issue, stateID: id) } })) {
                    if states.isEmpty { Text(issue.state).tag("") }
                    ForEach(states) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                Text("Priority").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { issue.priority }, set: { value in Task { await model.update(issue, priority: value) } })) {
                    ForEach(0..<5, id: \.self) { Text(Self.priority($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                Text("Project").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { projects.first { $0.name == issue.project }?.id },
                                              set: { id in Task { await model.update(issue, projectID: .some(id)) } })) {
                    Text("No project").tag(String?.none)
                    if projects.isEmpty, let project = issue.project { Text(project).tag(String?.none) }
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
                Color.clear.frame(width: 1, height: 1)
            }
            if !issue.labels.isEmpty { InfoRow(label: "Labels", value: issue.labels.joined(separator: ", ")) }
            if let updated = issue.updatedAt { InfoRow(label: "Updated", value: updated.formatted(.relative(presentation: .named))) }
        }
        .tavernFont(.callout)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Description").tavernFont(.headline, weight: .semibold)
            if editing {
                TextEditor(text: $draftDescription)
                    .font(.body)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            } else if let detail {
                if detail.description.isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(text: detail.description)
                }
            } else if let error {
                Text(error).tavernFont(.callout).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// The discussion, newest first, a page at a time.
    @ViewBuilder
    private var discussion: some View {
        if commentsLoaded {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Discussion").tavernFont(.headline, weight: .semibold)
                    if !comments.isEmpty { CountBadge(count: comments.count) }
                    if commentsCursor != nil { Text("newest first").tavernFont(.caption).foregroundStyle(.secondary) }
                }
                if comments.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(comment.author).tavernFont(.callout, weight: .semibold)
                            if let date = comment.date {
                                Text(date.formatted(.relative(presentation: .named))).tavernFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        MarkdownText(text: comment.body)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
                if commentsCursor != nil {
                    Button(loadingComments ? "Loading…" : "Show older comments") { Task { await loadComments() } }
                        .buttonStyle(PillButtonStyle())
                        .disabled(loadingComments)
                }
            }
        }
    }

    private func loadComments() async {
        loadingComments = true
        defer { loadingComments = false }
        do {
            let page = try await linear.comments(issue.identifier, after: commentsCursor)
            comments += page.comments
            commentsCursor = page.next
        } catch {
            self.error = String(describing: error)
        }
        commentsLoaded = true
    }

    private func startEditing() {
        draftTitle = issue.title
        draftDescription = detail?.description ?? ""
        editing = true
    }

    private func save() {
        saving = true
        let title = draftTitle.trimmingCharacters(in: .whitespaces)
        let description = draftDescription
        Task {
            let ok = await model.update(issue, title: title == issue.title ? nil : title,
                                        description: description == detail?.description ? nil : description)
            if ok {
                detail?.description = description
                editing = false
            }
            saving = false
        }
    }

    static func priority(_ value: Int) -> String {
        ["None", "Urgent", "High", "Medium", "Low"][min(max(value, 0), 4)]
    }
}

/// Linear priority as exclamation marks: !!! urgent, !! high, ! medium; nothing for low or none.
struct PriorityMark: View {
    let priority: Int

    var body: some View {
        let marks = [1: "!!!", 2: "!!", 3: "!"][priority]
        if let marks {
            Text(marks)
                .font(.system(.callout, design: .rounded, weight: .heavy))
                .foregroundStyle(priority == 1 ? Color.red : (priority == 2 ? Color.orange : Color.secondary))
                .help(GoalDetail.priority(priority))
        }
    }
}

/// the user reviews and edits the prompt before it goes to the agent.
private struct SendToAgentSheet: View {
    let agent: RosterMember
    @State var prompt: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View { sheet.themedSurface() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(member: agent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to \(agent.name)").tavernFont(.headline, weight: .semibold)
                    Text("This becomes a message in \(agent.name)'s thread.").tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $prompt)
                .font(.system(.body))
                .frame(minWidth: 520, minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { send(prompt); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
