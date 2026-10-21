import SwiftUI
import TavernCore

/// An agent's one thread: messages, folded work and heartbeats, the reply as it streams, an
/// approval when the agent is waiting on you, and the composer.
struct ThreadView: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.rows.suffix(150)) { row in
                        RowView(row: row).id(row.id)
                    }
                    ForEach(session.pendingMessages) { item in
                        Bubble(text: item.text, mine: true).opacity(0.6)
                    }
                    if session.isWorking { live }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.rows.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let dialog = session.dialog { ApprovalCard(dialog: dialog, session: session) }
                composer
            }
            .background(.bar)
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(agent.name).font(.headline)
                    Text(session.presence.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if session.isWorking {
                ToolbarItem { Button { Task { await session.abort() } } label: { Label("Stop", systemImage: "stop.circle") } }
            }
        }
    }

    @ViewBuilder private var live: some View {
        if let tool = session.currentTool {
            Label(tool, systemImage: "gearshape.2").font(.footnote).foregroundStyle(.secondary)
        } else if session.streamingText.isEmpty {
            Label("Thinking…", systemImage: "ellipsis").font(.footnote).foregroundStyle(.secondary)
        }
        if !session.streamingText.isEmpty { Bubble(text: session.streamingText, mine: false) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(agent.name)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel(session.isWorking ? "Queue" : "Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (session.presence == .idle || session.presence == .working)
    }

    /// Sends now, or queues it after the current turn when the agent is busy.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        Task { session.isWorking ? await session.followUp(text) : await session.send(text) }
    }
}

private struct RowView: View {
    let row: PiThreadRow

    var body: some View {
        switch row {
        case .message(let item):
            if item.role == .user || item.role == .assistant, !item.text.isEmpty {
                Bubble(text: item.text, mine: item.role == .user)
            }
        case .work(let work):
            Label(work.summary, systemImage: "hammer").font(.footnote).foregroundStyle(.secondary)
        case .background(let run):
            DisclosureGroup {
                ForEach(run.newItems, id: \.self) { Text($0).font(.footnote) }
                if let reply = run.reply { Text(reply).font(.footnote).foregroundStyle(.secondary) }
            } label: {
                Label("Heartbeat · \(run.title) · \(run.date.formatted(date: .omitted, time: .shortened))", systemImage: "waveform.path.ecg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .card(_, let card):
            Label("\(card.toolName) card (open Tavern on the Mac to see it)", systemImage: "rectangle.on.rectangle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct Bubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            Text(markdown)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? Color.white : Color.primary)
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The agent's question: Allow/Deny for an approval, a button per option for a choice, or a
/// text answer.
private struct ApprovalCard: View {
    let dialog: PiDialog
    let session: PiAgentSession
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(dialog.title, systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if let message = dialog.message, !message.isEmpty {
                ScrollView { Text(message).font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            switch dialog.method {
            case .confirm:
                HStack {
                    Button("Deny", role: .destructive) { reply(.confirmed(false)) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Allow") { reply(.confirmed(true)) }.buttonStyle(.borderedProminent)
                }
            case .select:
                ForEach(dialog.options, id: \.self) { option in
                    Button(option) { reply(.value(option)) }.buttonStyle(.bordered)
                }
                Button("Cancel", role: .cancel) { reply(.cancelled) }
            case .input, .editor:
                TextField(dialog.placeholder ?? "Answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel", role: .cancel) { reply(.cancelled) }
                    Spacer()
                    Button("Send") { reply(.value(answer)) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func reply(_ answer: PiDialogAnswer) {
        Task { await session.answer(answer) }
    }
}
