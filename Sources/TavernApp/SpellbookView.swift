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
    private var documents: [String: SpellDocument] = [:]

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
            SpellDetail(spell: spell, document: book.document(for: spell), asOf: book.asOf, page: $page)
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
