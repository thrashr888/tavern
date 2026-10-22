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
    /// Runs started here, newest first (mock 2: running a spell by hand).
    @Published private(set) var runs: [SpellRun] = []
    @Published private(set) var runError: String?
    /// Spells starred on this Mac, by SB id.
    @Published private(set) var starred: Set<String> = Set(UserDefaults.standard.stringArray(forKey: SpellbookStore.starredKey) ?? [])
    /// When each spell was last cast, by an agent or a run here, by SB id.
    @Published private(set) var lastUsed: [String: Date] = [:]
    private static let starredKey = "tavern.spellbook.starred"
    private var documents: [String: SpellDocument] = [:]
    private let runStore = SpellRunStore.defaultURL().map(SpellRunStore.init(url:))

    init() { runs = runStore?.load() ?? [] }

    func toggleStar(_ id: String) {
        if starred.contains(id) { starred.remove(id) } else { starred.insert(id) }
        UserDefaults.standard.set(starred.sorted(), forKey: Self.starredKey)
    }

    /// Rereads the last year's casts from the event log, plus runs kept here.
    func refreshUsage(store: EventStore?) {
        var latest: [String: Date] = [:]
        let casts = store.map { SpellCast.recent(store: $0, since: Date().addingTimeInterval(-365 * 86_400)) } ?? []
        for cast in casts {
            let id = spell(cast.spell)?.id ?? cast.spell
            latest[id] = max(latest[id] ?? .distantPast, cast.date)
        }
        for run in runs { latest[run.spellID] = max(latest[run.spellID] ?? .distantPast, run.startedAt) }
        if latest != lastUsed { lastUsed = latest }
    }

    /// The newest unfinished run of a spell.
    func openRun(for spellID: String) -> SpellRun? { runs.first { $0.spellID == spellID && !$0.isFinished } }
    func run(id: String) -> SpellRun? { runs.first { $0.id == id } }
    func runs(of spellID: String) -> [SpellRun] { runs.filter { $0.spellID == spellID } }

    /// The spell a spell's steps hand off to, when it's in the spellbook and readable.
    func chained(after spell: Spell, document: SpellDocument) -> (Spell, SpellDocument)? {
        guard let id = document.chainedSpell(from: spell.id), let next = snapshot?.spell(id: id),
              case .success(let nextDocument) = self.document(for: next), !nextDocument.steps.isEmpty else { return nil }
        return (next, nextDocument)
    }

    /// Starts a checklist from the spell's steps (and the spell it chains into), and logs the start
    /// so it counts as a cast. Returns the run's id.
    @discardableResult
    func startRun(_ spell: Spell, document: SpellDocument, chain: Bool, agentID: String?, issue: String?, message: String? = nil,
                  events: EventStore?) -> String {
        var parts = [SpellRun.Part(spell: spell, document: document)]
        if chain, let (next, nextDocument) = chained(after: spell, document: document) {
            parts.append(SpellRun.Part(spell: next, document: nextDocument))
        }
        let run = SpellRun(parts: parts, commit: snapshot?.commit, agentID: agentID, issue: issue, message: message)
        save(run)
        _ = try? events?.append([run.startEvent])
        return run.id
    }

    func save(_ run: SpellRun) {
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

    /// "abc1234 · 2h ago": the commit the spells came from.
    var asOf: String? {
        guard let commit = snapshot?.commit else { return nil }
        let short = String(commit.prefix(7))
        guard let date = snapshot?.committedAt else { return short }
        return "\(short) · \(date.formatted(.relative(presentation: .named)))"
    }

    func fileURL(for spell: Spell) -> URL? { repo?.directory.appendingPathComponent(spell.path) }

    /// The spell's history on GitHub, when the repo is a GitHub URL.
    func historyURL(for spell: Spell) -> URL? {
        guard let source = repo?.source, source.repo.hasPrefix("https://github.com/") else { return nil }
        let base = source.repo.hasSuffix(".git") ? String(source.repo.dropLast(4)) : source.repo
        return URL(string: "\(base)/commits/\(source.branch ?? "HEAD")/\(spell.path)")
    }

    /// Finds a spell by id or by name (`spellbook_get` calls can use either).
    func spell(_ key: String) -> Spell? { snapshot?.spells.first { $0.id == key || $0.name == key } }
}

