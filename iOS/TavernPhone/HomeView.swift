import SwiftUI
import TavernCore

/// Like the Mac Dashboard, phone-sized: what needs you first, then what each agent is up to.
struct HomeView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        List {
            Section("Needs you") {
                let waiting = model.agents.filter { needsYou($0) }
                if waiting.isEmpty {
                    Label("Nothing is waiting on you.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(waiting) { agent in
                    if let session = model.session(for: agent) {
                        NavigationLink(value: agent.id) { NeedsRow(agent: agent, session: session) }
                    }
                }
            }
            Section("The party") {
                ForEach(model.agents) { agent in
                    if let session = model.session(for: agent) {
                        NavigationLink(value: agent.id) { ActivityRow(agent: agent, session: session) }
                    }
                }
            }
        }
        .navigationTitle("Tavern")
        .refreshable {
            for agent in model.agents { await model.session(for: agent)?.reconnectNow() }
        }
    }

    private func needsYou(_ agent: PhoneAgent) -> Bool {
        guard let session = model.session(for: agent) else { return false }
        if session.dialog != nil { return true }
        if case .failed = session.presence { return true }
        return false
    }
}

private struct NeedsRow: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: agent.name, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.dialog?.title ?? "\(agent.name) can't connect").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(session.dialog != nil ? "\(agent.name) is waiting on you" : session.presence.label)
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// An agent, what it's doing, and its last message with when.
private struct ActivityRow: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession

    var body: some View {
        let last = session.transcript.last { ($0.role == .assistant || $0.role == .user) && !$0.text.isEmpty }
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: agent.name, size: 40)
                .overlay(alignment: .bottomTrailing) { PresenceDot(presence: session.presence, waiting: session.dialog != nil) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent.name).font(.headline)
                    Spacer()
                    if let last { Text(last.date.formatted(.relative(presentation: .numeric))).font(.caption).foregroundStyle(.secondary) }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                if let last {
                    Text((last.role == .user ? "You: " : "") + Self.plain(PiReactions.withoutNotes(last.text)))
                        .font(.subheadline).foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The message without its Markdown marks, for a one-line preview.
    static func plain(_ text: String) -> String {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return String(attributed.characters).replacingOccurrences(of: "\n", with: " ")
    }

    private var status: String {
        if session.dialog != nil { return "Waiting on you" }
        if let tool = session.currentTool { return "Running \(tool)" }
        return session.presence.label.capitalized
    }
}

struct PresenceDot: View {
    let presence: PiAgentSession.Presence
    var waiting = false

    var body: some View {
        Circle().fill(color).frame(width: 11, height: 11).overlay(Circle().stroke(.background, lineWidth: 2))
    }

    private var color: Color {
        if waiting { return .orange }
        switch presence {
        case .idle: return .green
        case .working: return .blue
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}
