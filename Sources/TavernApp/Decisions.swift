import SwiftUI
import TavernCore

/// Suggestions from a decision model: Clef Flash through local Ollama first, Jev when a key is set
/// up and no local model is, else none. They only ever suggest; nothing is set until someone taps.
@MainActor
final class Decisions: ObservableObject {
    @Published private(set) var backend: DecisionBackend?
    private var lookedAt: Date?

    /// Finds the backend once, and again every 5 minutes while there's none (a model pulled later).
    func ready() async -> DecisionBackend? {
        if let backend { return backend }
        if let lookedAt, Date().timeIntervalSince(lookedAt) < 300 { return nil }
        lookedAt = Date()
        backend = await DecisionBackend.best()
        return backend
    }

    /// Asks, falling back to Jev when the local model fails; logs the answers to the event store, and
    /// returns nil on any failure.
    func ask(site: String, state: String, questions: [String: DecisionQuestion], events: EventStore?) async -> [String: DecisionAnswer]? {
        guard !questions.isEmpty, let backend = await ready() else { return nil }
        let started = Date()
        var used = backend
        var answers = try? await backend.ask(state: state, questions: questions)
        // A local model Ollama lists but can't run (an old download format) falls back to Jev.
        if answers == nil, backend.isLocal, let jev = DecisionBackend.jev() {
            used = jev
            answers = try? await jev.ask(state: state, questions: questions)
        }
        guard let answers else { return nil }
        _ = try? events?.append([DecisionSuggestions.event(site: site, backend: used, answers: answers,
                                                           latency: Date().timeIntervalSince(started))])
        return answers
    }
}

/// A "Suggested: …" chip. Tapping applies it; it never applies itself.
struct SuggestionChip: View {
    let text: String
    var help: String? = nil
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            Label(text, systemImage: "sparkles")
                .tavernFont(.caption, weight: .semibold)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.tavernAccent.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? "A decision model's suggestion; tap to use it")
    }
}
