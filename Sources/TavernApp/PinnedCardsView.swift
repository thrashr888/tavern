import SwiftUI
import TavernCore

@MainActor
final class PinnedCards: ObservableObject {
    static let shared = PinnedCards()
    @Published private(set) var pins: [PinnedCard] = []
    @Published var error: String?
    private let url = TavernPaths.file("pinned-cards.json")
    private var loaded = false
    private init() {
        do {
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            pins = try PinnedCardFile.load(from: url)
            loaded = true
        } catch { self.error = "Couldn't load pinned widgets. Your saved pins have not been changed." }
    }
    func contains(_ pin: PinnedCard) -> Bool { pins.contains { $0.id == pin.id } }
    func toggle(_ pin: PinnedCard) {
        guard loaded, let url else { return }
        let next = contains(pin) ? pins.filter { $0.id != pin.id } : pins + [pin]
        do { try PinnedCardFile.save(next, to: url); pins = next; error = nil }
        catch { self.error = "Couldn't save pinned widgets. Try again." }
    }
}

struct PinnableCardView: View {
    let card: ToolCard
    let rowID: String
    var projectID: String? = nil
    var onPin: (() -> Void)? = nil
    @ObservedObject var session: PiAgentSession
    @ObservedObject private var pins = PinnedCards.shared

    var body: some View {
        let snapshot = PinnedCard(agentID: session.agentID, rowID: rowID, projectID: projectID)
        let live = PinnedCard(following: card, agentID: session.agentID, rowID: rowID, projectID: projectID)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Widget", systemImage: "rectangle.on.rectangle")
                    .tavernFont(.caption).foregroundStyle(.secondary)
                Spacer()
                pinButton(snapshot, label: live == nil ? "Pin" : "Pin snapshot", unpinLabel: live == nil ? "Unpin" : "Unpin snapshot",
                          help: "Keep this exact result in the sidebar")
                if let live {
                    pinButton(live, label: "Pin live", unpinLabel: "Unpin live",
                              help: "Follow newer revisions of this widget from this agent")
                }
            }
            ToolCardView(card: card, session: session)
            if let error = pins.error { Text(error).foregroundStyle(.red).tavernFont(.caption) }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .contextMenu {
            Button(pins.contains(snapshot) ? "Unpin snapshot" : "Pin snapshot") { toggle(snapshot) }
            if let live {
                Button(pins.contains(live) ? "Unpin live widget" : "Pin live widget") { toggle(live) }
            }
        }
    }

    private func toggle(_ pin: PinnedCard) {
        let adding = !pins.contains(pin)
        pins.toggle(pin)
        if adding, pins.contains(pin) { onPin?() }
    }

    private func pinButton(_ pin: PinnedCard, label: String, unpinLabel: String, help: String) -> some View {
        Button { toggle(pin) } label: {
            Label(pins.contains(pin) ? unpinLabel : label, systemImage: pins.contains(pin) ? "pin.slash" : "pin")
        }
        .buttonStyle(.borderless).tavernFont(.caption)
        .help(pins.contains(pin) ? "Remove from sidebar" : help)
    }
}

/// Uses the saved pin's identity, not the newest result's row, so Unpin also works after an update.
private struct SavedPinnedCardView: View {
    let pin: PinnedCard
    let card: ToolCard
    @ObservedObject var session: PiAgentSession
    @ObservedObject private var pins = PinnedCards.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if pin.live != nil, let revision = card.widgetRevision?.revision {
                    Label("Live · revision \(revision)", systemImage: "arrow.triangle.2.circlepath")
                        .help("Updates when this agent publishes a newer revision. No tools run automatically.")
                } else {
                    Label("Snapshot", systemImage: "pin")
                }
                Spacer()
                Button("Unpin") { pins.toggle(pin) }.buttonStyle(.borderless)
            }
            .tavernFont(.caption).foregroundStyle(.secondary)
            ToolCardView(card: card, session: session)
            if let error = pins.error { Text(error).foregroundStyle(.red).tavernFont(.caption) }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct PinnedCardsSection: View {
    @ObservedObject var session: PiAgentSession
    @ObservedObject private var pins = PinnedCards.shared
    var body: some View {
        let selected = pins.pins.filter { $0.agentID == session.agentID && $0.projectID == nil }
        if !selected.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pinned", systemImage: "pin").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                PinnedSessionWidgets(session: session, selected: selected)
            }
        }
    }
}

