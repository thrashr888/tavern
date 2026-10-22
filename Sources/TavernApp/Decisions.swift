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

/// A suggestion chip (mock 5): "Spell  SB-20 Weekly update  0.86". Tapping applies it; it never
/// applies itself. Dashed for a follow-on ("then SB-21") that's offered, not picked.
struct SuggestionChip: View {
    let label: String
    let value: String
    var confidence: Double? = nil
    var dashed = false
    var help: String? = nil
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").imageScale(.small).foregroundStyle(Color.tavernAccent)
                Text(label).tavernFont(.caption).foregroundStyle(.secondary)
                Text(value).tavernFont(.caption, weight: .semibold).lineLimit(1)
                if let confidence {
                    Text(String(format: "%.2f", confidence))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(dashed ? Color.clear : Color.tavernAccent.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.tavernAccent.opacity(dashed ? 0.6 : 0.35),
                                            style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? "A decision model's suggestion; tap to use it")
    }
}
