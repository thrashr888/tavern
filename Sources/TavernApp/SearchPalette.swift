import AppKit
import SwiftUI
import TavernCore

/// ⌘K palette (plan 3f): scope chips All, Agents, Pi threads, Mail, Linear. Local results come from
/// the FTS5 index and work offline; Linear is live and read-only. ↵ opens in Tavern, ⌘↵ in Gmail
/// or Linear.
struct SearchPalette: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", agents = "Agents", pi = "Pi threads", mail = "Mail", linear = "Linear"
        var id: String { rawValue }
    }

    struct Result: Identifiable, Hashable {
        var id: String
        var scope: Scope
        var icon: String
        var title: String
        var detail: String
        var page: Page?
        var mailThread: String?
        var external: URL?
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Page?
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var local: [Result] = []
    @State private var linear: [Result] = []
    @State private var linearError: String?
    @State private var highlighted: Result.ID?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search agents, Pi threads, mail and Linear", text: $query)
                    .textFieldStyle(.plain)
                    .tavernFont(.title3)
                    .focused($focused)
                    .onSubmit { open(highlightedResult, external: false) }
            }
            .padding(14)

            HStack(spacing: 6) {
                ForEach(Scope.allCases) { option in
                    Button(option.rawValue) { scope = option }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(scope == option ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                    in: Capsule())
                }
                Spacer()
            }
            .tavernFont(.caption)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            List(selection: $highlighted) {
                ForEach(results) { result in
                    ResultRow(result: result)
                        .tag(result.id)
                        .onTapGesture(count: 2) { open(result, external: false) }
                }
                if let linearError, scope == .all || scope == .linear {
                    Text(linearError).tavernFont(.caption).foregroundStyle(.secondary)
                }
                if results.isEmpty && !query.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)

            Divider()
            HStack {
                Text("↵ open in Tavern · ⌘↵ open in Gmail or Linear · ↑↓ move · esc close")
                Spacer()
            }
            .tavernFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 640, height: 460)
        .background {
            Button("") { open(highlightedResult, external: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: []).opacity(0)
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: []).opacity(0)
            Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0)
        }
        .onAppear { focused = true }
        .task(id: query) { await runSearch() }
        .onChange(of: scope) { _, _ in highlighted = results.first?.id }
    }

    private var results: [Result] {
        let all = local + linear
        return scope == .all ? all : all.filter { $0.scope == scope }
    }

    private var highlightedResult: Result? {
        results.first { $0.id == highlighted } ?? results.first
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == highlighted } ?? -1
        highlighted = results[max(0, min(results.count - 1, index + step))].id
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            local = []
            linear = []
            linearError = nil
            return
        }
        local = agentResults(text) + storeResults(text)
        highlighted = results.first?.id
        // Debounce the network part.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        guard let source = model.linear else {
            linear = []
            linearError = "Linear: no key at ~/.config/linear-key"
            return
        }
        do {
            let issues = try await source.search(text)
            guard !Task.isCancelled else { return }
            linear = issues.map(Self.result(for:))
            linearError = nil
        } catch {
            guard !Task.isCancelled else { return }
            linear = []
            linearError = "Linear: \(error)"
        }
        if highlighted == nil { highlighted = results.first?.id }
    }

    private func agentResults(_ text: String) -> [Result] {
        let needle = text.lowercased()
        return model.roster.members.filter { member in
            [member.name, member.partyClass, member.animal, member.host].compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }.map { member in
            Result(
                id: "agent:\(member.id)", scope: .agents, icon: member.kind == .pi ? "cpu" : "person",
                title: member.name,
                detail: [member.partyClass, member.host, member.kind == .pi ? "Pi agent" : "mail"].compactMap { $0 }.joined(separator: " · "),
                page: member.kind == .pi ? .agent(id: member.id) : .mail(project: nil)
            )
        }
    }

    private func storeResults(_ text: String) -> [Result] {
        guard let store = model.store, let hits = try? store.search(text, limit: 40) else { return [] }
        return hits.compactMap { hit in
            let event = hit.event
            switch event.source {
            case EventSource.pi:
                let agentID = String(event.threadKey.dropFirst("pi:".count))
                let name = model.roster.member(id: agentID)?.name ?? agentID
                let who = event.authorAgent == "paul" ? model.roster.owner : name
                return Result(id: "pi:\(event.sourceID)", scope: .pi, icon: "bubble.left.and.bubble.right",
                              title: hit.snippet, detail: "\(name) · \(who) · \(event.sourceTS.formatted(.relative(presentation: .named)))",
                              page: .agent(id: agentID))
            case EventSource.gmail:
                let json = try? JSONValue.decode(event.payload)
                let threadID = json?["threadId"]?.stringValue
                return Result(id: "mail:\(event.sourceID)", scope: .mail, icon: "envelope",
                              title: json?["subject"]?.stringValue ?? "(no subject)",
                              detail: hit.snippet,
                              page: .mail(project: json?["project"]?.stringValue),
                              mailThread: threadID,
                              external: threadID.flatMap { URL(string: "https://mail.google.com/mail/u/0/#all/\($0)") })
            default:
                return nil
            }
        }
    }

    static func result(for issue: LinearIssue) -> Result {
        Result(id: "linear:\(issue.identifier)", scope: .linear, icon: "checklist",
               title: "\(issue.identifier) \(issue.title)",
               detail: [issue.state, issue.project, issue.owner].compactMap { $0 }.joined(separator: " · "),
               page: .goals, external: issue.url)
    }

    private func open(_ result: Result?, external: Bool) {
        guard let result else { return }
        if external, let url = result.external {
            NSWorkspace.shared.open(url)
        } else if let page = result.page {
            model.focusedMailThread = result.mailThread
            selection = page
        } else if let url = result.external {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }
}

private struct ResultRow: View {
    let result: SearchPalette.Result

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1)
                Text(result.detail).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(result.scope.rawValue).tavernFont(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
