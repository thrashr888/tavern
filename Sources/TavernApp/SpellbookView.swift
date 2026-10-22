import AppKit
import SwiftUI
import TavernCore

/// The party's spellbook as last pulled: Tavern's read-only clone of the repo in roster.json
/// (`spellbookRepo`), refreshed at launch, every 15 minutes and from Refresh.
@MainActor
final class SpellbookStore: ObservableObject {
    @Published private(set) var snapshot: SpellbookSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var syncing = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var repo: SpellbookRepo?
    /// Runs started here, newest first (slice 2: manual checklists).
    @Published private(set) var runs: [SpellRun] = []
    @Published private(set) var runError: String?
    private var documents: [String: SpellDocument] = [:]
    private let runStore = SpellRunStore.defaultURL().map(SpellRunStore.init(url:))

    init() { runs = runStore?.load() ?? [] }

    /// The newest unfinished run of a spell.
    func openRun(for spellID: String) -> SpellRun? { runs.first { $0.spellID == spellID && !$0.isFinished } }

    /// Starts a checklist from the spell's steps, and logs the start so it counts as a cast.
    func startRun(_ spell: Spell, document: SpellDocument, agentID: String?, events: EventStore?) {
        let run = SpellRun(spell: spell, document: document, commit: snapshot?.commit, agentID: agentID)
        save(run)
        _ = try? events?.append([run.startEvent])
    }

    func toggle(_ step: Int, in run: SpellRun) {
        var run = run
        run.toggle(step)
        save(run)
    }

    func finish(_ run: SpellRun) {
        var run = run
        run.finishedAt = Date()
        save(run)
    }

    private func save(_ run: SpellRun) {
        do {
            runs = try runStore?.save(run) ?? runs
            runError = nil
        } catch {
            runError = "Couldn't save the run: \(error.localizedDescription)"
        }
    }

    /// Points at the roster's repo and shows what's already on disk.
    func configure(roster: Roster) async {
        guard let source = SpellbookSource(roster: roster), let directory = SpellbookRepo.defaultDirectory() else {
            repo = nil
            snapshot = nil
            return
        }
        guard repo?.source != source else { return }
        repo = SpellbookRepo(source: source, directory: directory)
        documents = [:]
        snapshot = try? await repo?.snapshot()
    }

    /// Pulls, then rereads. On failure the last good copy stays, with the error beside it.
    func refresh() async {
        guard let repo, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await repo.sync()
            snapshot = try await repo.snapshot()
            documents = [:]
            error = nil
            refreshedAt = Date()
        } catch let failure as SpellbookError {
            error = failure.description
        } catch {
            self.error = error.localizedDescription
        }
    }

    func watch(roster: Roster) async {
        await configure(roster: roster)
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(15 * 60))
        }
    }

    func document(for spell: Spell) -> Result<SpellDocument, SpellbookError> {
        if let cached = documents["\(spell.id)@\(snapshot?.commit ?? "")"] { return .success(cached) }
        guard let repo else { return .failure(SpellbookError(message: "No spellbook repo is set.")) }
        do {
            let document = try repo.document(for: spell)
            documents["\(spell.id)@\(snapshot?.commit ?? "")"] = document
            return .success(document)
        } catch let error as SpellbookError {
            return .failure(error)
        } catch {
            return .failure(SpellbookError(message: "Couldn't read \(spell.path): \(error.localizedDescription)"))
        }
    }

    /// "as of 3f2a1c9, 2 hours ago", for the page and the detail's source line.
    var asOf: String? {
        guard let snapshot, let commit = snapshot.commit else { return nil }
        let when = snapshot.committedAt.map { ", \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return "\(commit)\(when)"
    }
}