/// A permanent sidebar destination, including before the first widget is pinned.
struct PinnedWidgetsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var pins = PinnedCards.shared
    @Binding var selection: Page?

    private var agentIDs: [String] {
        let saved = Set(pins.pins.map(\.agentID))
        let known = model.roster.members.map(\.id).filter { saved.contains($0) }
        return known + saved.subtracting(known).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Pinned widgets", systemImage: "pin")
                    .tavernFont(.title, weight: .semibold)
                Text("Choose Pin above an inline card to keep it here. Pin live follows updates when the widget supports them.")
                    .tavernFont(.body).foregroundStyle(.secondary)
                if let error = pins.error {
                    Text(error).tavernFont(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            Divider()
            if pins.pins.isEmpty {
                ContentUnavailableView {
                    Label("No pinned widgets yet", systemImage: "pin")
                } description: {
                    Text("Open an agent conversation and choose Pin above a weather, calendar, or other inline card. Saved widgets from every agent appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(agentIDs, id: \.self) { agentID in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(model.roster.member(id: agentID)?.name ?? agentID)
                                        .tavernFont(.headline, weight: .semibold)
                                    Spacer()
                                    if let member = model.roster.member(id: agentID), member.kind == .pi {
                                        Button("Open conversation") { selection = .agent(id: agentID) }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                if let session = model.session(for: agentID) {
                                    PinnedSessionWidgets(session: session,
                                        selected: pins.pins.filter { $0.agentID == agentID })
                                } else {
                                    ForEach(pins.pins.filter { $0.agentID == agentID }) { pin in
                                        UnavailablePinnedWidget(pin: pin,
                                            explanation: "This agent is unavailable. The saved pin is kept until you remove it.")
                                    }
                                }
                            }
                            .frame(maxWidth: 720, alignment: .leading)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Pinned widgets")
    }
}

/// Observe the session itself so a restored or updated original replaces the placeholder.
struct PinnedSessionWidgets: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PiAgentSession
    let selected: [PinnedCard]

    var body: some View {
        ForEach(selected) { pin in
            switch pin.resolution(in: rows(for: pin), agentID: session.agentID) {
            case .available(let card):
                SavedPinnedCardView(pin: pin, card: card, session: session)
            case .missingSource:
                UnavailablePinnedWidget(pin: pin,
                    explanation: pin.live == nil
                        ? "The original widget is not in the loaded conversation. The pin is kept until you remove it."
                        : "No matching revision is in this agent's loaded conversation. The pin is kept and will resume when the source is available.")
            case .conflictingRevision(let revision):
                UnavailablePinnedWidget(pin: pin,
                    explanation: "This agent published different contents for revision \(revision). Waiting for a newer revision rather than choosing the wrong widget.")
            }
        }
    }
    private func rows(for pin: PinnedCard) -> [PiThreadRow] {
        guard let projectID = pin.projectID else { return session.rows }
        return ProjectChatStore.cardRows(for: model.projectChats.messages.filter { $0.chatID == projectID },
                                         agentID: session.agentID, transcript: session.transcript)
    }

}

struct UnavailablePinnedWidget: View {
    let pin: PinnedCard
    let explanation: String
    @ObservedObject private var pins = PinnedCards.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Widget unavailable", systemImage: "rectangle.slash")
                    .tavernFont(.headline)
                Text(explanation).tavernFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unpin") { pins.toggle(pin) }.buttonStyle(.borderless)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
