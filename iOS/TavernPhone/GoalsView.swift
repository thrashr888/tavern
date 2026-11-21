import SwiftUI
import TavernCore

/// The Mac's Goals, phone-sized: the team's open issues grouped by status, filtered by status,
/// project, agent or person, searched by title or ID, and each one's details. An issue can be
/// handed to a party agent as a prompt Paul reviews first. Read-only toward Linear.
struct GoalsView: View {
    enum Filter: Hashable {
        case all
        case status(String)
        case project(String)
        case agent(String)
        case owner(String)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case status = "Status", priority = "Priority", updated = "Recently updated", agent = "Agent", identifier = "ID"
        var id: String { rawValue }
    }

    @EnvironmentObject private var pap: PAPPhone
    @State private var issues: [LinearIssue] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var query = ""
    @AppStorage("tavern.goals.sort") private var sort: Sort = .status

    static let statusOrder: [(type: String, name: String, symbol: String)] = [
        ("started", "In progress", "circle.lefthalf.filled"),
        ("unstarted", "Todo", "circle"),
        ("backlog", "Backlog", "circle.dashed"),
        ("triage", "Triage", "tray"),
    ]

    var body: some View {
        NeedsPAP(purpose: "your Linear goals") {
            if pap.linear == nil {
                ContentUnavailableView("No Linear team", systemImage: "list.bullet.rectangle",
                                       description: Text("Goals reads the team set in the Mac's Settings > Party. Rebuild the app after setting it."))
            } else {
                list
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: LinearIssue.self) { GoalDetailView(issue: $0) }
    }

    private var title: String {
        switch filter {
        case .all: "Goals"
        case .status(let type): Self.statusOrder.first { $0.type == type }?.name ?? "Goals"
        case .project(let name), .owner(let name): name
        case .agent(let id): Party.info.members?.first { $0.id == id }?.name ?? "Goals"
        }
    }

    private var list: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if sort == .status {
                ForEach(Self.statusOrder, id: \.type) { status in
                    let group = shown.filter { $0.stateType == status.type }
                    if !group.isEmpty { Section(status.name) { rows(group) } }
                }
                let other = shown.filter { issue in !Self.statusOrder.contains { $0.type == issue.stateType } }
                if !other.isEmpty { Section("Other") { rows(other) } }
            } else {
                rows(sorted(shown))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Title or ID (60)")
        .overlay {
            if loaded && issues.isEmpty && error == nil {
                ContentUnavailableView("No open goals", systemImage: "checkmark.circle")
            } else if !loaded {
                ProgressView()
            } else if shown.isEmpty && !issues.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .refreshable { await load(refresh: true) }
        .task { if !loaded { await load(refresh: false) } }
    }

    private func rows(_ issues: [LinearIssue]) -> some View {
        ForEach(issues) { issue in
            NavigationLink(value: issue) { GoalRow(issue: issue) }
        }
    }

    // MARK: Filters and sort

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                Label("All open (\(issues.count))", systemImage: "square.stack").tag(Filter.all)
            }
            Section("Status") {
                Picker("Status", selection: $filter) {
                    ForEach(Self.statusOrder, id: \.type) { status in
                        let count = issues.filter { $0.stateType == status.type }.count
                        if count > 0 { Label("\(status.name) (\(count))", systemImage: status.symbol).tag(Filter.status(status.type)) }
                    }
                }
            }
            Section("Projects") {
                Picker("Project", selection: $filter) {
                    ForEach(counts(issues.compactMap(\.project)), id: \.name) { item in
                        Label("\(item.name) (\(item.count))", systemImage: "folder").tag(Filter.project(item.name))
                    }
                }
            }
            Section("Party") {
                Picker("Agent", selection: $filter) {
                    ForEach(Party.info.members ?? []) { member in
                        let count = issues.filter { Party.member(for: $0)?.id == member.id }.count
                        if count > 0 { Label("\(member.name) (\(count))", systemImage: "person.crop.circle").tag(Filter.agent(member.id)) }
                    }
                }
            }
            let people = counts(issues.compactMap(\.owner)).filter { item in
                !(Party.info.members ?? []).contains { $0.id.lowercased() == item.name.lowercased() || $0.name.lowercased() == item.name.lowercased() }
            }
            if !people.isEmpty {
                Section("People") {
                    Picker("Person", selection: $filter) {
                        ForEach(people, id: \.name) { item in Label("\(item.name) (\(item.count))", systemImage: "person").tag(Filter.owner(item.name)) }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func counts(_ names: [String]) -> [(name: String, count: Int)] {
        Dictionary(grouping: names, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private var shown: [LinearIssue] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return issues.filter { issue in
            switch filter {
            case .all: true
            case .status(let type): issue.stateType == type
            case .project(let name): issue.project == name
            case .agent(let id): Party.member(for: issue)?.id == id
            case .owner(let name): issue.owner == name
            }
        }
        .filter { issue in
            guard !q.isEmpty else { return true }
            // "60" or "paul-60" finds PAUL-60 exactly, not PAUL-160; words search titles.
            let number = issue.identifier.split(separator: "-").last.map(String.init) ?? ""
            if q.allSatisfy(\.isNumber) { return number == q || issue.title.lowercased().contains(q) }
            return issue.identifier.lowercased().hasPrefix(q) || issue.title.lowercased().contains(q)
        }
    }

    private func sorted(_ issues: [LinearIssue]) -> [LinearIssue] {
        switch sort {
        case .status: return issues
        case .priority:
            // Urgent first; no priority (0) last.
            return issues.sorted { ($0.priority == 0 ? 9 : $0.priority, $1.updatedAt ?? .distantPast) < ($1.priority == 0 ? 9 : $1.priority, $0.updatedAt ?? .distantPast) }
        case .updated: return issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .agent: return issues.sorted { (Party.member(for: $0)?.name ?? "~", $0.identifier) < (Party.member(for: $1)?.name ?? "~", $1.identifier) }
        case .identifier:
            return issues.sorted { Int($0.identifier.split(separator: "-").last ?? "") ?? 0 > Int($1.identifier.split(separator: "-").last ?? "") ?? 0 }
        }
    }

    private func load(refresh: Bool) async {
        do {
            issues = try await pap.goals(refresh: refresh)
            error = nil
        } catch {
            self.error = PAPPhone.message(for: error, signingIn: false)
        }
        loaded = true
    }
}

extension LinearIssue: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }
}

private struct GoalRow: View {
    let issue: LinearIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriorityMark(priority: issue.priority)
                    Text(issue.title).font(.subheadline.weight(.medium)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(issue.identifier).monospacedDigit()
                    if let project = issue.project { Text("·"); Text(project).lineLimit(1) }
                    if Party.member(for: issue) == nil, let owner = issue.owner { Text("·"); Text(owner).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let member = Party.member(for: issue) {
                AgentTag(member: member, labelled: issue.labels.contains { $0.lowercased().hasPrefix("agent:") })
            }
        }
        .padding(.vertical, 2)
    }
}

struct PriorityMark: View {
    let priority: Int

    var body: some View {
        if let marks = [1: "!!!", 2: "!!", 3: "!"][priority] {
            Text(marks)
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(priority == 1 ? Color.red : (priority == 2 ? Color.orange : Color.secondary))
        }
    }

    static func name(_ priority: Int) -> String {
        ["No priority", "Urgent", "High", "Medium", "Low"][safe: priority] ?? "No priority"
    }
}

/// Who an issue belongs to: filled when it carries their `agent:` label, outlined when it's
/// theirs because they own its project.
private struct AgentTag: View {
    let member: Party.Member
    var labelled = true

    var body: some View {
        HStack(spacing: 4) {
            Avatar(name: member.id, size: 16)
            Text(member.name).font(.caption.weight(.medium))
        }
        .padding(.leading, 2)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Color.tavernAccent.opacity(labelled ? 0.22 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.tavernAccent.opacity(labelled ? 0 : 0.5)))
    }
}

/// One issue: its fields, description and comments, Open in Linear, and Send to an agent.
private struct GoalDetailView: View {
    let issue: LinearIssue
    @EnvironmentObject private var pap: PAPPhone
    @EnvironmentObject private var model: PhoneModel
    @State private var detail: LinearIssueDetail?
    @State private var error: String?
    @State private var sending: PhoneAgent?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.identifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(issue.title).font(.title3.bold())
                }
                LabeledContent("Status", value: issue.state)
                if issue.priority > 0 { LabeledContent("Priority", value: PriorityMark.name(issue.priority)) }
                if let project = issue.project { LabeledContent("Project", value: project) }
                if let member = Party.member(for: issue) {
                    LabeledContent("Agent") { HStack(spacing: 6) { Avatar(name: member.id, size: 20); Text(member.name) } }
                } else if let owner = issue.owner {
                    LabeledContent("Owner", value: owner)
                }
                if let updated = issue.updatedAt { LabeledContent("Updated", value: updated.formatted(.relative(presentation: .named))) }
            }
            Section {
                if let url = issue.url { Link(destination: url) { Label("Open in Linear", systemImage: "arrow.up.right.square") } }
                Menu {
                    ForEach(model.agents) { agent in
                        Button(agent.name) { sending = agent }
                    }
                } label: {
                    Label("Send to an agent", systemImage: "paperplane")
                }
                .disabled(model.agents.isEmpty)
            }
            Section("Description") {
                if let detail {
                    if detail.description.isEmpty { Text("No description.").foregroundStyle(.secondary) } else { MarkdownView(text: detail.description) }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            if let comments = detail?.comments, !comments.isEmpty {
                Section("Comments") {
                    ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(comment.author).font(.subheadline.weight(.semibold))
                                Spacer()
                                if let date = comment.date { Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                            }
                            MarkdownView(text: comment.body)
                        }
                    }
                }
            }
        }
        .navigationTitle(issue.identifier)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await pap.goalDetail(issue.identifier) } catch { self.error = PAPPhone.message(for: error, signingIn: false) }
        }
        .sheet(item: $sending) { agent in
            SendToAgentSheet(agent: agent, prompt: issue.agentPrompt(description: detail?.description ?? "")) { text in
                guard let session = model.session(for: agent) else { return }
                Task { session.isWorking ? await session.followUp(text) : await session.send(text) }
            }
        }
    }
}

/// The prompt an issue becomes, for Paul to edit before it goes to the agent.
private struct SendToAgentSheet: View {
    let agent: PhoneAgent
    @State var prompt: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $prompt)
                .padding(.horizontal, 12)
                .navigationTitle("To \(agent.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            send(prompt)
                            dismiss()
                        }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
