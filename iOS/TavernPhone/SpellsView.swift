import SwiftUI
import TavernCore

/// The spellbook as of the build: search it, read a spell, and cast it on an agent, which sends
/// the same message the Mac does (read it with spellbook_get, follow it, cite the version).
struct SpellsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var query = ""
    @State private var starredOnly = false
    @State private var kind = Kind.all
    @State private var owner: String?

    enum Kind: String, CaseIterable { case all = "All", spells = "Spells", rituals = "Rituals" }

    var body: some View {
        Group {
            if let book = Party.spellbook {
                let shown = filtered(book.spells)
                List(shown) { spell in
                    NavigationLink(value: spell.id) { SpellRow(spell: spell) }
                }
                .overlay { if shown.isEmpty { ContentUnavailableView.search } }
                .searchable(text: $query, prompt: "Search spells")
                .navigationDestination(for: String.self) { id in
                    if let spell = book.spell(id: id) { SpellDetail(spell: spell, commit: book.commit) }
                }
                .toolbar { filters(owners: Set(relevant(book.spells).compactMap(\.owner)).sorted()) }
            } else {
                ContentUnavailableView("No spellbook in this build", systemImage: "book.closed",
                                       description: Text("scripts/phone.sh copies it from the Mac's Tavern folder."))
            }
        }
        .navigationTitle("Spells")
    }

    /// The Mac's Spellbook filters: starred, spells or rituals, and owner.
    private func filters(owners: [String]) -> some ToolbarContent {
        ToolbarItem {
            Menu {
                Toggle("Starred", systemImage: "star", isOn: $starredOnly)
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Owner", selection: $owner) {
                    Text("Anyone").tag(String?.none)
                    ForEach(owners, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
            } label: {
                Label("Filter", systemImage: starredOnly || kind != .all || owner != nil
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
    }

    /// Spells for the agents on this phone (applies to "all" or one of them), retired ones out.
    private func relevant(_ spells: [Spell]) -> [Spell] {
        let here = Set(model.agents.flatMap { [$0.id.lowercased(), $0.name.lowercased()] })
        return spells.filter { spell in
            !spell.isRetired && spell.appliesTo.contains { $0.lowercased() == "all" || here.contains($0.lowercased()) }
        }
    }

    /// The filters and every word of the search (id, title or trigger); Paul's starred spells first.
    private func filtered(_ spells: [Spell]) -> [Spell] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let stars = Party.info.spellbookStars ?? []
        return relevant(spells)
            .filter { !starredOnly || stars.contains($0.id) }
            .filter { kind == .all || (kind == .rituals) == $0.isRitual }
            .filter { owner == nil || $0.owner == owner }
            .filter { spell in
                let text = "\(spell.id) \(spell.title) \(spell.description)".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { (stars.firstIndex(of: $0.id) ?? .max, $0.number) < (stars.firstIndex(of: $1.id) ?? .max, $1.number) }
    }
}

private struct SpellRow: View {
    let spell: Spell

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(spell.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if spell.isRitual { Text("Ritual").font(.caption2.weight(.semibold)).foregroundStyle(Color.tavernAccent) }
                if Party.info.spellbookStars?.contains(spell.id) == true {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.tavernAccent)
                }
            }
            Text(spell.title).font(.headline)
            Text(spell.trigger).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct SpellDetail: View {
    let spell: Spell
    let commit: String?
    @EnvironmentObject private var model: PhoneModel
    @State private var casting = false

    var body: some View {
        let document = Party.document(for: spell)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(spell.citation)\(spell.owner.map { " · \($0)" } ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(spell.trigger).foregroundStyle(.secondary)
                if let document {
                    if !document.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Steps").font(.headline)
                            ForEach(Array(document.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                                    MarkdownView(text: step)
                                }
                            }
                        }
                    }
                    if let done = document.section("Done when") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Done when").font(.headline)
                            MarkdownView(text: done.body)
                        }
                    }
                } else {
                    Text("This spell's text isn't in the build.").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(spell.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { casting = true } label: { Label("Cast", systemImage: "sparkles") }
                .disabled(document == nil || model.agents.isEmpty)
        }
        .sheet(isPresented: $casting) {
            if let document { CastSheet(spell: spell, document: document, commit: commit).environmentObject(model) }
        }
    }
}

/// Who casts it, and a note; sends the Mac's cast message into that agent's thread.
private struct CastSheet: View {
    let spell: Spell
    let document: SpellDocument
    let commit: String?
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var agentID = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agentID) {
                    ForEach(model.agents) { Text($0.name).tag($0.id) }
                }
                TextField("Anything to add (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                Section {
                    Text(run.agentPrompt).font(.footnote).foregroundStyle(.secondary)
                } header: { Text("They'll get") }
            }
            .navigationTitle("Cast \(spell.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cast") {
                        if let agent = model.agents.first(where: { $0.id == agentID }), let session = model.session(for: agent) {
                            let prompt = run.agentPrompt
                            Task { await session.send(prompt) }
                        }
                        dismiss()
                    }
                    .disabled(model.agents.first(where: { $0.id == agentID }).flatMap(model.session(for:)) == nil)
                }
            }
            .onAppear { if agentID.isEmpty { agentID = model.agents.first?.id ?? "" } }
        }
        .presentationDetents([.medium, .large])
    }

    private var run: SpellRun {
        SpellRun(spell: spell, document: document, commit: commit, agentID: agentID, message: note)
    }
}