/// Spells, read-only (mocks 1 to 4): a filterable list grouped by lifecycle, and the open spell's
/// SKILL.md. Pages restore by SB id.
struct SpellbookView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    @Binding var page: Page?
    let spellID: String?
    @State private var query = ""
    @State private var kind: String?
    @State private var agent: String?
    @State private var showRetired = false
    /// A decision model's pick for a search that reads like a task ("draft the weekly update").
    @State private var suggested: String?

    private var selection: Binding<String?> {
        Binding(get: { spellID }, set: { id in page = .spellbook(spell: id) })
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Spellbook")
        .onReceive(NotificationCenter.default.publisher(for: .tavernRefresh)) { _ in Task { await book.refresh() } }
        .task(id: query) { await suggest() }
    }

    /// Three words or more read as a task: after a pause, ask which spell fits it.
    private func suggest() async {
        suggested = nil
        let task = query.trimmingCharacters(in: .whitespaces)
        guard task.split(separator: " ").count >= 3, let snapshot = book.snapshot else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled else { return }
        let candidates = snapshot.spells.filter { !$0.isRetired }
        guard let answers = await model.decisions.ask(site: "spellbook", state: "Task: \(task)",
                                                      questions: DecisionSuggestions.spellQuestions(for: candidates), events: model.store),
              !Task.isCancelled else { return }
        suggested = DecisionSuggestions.spell(from: answers)?.id
    }

    // MARK: List

    private var spells: [Spell] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let member = agent.flatMap { model.roster.member(id: $0) }
        return (book.snapshot?.spells ?? []).filter { spell in
            (showRetired || !spell.isRetired)
                && (kind == nil || spell.kind == kind)
                && (member.map(spell.applies(to:)) ?? true)
                && (q.isEmpty || [spell.id, spell.title, spell.description].contains { $0.lowercased().contains(q) })
        }
    }

    private static let groups: [(lifecycle: String, title: String)] = [("live", "Live"), ("proposal", "Proposals"), ("retired", "Retired")]

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search spells", text: $query).textFieldStyle(.plain)
                if book.syncing { ProgressView().controlSize(.small) }
                Button { Task { await book.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(book.asOf.map { "As of \($0)" } ?? "Refresh")
                    .disabled(book.repo == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            filters
            Divider()
            if book.repo == nil {
                setup("No spellbook yet", detail: "Add \"spellbookRepo\" (a git URL) to roster.json, and Tavern keeps a read-only copy.")
            } else if book.snapshot == nil {
                if let error = book.error {
                    setup("Couldn't get the spellbook", detail: "\(error)\n\nTavern runs: \(book.repo?.cloneCommand ?? "")", retry: true)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(selection: selection) {
                    if let suggested, let spell = book.snapshot?.spell(id: suggested) {
                        SuggestionChip(text: "\(spell.id) \(spell.title)", help: "Clef's pick for “\(query)”") { page = .spellbook(spell: spell.id) }
                    }
                    if let error = book.error {
                        Label("Showing the last copy\(book.asOf.map { " (\($0))" } ?? ""): \(error)", systemImage: "exclamationmark.triangle")
                            .tavernFont(.caption).foregroundStyle(.orange)
                    }
                    ForEach(Self.groups, id: \.lifecycle) { group in
                        let shown = spells.filter { $0.lifecycle == group.lifecycle }
                        if !shown.isEmpty {
                            Section {
                                ForEach(shown) { spell in
                                    SpellRow(spell: spell).themedTag(spell.id, selection: spellID)
                                }
                            } header: {
                                HStack {
                                    Text(group.title)
                                    Spacer()
                                    CountBadge(count: shown.count)
                                }
                            }
                        }
                    }
                    // Lifecycles a newer repo adds still show.
                    let others = spells.filter { spell in !Self.groups.contains { $0.lifecycle == spell.lifecycle } }
                    if !others.isEmpty {
                        Section("Other") {
                            ForEach(others) { SpellRow(spell: $0).themedTag($0.id, selection: spellID) }
                        }
                    }
                    if spells.isEmpty { Text("No matches").tavernFont(.caption).foregroundStyle(.tertiary) }
                }
                .listStyle(.sidebar)
                .themedList()
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            Menu(kind.map { $0 == "ritual" ? "Rituals" : "Spells" } ?? "All kinds") {
                Button("All kinds") { kind = nil }
                Button("Spells") { kind = "spell" }
                Button("Rituals") { kind = "ritual" }
            }
            Menu(agent.flatMap { model.roster.member(id: $0)?.name } ?? "Everyone") {
                Button("Everyone") { agent = nil }
                ForEach(model.roster.members) { member in
                    Button(member.name) { agent = member.id }
                }
            }
            Toggle("Retired", isOn: $showRetired).toggleStyle(.checkbox)
            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .tavernFont(.caption)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func setup(_ title: String, detail: String, retry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).tavernFont(.headline)
            Text(detail).tavernFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if retry {
                Button("Try again") { Task { await book.refresh() } }.buttonStyle(PillButtonStyle())
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let spellID, let spell = book.snapshot?.spell(id: spellID) {
            SpellDetail(book: book, spell: spell, document: book.document(for: spell), asOf: book.asOf, page: $page)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text(spellID.map { "\($0) isn't in the spellbook" } ?? "Select a spell").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SpellRow: View {
    let spell: Spell

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(spell.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spell.title).tavernFont(.callout, weight: .semibold).lineLimit(1)
                    if spell.isRitual { Image(systemName: "repeat").imageScale(.small).foregroundStyle(.secondary).help("Ritual") }
                }
                Text(spell.trigger).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            GateBadge(gate: spell.gate)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }
}

/// A spell's gate when it isn't "none": needs-<owner> in the Needs-you color, Blocked in red.
struct GateBadge: View {
    let gate: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if gate != "none" {
            let color: Color = gate == "needs-paul" ? .orange : gate == "blocked" ? .red : .secondary
            Text(Self.label(gate, owner: model.roster.owner))
                .tavernFont(.caption, weight: .semibold)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }

    static func label(_ gate: String, owner: String) -> String {
        switch gate {
        case "needs-paul": return "Needs \(owner)"
        case "needs-review": return "Review"
        case "blocked": return "Blocked"
        default: return gate.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

private struct SpellDetail: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    let spell: Spell
    let document: Result<SpellDocument, SpellbookError>
    let asOf: String?
    @Binding var page: Page?

    private func name(_ id: String?) -> String {
        guard let id else { return "–" }
        return model.roster.member(id: id)?.name ?? model.roster.members.first { $0.name.lowercased() == id.lowercased() }?.name ?? id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(spell.title).tavernFont(.title2, weight: .semibold)
                        GateBadge(gate: spell.gate)
                    }
                    Text(spell.trigger).foregroundStyle(.secondary)
                }

                if case .success(let document) = document {
                    if let run = book.openRun(for: spell.id) {
                        SpellRunCard(book: book, run: run)
                    } else {
                        RunButton(book: book, spell: spell, document: document)
                    }
                }
                if let error = book.runError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }

                InfoCard(title: spell.isRitual ? "Ritual" : "Spell") {
                    InfoRow(label: "ID", value: spell.citation, monospaced: true, copyable: true)
                    InfoRow(label: "Status", value: spell.lifecycle.capitalized)
                    InfoRow(label: "Owner", value: name(spell.owner))
                    InfoRow(label: "Reviewer", value: name(spell.reviewOwner))
                    InfoRow(label: "For", value: spell.appliesTo.map { $0 == "all" ? "Everyone" : name($0) }.joined(separator: ", "))
                    if let asOf { InfoRow(label: "Source", value: "\(spell.path) at \(asOf)", monospaced: true) }
                }

                switch document {
                case .success(let document):
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).tavernFont(.headline, weight: .semibold)
                            MarkdownText(text: section.body)
                        }
                    }
                case .failure(let error):
                    Label(error.description, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

/// The spells for one member, in their inspector. Each opens on the Spellbook page.
struct AgentSpellsSection: View {
    let member: RosterMember
    @ObservedObject var book: SpellbookStore

    var body: some View {
        if book.repo != nil {
            let spells = book.snapshot?.spells(for: member) ?? []
            VStack(alignment: .leading, spacing: 8) {
                Text("Spells").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                if spells.isEmpty {
                    Text(book.snapshot == nil ? "Not loaded yet." : "None for \(member.name).").tavernFont(.callout).foregroundStyle(.secondary)
                }
                ForEach(spells) { spell in
                    Button {
                        NotificationCenter.default.post(name: .tavernOpenPage, object: Page.spellbook(spell: spell.id).storageKey)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(spell.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(spell.title).tavernFont(.callout, weight: .medium).lineLimit(1)
                            Spacer(minLength: 0)
                            GateBadge(gate: spell.gate)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Starts a run for whoever the spell applies to, or for the owner. A blocked spell can't be run;
/// one gated on the owner asks first.
private struct RunButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    let spell: Spell
    let document: SpellDocument
    @State private var pendingAgent: String??

    private var members: [RosterMember] { model.roster.members.filter(spell.applies(to:)) }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("For me") { request(nil) }
                if !members.isEmpty { Divider() }
                ForEach(members) { member in
                    Button("For \(member.name)") { request(member.id) }
                }
            } label: {
                Label("Run", systemImage: "play.fill")
            } primaryAction: {
                request(nil)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(spell.gate == "blocked" || document.steps.isEmpty)
            let past = book.runs.filter { $0.spellID == spell.id }
            Text(spell.gate == "blocked" ? "Blocked: this spell can't be run yet."
                 : document.steps.isEmpty ? "No numbered steps to check off."
                 : past.first.map { "Run \(past.count)× · last \($0.startedAt.formatted(.relative(presentation: .named)))" } ?? "Turns the steps into a checklist.")
                .tavernFont(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("\(spell.citation) needs \(model.roster.owner)'s OK", isPresented: Binding(
            get: { pendingAgent != nil }, set: { if !$0 { pendingAgent = nil } }
        )) {
            Button("Start the run") {
                if let agent = pendingAgent { start(agent) }
                pendingAgent = nil
            }
        } message: {
            Text("This spell is gated on \(model.roster.owner). Start it only if you're giving that OK now.")
        }
    }

    private func request(_ agentID: String?) {
        if spell.gate == "needs-paul" { pendingAgent = .some(agentID) } else { start(agentID) }
    }

    private func start(_ agentID: String?) {
        book.startRun(spell, document: document, agentID: agentID, events: model.store)
    }
}

/// A run's checklist: tick steps by hand, then Finish. Evidence goes on the issue or thread.
private struct SpellRunCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    let run: SpellRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run · \(run.agentID.flatMap { model.roster.member(id: $0)?.name } ?? model.roster.owner)")
                    .tavernFont(.headline, weight: .semibold)
                Spacer()
                Text("\(run.checked.count)/\(run.steps.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(Array(run.steps.enumerated()), id: \.offset) { index, step in
                Button { book.toggle(index, in: run) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: run.checked.contains(index) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(run.checked.contains(index) ? Color.tavernAccent : Color.secondary)
                        Text(TranscriptRow.markdown(step))
                            .foregroundStyle(run.checked.contains(index) ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let done = run.doneWhen, !done.isEmpty {
                Text("Done when: \(done)").tavernFont(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(run.allChecked ? "Finish" : "Finish anyway") { book.finish(run) }
                    .buttonStyle(PillButtonStyle(selected: run.allChecked))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(run.citation)\(run.commit.map { " @ \($0)" } ?? "")", forType: .string)
                } label: { Label("Copy citation", systemImage: "doc.on.doc") }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                Text("Started \(run.startedAt.formatted(.relative(presentation: .named)))").tavernFont(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tavernAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.tavernAccent.opacity(0.3)))
    }
}