/// Spells, read-only (mock 1), laid out like Goals: filters with counts (type, lifecycle, gate,
/// owner), the matching spells by lifecycle, and the open spell. Pages restore by SB id.
struct SpellbookView: View {
    enum Filter: Hashable {
        case all
        case kind(String)
        case lifecycle(String)
        case gate(String)
        case owner(String)
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    @Binding var page: Page?
    let spellID: String?
    enum Sort: String, CaseIterable {
        case lifecycle = "Lifecycle", lastUsed = "Last used", name = "Name"
    }

    @State private var filter: Filter? = .all
    @AppStorage("tavern.spellbook.sort") private var sort: Sort = .lifecycle
    @State private var query = ""
    /// A decision model's pick for a filter that reads like a task ("draft the weekly update").
    @State private var suggested: (id: String, probability: Double)?

    private var selection: Binding<String?> {
        Binding(get: { spellID }, set: { id in page = .spellbook(spell: id) })
    }

    var body: some View {
        Group {
            if book.repo == nil {
                note("No spellbook yet", "Add \"spellbookRepo\" (a git URL) to roster.json in Settings, and Tavern keeps a read-only copy.")
            } else if book.snapshot == nil, let error = book.error {
                VStack(spacing: 10) {
                    note("Couldn't get the spellbook", "\(error)\n\nTavern runs: \(book.repo?.cloneCommand ?? "")")
                    Button("Try again") { Task { await book.refresh() } }.buttonStyle(PillButtonStyle())
                }
                .padding(.bottom, 40)
            } else if book.snapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    filters.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                    spellList.frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                    detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Spellbook")
        .onReceive(NotificationCenter.default.publisher(for: .tavernRefresh)) { _ in Task { await book.refresh() } }
        .task(id: query) { await suggest() }
        .task {
            while !Task.isCancelled {
                book.refreshUsage(store: model.store)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Filters

    private var all: [Spell] { book.snapshot?.spells ?? [] }
    private var current: [Spell] { all.filter { !$0.isRetired } }

    private var filters: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(book.asOf.map { "@ \($0)" } ?? "").tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if book.syncing { ProgressView().controlSize(.small) }
                Button { Task { await book.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Pull the spellbook")
                    .disabled(book.syncing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $filter) {
                row("All spells", count: current.count).themedTag(Filter.all, selection: filter)
                Section("Type") {
                    row("Spells", count: current.filter { !$0.isRitual }.count).themedTag(Filter.kind("spell"), selection: filter)
                    row("Rituals", count: current.filter(\.isRitual).count).themedTag(Filter.kind("ritual"), selection: filter)
                }
                Section("Lifecycle") {
                    ForEach(["live", "proposal", "retired"], id: \.self) { lifecycle in
                        row(lifecycle.capitalized, count: all.filter { $0.lifecycle == lifecycle }.count)
                            .themedTag(Filter.lifecycle(lifecycle), selection: filter)
                    }
                }
                Section("Gate") {
                    ForEach(["needs-paul", "needs-review", "blocked"], id: \.self) { gate in
                        row(SpellPill.gateLabel(gate, owner: model.roster.owner), count: current.filter { $0.gate == gate }.count)
                            .themedTag(Filter.gate(gate), selection: filter)
                    }
                }
                Section("Owner") {
                    ForEach(owners, id: \.name) { item in
                        row(memberName(item.name), count: item.count).themedTag(Filter.owner(item.name), selection: filter)
                    }
                }
            }
            .listStyle(.sidebar)
            .themedList()
        }
    }

    private var owners: [(name: String, count: Int)] {
        Dictionary(grouping: current.compactMap(\.owner), by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func memberName(_ id: String) -> String {
        model.roster.member(id: id)?.name ?? model.roster.members.first { $0.name.lowercased() == id.lowercased() }?.name ?? id.capitalized
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            CountBadge(count: count)
        }
        .padding(.vertical, 2)
    }

    // MARK: Spells

    private var shown: [Spell] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool: [Spell]
        switch filter ?? .all {
        case .all: pool = current
        case .kind(let kind): pool = current.filter { $0.kind == kind }
        case .lifecycle(let lifecycle): pool = all.filter { $0.lifecycle == lifecycle }
        case .gate(let gate): pool = current.filter { $0.gate == gate }
        case .owner(let owner): pool = current.filter { $0.owner == owner }
        }
        guard !q.isEmpty else { return pool }
        return pool.filter { spell in
            spell.id.lowercased() == q || spell.id.lowercased().hasSuffix("-\(q)") || spell.title.lowercased().contains(q)
                || spell.description.lowercased().contains(q)
        }
    }

    private static let groups = ["live", "proposal", "retired"]

    private var spellList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter spells, or describe a task", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            HStack {
                Text("\(shown.count) spells").tavernFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .tavernFont(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            if let suggested, let spell = book.snapshot?.spell(id: suggested.id) {
                HStack(spacing: 6) {
                    Text("Fits:").tavernFont(.caption).foregroundStyle(.secondary)
                    SuggestionChip(label: "Spell", value: "\(spell.id) \(spell.title)", confidence: suggested.probability) {
                        page = .spellbook(spell: spell.id)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            if let error = book.error {
                Label("Showing the last copy: \(error)", systemImage: "exclamationmark.triangle")
                    .tavernFont(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            List(selection: selection) {
                let shown = self.shown
                let stars = shown.filter { book.starred.contains($0.id) }
                let rest = shown.filter { !book.starred.contains($0.id) }
                if !stars.isEmpty {
                    Section("Starred") { ForEach(sorted(stars)) { row($0) } }
                }
                switch sort {
                case .lifecycle:
                    ForEach(Self.groups, id: \.self) { lifecycle in
                        let group = rest.filter { $0.lifecycle == lifecycle }
                        if !group.isEmpty {
                            Section(lifecycle.capitalized) { ForEach(group) { row($0) } }
                        }
                    }
                    // Lifecycles a newer repo adds still show.
                    let other = rest.filter { !Self.groups.contains($0.lifecycle) }
                    if !other.isEmpty {
                        Section("Other") { ForEach(other) { row($0) } }
                    }
                case .lastUsed, .name:
                    if !rest.isEmpty {
                        Section(stars.isEmpty ? "" : "All") { ForEach(sorted(rest)) { row($0) } }
                    }
                }
                if shown.isEmpty { Text("No matches").tavernFont(.caption).foregroundStyle(.tertiary) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ spell: Spell) -> some View {
        SpellRow(spell: spell, owner: spell.owner.map(memberName), starred: book.starred.contains(spell.id),
                 lastUsed: sort == .lastUsed ? book.lastUsed[spell.id] : nil, showLastUsed: sort == .lastUsed) {
            book.toggleStar(spell.id)
        }
        .themedTag(spell.id, selection: spellID)
    }

    /// Newest cast first (never-cast spells after, by number), or by title; lifecycle keeps index order.
    private func sorted(_ spells: [Spell]) -> [Spell] {
        switch sort {
        case .lifecycle: return spells
        case .name: return spells.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastUsed:
            return spells.enumerated().sorted { a, b in
                let x = book.lastUsed[a.element.id] ?? .distantPast, y = book.lastUsed[b.element.id] ?? .distantPast
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        }
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
              !Task.isCancelled, let pick = DecisionSuggestions.spell(from: answers) else { return }
        let probability = answers.values.compactMap { answer -> Double? in
            guard case .choice(let key, let probabilities, _) = answer, key == pick.id else { return nil }
            return probabilities[key]
        }.max() ?? pick.confidence
        suggested = (pick.id, probability)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let spellID, let spell = book.snapshot?.spell(id: spellID) {
            SpellDetail(book: book, spell: spell, document: book.document(for: spell)).id(spell.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text(spellID.map { "\($0) isn't in the spellbook" } ?? "Select a spell").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).tavernFont(.title2, weight: .semibold)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Title, then "SB-20 · Wololo" and the spell's pills: Ritual, its lifecycle, its gate.
private struct SpellRow: View {
    let spell: Spell
    let owner: String?
    var starred = false
    var lastUsed: Date? = nil
    var showLastUsed = false
    var toggleStar: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(spell.title).tavernFont(.body, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    if showLastUsed {
                        Text(lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
                            .tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(spell.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if let owner { Text("· \(owner)").tavernFont(.caption).foregroundStyle(.secondary) }
                    SpellPills(spell: spell)
                }
            }
            StarButton(starred: starred, toggle: toggleStar)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

/// Star or unstar a spell; starred spells sit at the top of the list.
struct StarButton: View {
    let starred: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(starred ? "Unstar" : "Star")
    }
}

/// An outlined capsule: Ritual, Live, Proposal, Needs review, Needs <owner>, Blocked.
struct SpellPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .tavernFont(.caption, weight: .medium)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(Capsule().strokeBorder(color.opacity(0.8)))
    }

    static func gateLabel(_ gate: String, owner: String) -> String {
        switch gate {
        case "needs-paul": return "Needs \(owner)"
        case "needs-review": return "Needs review"
        case "blocked": return "Blocked"
        default: return gate.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func lifecycleColor(_ lifecycle: String) -> Color { lifecycle == "live" ? .green : .secondary }

    static func gateColor(_ gate: String) -> Color {
        switch gate {
        case "needs-paul", "blocked": return .red
        case "needs-review": return .orange
        default: return .secondary
        }
    }
}

struct SpellPills: View {
    let spell: Spell
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            if spell.isRitual { SpellPill(text: "Ritual", color: .tavernAccent) }
            SpellPill(text: spell.lifecycle.capitalized, color: SpellPill.lifecycleColor(spell.lifecycle))
            if spell.gate != "none" {
                SpellPill(text: SpellPill.gateLabel(spell.gate, owner: model.roster.owner), color: SpellPill.gateColor(spell.gate))
            }
        }
    }
}

/// A filled accent capsule, for the one primary action (Start run…).
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tavernFont(.callout, weight: .semibold)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .foregroundStyle(.white)
            .background(Color.tavernAccent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// One spell (mock 1): who and what it is, the actions, its facts, its steps, its permissions kept
/// apart from the steps, and where the text came from.
private struct SpellDetail: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var book: SpellbookStore
    let spell: Spell
    let document: Result<SpellDocument, SpellbookError>
    @State private var running = false
    @State private var lastCast: Date?

    private func name(_ id: String?) -> String {
        guard let id else { return "–" }
        return model.roster.member(id: id)?.name ?? model.roster.members.first { $0.name.lowercased() == id.lowercased() }?.name ?? id.capitalized
    }

    /// Sections shown in their own places; anything else follows Permissions as written.
    private static let placed: Set<String> = ["when to use", "inputs", "done when", "tools", "steps", "permissions"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text([spell.id, "v\(spell.version)", spell.isRitual ? "Ritual" : "Spell", "owner \(name(spell.owner))",
                      "reviewed by \(name(spell.reviewOwner))"].joined(separator: " · "))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(spell.title).tavernFont(.title, weight: .bold)
                    StarButton(starred: book.starred.contains(spell.id)) { book.toggleStar(spell.id) }.font(.title3)
                }
                HStack(spacing: 6) {
                    SpellPills(spell: spell)
                    Text("For \(spell.appliesTo.map { $0 == "all" ? "everyone" : name($0) }.joined(separator: ", "))")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
                actions
                if let error = book.runError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }

                switch document {
                case .success(let document):
                    facts(document)
                    if !document.steps.isEmpty { steps(document) }
                    if let permissions = document.section("Permissions") { permissionsBox(permissions.body) }
                    ForEach(Array(document.sections.filter { !Self.placed.contains($0.title.lowercased()) }.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).tavernFont(.headline, weight: .semibold)
                            MarkdownText(text: section.body).tavernFont(.callout)
                        }
                    }
                case .failure(let error):
                    Label(error.description, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }

                Text(footer).tavernFont(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .sheet(isPresented: $running) {
            if case .success(let document) = document {
                SpellRunSheet(book: book, spell: spell, document: document, runID: book.openRun(for: spell.id)?.id)
                    .environmentObject(model)
            }
        }
        .task(id: spell.id) {
            guard let store = model.store else { return }
            lastCast = SpellCast.recent(store: store, since: Date().addingTimeInterval(-90 * 86_400))
                .first { $0.spell == spell.id || $0.spell == spell.name }?.date
        }
    }

    private var hasSteps: Bool {
        if case .success(let document) = document { return !document.steps.isEmpty }
        return false
    }

    private var actions: some View {
        HStack(spacing: 8) {
            let open = book.openRun(for: spell.id)
            Button(open == nil ? "Cast…" : "Continue cast (\(open!.checkedCount)/\(open!.stepCount))") { running = true }
                .buttonStyle(PrimaryPillStyle())
                .disabled(spell.gate == "blocked" || !hasSteps)
                .help(spell.gate == "blocked" ? "Blocked: this spell can't be cast yet" : "Cast it yourself as a checklist, or send it to an agent")
            if let url = book.fileURL(for: spell) {
                Button("Open SKILL.md") { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle())
            }
            if let url = book.historyURL(for: spell) {
                Button("History") { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle()).help(url.absoluteString)
            }
        }
    }

    private func facts(_ document: SpellDocument) -> some View {
        let rows: [(String, String)] = [
            ("When", document.section("When to use")?.body ?? spell.trigger),
            ("Inputs", document.section("Inputs")?.body ?? ""),
            ("Done when", document.section("Done when")?.body ?? ""),
            ("Tools", document.section("Tools")?.body ?? ""),
        ].filter { !$0.1.isEmpty }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    Text(TranscriptRow.markdown(row.1)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .tavernFont(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func steps(_ document: SpellDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps").tavernFont(.headline, weight: .semibold)
            ForEach(Array(document.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                    Text(TranscriptRow.markdown(step)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .tavernFont(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionsBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions (separate from steps)").tavernFont(.headline, weight: .semibold).foregroundStyle(.red)
            Text(TranscriptRow.markdown(text)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .tavernFont(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.7), lineWidth: 1.5))
    }

    /// "Source: spellbook @ 4e1c9a2 · as of 6:02 PM · Last used: none yet · Next review: Fri Oct 23".
    private var footer: String {
        var parts = ["Source: spellbook @ \(book.snapshot?.commit ?? "?")"]
        if let at = book.refreshedAt { parts.append("as of \(at.formatted(date: .omitted, time: .shortened))") }
        let local = book.runs(of: spell.id).first?.startedAt
        let used = [lastCast, local, book.lastUsed[spell.id]].compactMap { $0 }.max()
        parts.append("Last used: \(used.map { $0.formatted(.relative(presentation: .named)) } ?? "none yet")")
        parts.append("Next review: \(Self.nextFriday().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        return parts.joined(separator: " · ")
    }

    /// The Friday review this spell next comes up in.
    static func nextFriday(after date: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime) ?? date
    }
}

/// Running a spell by hand (mock 2). Before it starts: who it's for, the Linear issue, and whether
/// to carry on into the spell it hands off to. Then each spell's steps take a tick and a note or
/// evidence link. Tavern keeps the record and sends nothing.
private struct SpellRunSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var book: SpellbookStore
    let spell: Spell
    let document: SpellDocument
    @State var runID: String?
    @State private var agentID: String?
    @State private var issue: String?
    @State private var chain = true
    @State private var message = ""
    @State private var confirmGate = false

    var body: some View {
        Group {
            if let runID, let run = book.run(id: runID) {
                checklist(run)
            } else {
                start
            }
        }
        .themedSurface()
        .task { _ = try? await model.loadOpenIssues() }
    }

    // MARK: Start

    private var members: [RosterMember] { model.roster.members.filter(spell.applies(to:)) }

    private var start: some View {
        let next = book.chained(after: spell, document: document)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Cast · \(spell.id) \(spell.title)").tavernFont(.title3, weight: .semibold)
            VStack(alignment: .leading, spacing: 8) {
                Text("Who casts it").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    Button { agentID = nil } label: { Label("Myself, as a checklist", systemImage: "checklist") }
                        .buttonStyle(PillButtonStyle(selected: agentID == nil))
                    ForEach(members) { member in
                        Button { agentID = member.id } label: {
                            HStack(spacing: 6) { AvatarView(member: member, size: 20, hoverCard: false); Text(member.name) }
                        }
                        .buttonStyle(PillButtonStyle(selected: agentID == member.id))
                    }
                }
            }
            Picker("Issue", selection: $issue) {
                Text("No issue").tag(String?.none)
                ForEach(model.openIssues) { Text("\($0.identifier) \($0.title)").tag(Optional($0.identifier)) }
            }
            if let (next, _) = next {
                Toggle("Then \(next.id) \(next.title)", isOn: $chain)
            }
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Add a message (optional)").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
            if let member = agent, !sending {
                Text("\(member.name) isn't connected, so this keeps a checklist here for you to tick off.")
                    .tavernFont(.caption).foregroundStyle(.orange)
            }
            if spell.gate == "needs-paul" {
                Label("Gated on \(model.roster.owner): start it only if you're giving that OK now.", systemImage: "hand.raised")
                    .tavernFont(.callout).foregroundStyle(.red)
            }
            HStack {
                Text(sending ? "\(agent?.name ?? "") gets the spell and your message in its thread and does the steps." : "You tick the steps off here. Tavern sends nothing.")
                    .tavernFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Cast") { cast() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var agent: RosterMember? { agentID.flatMap { model.roster.member(id: $0) } }

    private var sending: Bool {
        guard let agent, agent.kind == .pi else { return false }
        return model.session(for: agent.id) != nil
    }

    /// Keeps the record; sent to an agent, the agent does the steps and the sheet closes.
    private func cast() {
        let id = book.startRun(spell, document: document, chain: chain, agentID: agentID, issue: issue, message: message, events: model.store)
        guard sending, let agentID, let session = model.session(for: agentID), let run = book.run(id: id) else {
            runID = id
            return
        }
        Task { await session.send(run.agentPrompt) }
        dismiss()
    }

    // MARK: Checklist

    private func checklist(_ run: SpellRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cast · \(run.parts.first.map { "\($0.spellID) \($0.title)" } ?? "")\(run.issue.map { " · \($0)" } ?? "")")
                .tavernFont(.title3, weight: .semibold)
                .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(run.parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Divider() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(index == 0 ? header(run) : "Then · \(part.spellID) \(part.title) · v\(part.version)")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            if index == 0, let message = run.message {
                                Text(TranscriptRow.markdown(message)).tavernFont(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(Array(part.steps.enumerated()), id: \.offset) { step, text in
                                StepCheck(text: text, checked: part.checked.contains(step), note: noteBinding(run, part: index, step: step)) {
                                    var run = run
                                    run.parts[index].toggle(step)
                                    book.save(run)
                                }
                            }
                            if let done = part.doneWhen, !done.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Done when").tavernFont(.caption, weight: .semibold)
                                    Text(TranscriptRow.markdown(done)).tavernFont(.callout).foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if index == run.parts.count - 1 { buttons(run) }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if run.parts.count == 1 {
                    // Keep the two-column shape: the right side holds the outcome actions.
                    EmptyView()
                }
            }
            Divider()
            Text("The record stays in Tavern. Tavern doesn't post, send or edit Linear for this cast.")
                .tavernFont(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(width: run.parts.count > 1 ? 980 : 600, height: 560)
    }

    private func header(_ run: SpellRun) -> String {
        let number = book.runs(of: run.spellID).reversed().firstIndex { $0.id == run.id }.map { $0 + 1 } ?? 1
        let who = run.agentID.flatMap { model.roster.member(id: $0)?.name } ?? model.roster.owner
        return (["Cast \(number)", "by \(who)", run.startedAt.formatted(date: .omitted, time: .shortened)]
            + (run.issue.map { ["issue \($0)"] } ?? [])).joined(separator: " · ")
    }

    private func noteBinding(_ run: SpellRun, part: Int, step: Int) -> Binding<String> {
        Binding(
            get: { book.run(id: run.id).flatMap { $0.parts[part].notes.indices.contains(step) ? $0.parts[part].notes[step] : nil } ?? "" },
            set: { value in
                guard var latest = book.run(id: run.id) else { return }
                latest.parts[part].setNote(value, for: step)
                book.save(latest)
            }
        )
    }

    private func buttons(_ run: SpellRun) -> some View {
        HStack(spacing: 8) {
            Button("Save and close") { dismiss() }.buttonStyle(PillButtonStyle())
            Button("Copy run summary") {
                NSPasteboard.general.clearContents()
                let who = run.agentID.flatMap { model.roster.member(id: $0)?.name } ?? model.roster.owner
                NSPasteboard.general.setString(run.summary(by: who), forType: .string)
            }
            .buttonStyle(PillButtonStyle())
            Button(run.allChecked ? "Finish" : "Finish anyway") {
                var run = run
                run.finishedAt = Date()
                book.save(run)
                dismiss()
            }
            .buttonStyle(PillButtonStyle(selected: run.allChecked))
        }
        .padding(.top, 4)
    }
}

/// A step: a tick box, its text, and a note or evidence link under it.
private struct StepCheck: View {
    let text: String
    let checked: Bool
    @Binding var note: String
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.green : Color.secondary)
                        .imageScale(.large)
                    Text(TranscriptRow.markdown(text)).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TextField("Add a note or link", text: $note)
                .textFieldStyle(.plain)
                .tavernFont(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                .padding(.leading, 30)
        }
    }
}

/// What an agent has cast lately (its info panel's Activity tab): each spell, how often, when last.
struct AgentSpellCasts: View {
    let member: RosterMember
    @ObservedObject var book: SpellbookStore
    @EnvironmentObject private var model: AppModel
    @State private var casts: [SpellCast] = []

    private var grouped: [(spell: String, count: Int, last: Date)] {
        Dictionary(grouping: casts, by: { book.spell($0.spell)?.id ?? $0.spell })
            .map { (spell: $0.key, count: $0.value.count, last: $0.value.map(\.date).max() ?? .distantPast) }
            .sorted { $0.last > $1.last }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spells cast · 30 days").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if casts.isEmpty {
                Text("None yet.").tavernFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(grouped, id: \.spell) { item in
                Button {
                    NotificationCenter.default.post(name: .tavernOpenPage, object: Page.spellbook(spell: book.spell(item.spell)?.id ?? item.spell).storageKey)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "book.closed").foregroundStyle(Color.tavernAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.spell(item.spell).map { "\($0.id) \($0.title)" } ?? item.spell)
                                .tavernFont(.callout, weight: .medium).lineLimit(1)
                            Text("\(item.count)× · last \(item.last.formatted(.relative(presentation: .named)))")
                                .tavernFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: member.id) {
            while !Task.isCancelled {
                if let store = model.store {
                    casts = SpellCast.recent(store: store, agentID: member.id, since: Date().addingTimeInterval(-30 * 86_400))
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// The spells for one member (their info panel's About tab). Each opens on the Spellbook page.
struct AgentSpellsSection: View {
    let member: RosterMember
    @ObservedObject var book: SpellbookStore

    var body: some View {
        if book.repo != nil {
            let spells = book.snapshot?.spells(for: member) ?? []
            VStack(alignment: .leading, spacing: 8) {
                Text("Spells for \(member.name)").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                if spells.isEmpty {
                    Text(book.snapshot == nil ? "Not loaded yet." : "None.").tavernFont(.callout).foregroundStyle(.secondary)
                }
                ForEach(spells) { spell in
                    Button {
                        NotificationCenter.default.post(name: .tavernOpenPage, object: Page.spellbook(spell: spell.id).storageKey)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(spell.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(spell.title).tavernFont(.callout, weight: .medium).lineLimit(1)
                            Spacer(minLength: 0)
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

/// A spell an agent cast, inline in its chat: the spell's name, id and version, and its trigger,
/// in the accent color, so it stands out from ordinary tool steps. Opens the spell.
struct SpellCastCard: View {
    let spell: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let found = model.spellbook.spell(spell)
        Button {
            NotificationCenter.default.post(name: .tavernOpenPage, object: Page.spellbook(spell: found?.id ?? spell).storageKey)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.tavernAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.tavernAccent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Cast").tavernFont(.caption, weight: .semibold).foregroundStyle(Color.tavernAccent)
                        Text(found.map(\.citation) ?? spell).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(found?.title ?? spell).tavernFont(.body, weight: .semibold)
                    if let found { Text(found.trigger).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.tavernAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.tavernAccent.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Open \(found?.id ?? spell) in the Spellbook")
    }
}
