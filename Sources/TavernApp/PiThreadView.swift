import SwiftUI
import TavernCore

/// A Pi agent's single thread: transcript, live stream, waiting-on-you dialogs and controls.
struct PiThreadView: View {
    @ObservedObject var session: PiAgentSession
    var agent: RosterMember?
    @State private var draft = ""
    @State private var images: [DraftImage] = []
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    /// How many of the newest rows the thread shows; reaching the top loads another page.
    @State private var shownRows = PiThreadView.rowPage
    static let rowPage = 150

    var body: some View {
        VStack(spacing: 0) {
            header
            if finding {
                FindBar(query: $findQuery, current: $findIndex, matchCount: findMatchIDs.count) {
                    finding = false
                    findQuery = ""
                }
            }
            transcript
            composer
        }
        .task { await session.connect() }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFocusComposer)) { _ in composerFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFind)) { _ in finding = true }
    }

    /// Ids of transcript messages matching the find query, oldest first.
    private var findMatchIDs: [String] {
        guard finding, !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return session.rows.compactMap { row in
            if case .message(let item) = row, findMatches(item.text + "\n" + item.thinking, findQuery) { return row.id }
            return nil
        }
    }

    /// A centered pill, as in the Pi app examples: avatar, name, then model and status.
    private var header: some View {
        HStack {
            Spacer()
            HStack(spacing: 10) {
                if let agent {
                    AvatarView(member: agent, size: 30)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(presenceColor).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent?.name ?? session.agentID).tavernFont(.callout, weight: .semibold)
                    Text([session.config.model?.shortName, statusLine].compactMap { $0 }.joined(separator: " · "))
                        .tavernFont(.caption)
                        .foregroundStyle(session.dialog != nil ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                switch session.presence {
                case .disconnected, .failed:
                    Button("Connect") { Task { await session.connect() } }.controlSize(.small)
                default:
                    EmptyView()
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            // Like Muse: the pill opens (and closes) the agent's panel.
            .contentShape(Capsule())
            .onTapGesture { NotificationCenter.default.post(name: .tavernToggleInspector, object: nil) }
            .help("Show or hide \(agent?.name ?? "the agent")'s panel")
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        if session.dialog != nil { return "Waiting on you" }
        if let tool = session.currentTool { return "Running \(tool)" }
        if session.isThinking { return "Thinking" }
        if case .failed(let reason) = session.presence { return "Connection failed: \(reason)" }
        if session.presence == .reconnecting, let reason = session.lastConnectError {
            return "Reconnecting (last error: \(reason))"
        }
        return session.presence.label.capitalized
    }

    private var presenceColor: Color {
        if session.dialog != nil { return .orange }
        switch session.presence {
        case .working: return .green
        case .idle: return .secondary
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let matches = findMatchIDs
                    let currentMatch = matches.indices.contains(findIndex) ? matches[findIndex] : nil
                    let groups = HeartbeatRun.grouped(session.rows)
                    // The newest rows only; older ones load as you reach the top. Find shows all.
                    let visible = finding ? groups[...] : groups.suffix(shownRows)
                    if visible.count < groups.count {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .onAppear {
                                let anchor = visible.first?.id
                                shownRows += Self.rowPage
                                // Stay on the row that was at the top, rather than jumping.
                                if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
                            }
                    }
                    ForEach(visible) { group in
                        switch group {
                        case .heartbeats(let runs): HeartbeatGroupRow(runs: runs, session: session)
                        case .row(let row):
                        switch row {
                        case .message(let item):
                            TranscriptRow(item: item, reactions: session.reactions[item.id] ?? []) { emoji in
                                session.toggleReaction(emoji, on: item)
                            }
                                .findHighlight(matched: matches.contains(row.id), current: row.id == currentMatch)
                        case .work(let work): WorkRow(work: work)
                        case .card(_, let card): ToolCardView(card: card, session: session)
                        case .spell(_, let spell): SpellCastCard(spell: spell)
                        case .background(let run): HeartbeatRow(run: run, session: session)
                        }
                        }
                    }
                    ForEach(session.pendingMessages) { item in
                        TranscriptRow(item: item).opacity(0.6)
                    }
                    if let work = session.liveWork {
                        WorkRow(work: work, expandedAtStart: true)
                    }
                    if !session.streamingText.isEmpty || !session.streamingThinking.isEmpty {
                        TranscriptRow(item: TranscriptItem(
                            id: "streaming", role: .assistant, text: session.streamingText,
                            thinking: session.streamingThinking, date: Date()
                        ), thinkingExpanded: session.streamingText.isEmpty, showsLinks: false)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // A readable column, centered, like the Pi desktop apps.
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            // Find: start at the newest match and scroll to each one chosen.
            .onChange(of: findQuery) { _, _ in
                findIndex = max(findMatchIDs.count - 1, 0)
                if let id = findMatchIDs.last { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: findIndex) { _, index in
                let ids = findMatchIDs
                if ids.indices.contains(index) { withAnimation { proxy.scrollTo(ids[index], anchor: .center) } }
            }
            // Open on the latest messages, not the oldest.
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.transcript.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.pendingMessages.count) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.returnedDraft) { _, returned in
                guard let returned else { return }
                draft = draft.isEmpty ? returned : draft + "\n" + returned
                session.returnedDraft = nil
            }
            .onChange(of: session.streamingText) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.streamingThinking) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: session.liveSteps.count) { _, _ in proxy.scrollTo("bottom") }
        }
    }

    /// A rounded card: the message field on top, chips and actions underneath.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // What the agent is waiting on sits where you answer, just above the composer.
            if let dialog = session.dialog {
                DialogBanner(dialog: dialog) { answer in
                    Task { await session.answer(answer) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = session.lastError {
                Label(ModelError.parse(error).summary, systemImage: "exclamationmark.triangle")
                    .tavernFont(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 10) {
                AttachmentTray(images: $images)
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(submitDefault)
                    .padding(.horizontal, 4)
                HStack(spacing: 6) {
                    AddImageButton(images: $images)
                    EmojiDraftButton(draft: $draft)
                    if let model = session.config.model {
                        Chip(systemImage: "cpu", text: model.shortName).help(model.label)
                    }
                    if let level = session.config.thinkingLevel {
                        Chip(systemImage: "brain", text: level.capitalized).help("Thinking level")
                    }
                    Spacer()
                    if session.isWorking {
                        ChipButton(systemImage: "arrow.turn.down.right", text: "Steer") { submit { await session.steer($0, images: $1) } }
                            .help("Send now, into the running turn")
                            .disabled(draftIsEmpty)
                        ChipButton(systemImage: "text.append", text: "Queue") { submit { await session.followUp($0, images: $1) } }
                            .help("Run after this turn (Return)")
                            .disabled(draftIsEmpty)
                        RoundButton(systemImage: "stop.fill", tint: .red) { Task { await session.abort() } }
                            .help("Abort the turn")
                    } else {
                        RoundButton(systemImage: "arrow.up", tint: .tavernAccent, action: submitDefault)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(draftIsEmpty)
                            .help("Send (Return)")
                    }
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                dropTargeted ? Color.tavernAccent : (composerFocused ? Color.tavernAccent.opacity(0.5) : Color.secondary.opacity(0.25)),
                lineWidth: dropTargeted ? 2 : 1))
            .acceptsImageDrops(into: $images, targeted: $dropTargeted)
            .onPasteCommand(of: [.image, .fileURL]) { _ in images += DraftImage.fromPasteboard() }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { composerFocused = true }
            .disabled(!canSend)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private var placeholder: String {
        let name = agent?.name ?? "the agent"
        switch session.presence {
        case .working: return "Steer \(name), or queue a follow-up"
        case .idle: return "Message \(name)"
        default: return "\(name) isn't connected"
        }
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    private var canSend: Bool {
        switch session.presence {
        case .idle, .working: return true
        default: return false
        }
    }

    private func submitDefault() {
        if session.isWorking {
            submit { await session.followUp($0, images: $1) }
        } else {
            submit { await session.send($0, images: $1) }
        }
    }

    private func submit(_ action: @escaping (String, [PiImage]) async -> Void) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let attached = images.map(\.piImage)
        draft = ""
        images = []
        Task { await action(text.isEmpty ? "Here's an image." : text, attached) }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    /// Live thinking starts open so a long think visibly moves; stored thinking starts collapsed.
    var thinkingExpanded = false
    /// Preview chips for the message's links; off while a reply streams in, half-written.
    var showsLinks = true
    /// The user's reactions to this reply; `onReact` is nil where reacting doesn't apply.
    var reactions: [Reaction] = []
    var onReact: ((String) -> Void)? = nil
    @State private var hovering = false
    @State private var picking = false

    var body: some View {
        switch item.role {
        case .system where item.failed:
            ModelErrorCard(error: ModelError.parse(item.text))
        case .system, .tool:
            Text(item.text)
                .tavernFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .user:
            // the user's messages are bubbles on the right; the agent's replies are plain text.
            let parts = AttachmentCache.split(item.text)
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !parts.paths.isEmpty { InlineImages(paths: parts.paths) }
                    if !parts.text.isEmpty { userBubble(parts.text) }
                    if showsLinks, case let urls = LinkPreviewPolicy.previewable(in: parts.text), !urls.isEmpty {
                        LinkChipRow(urls: urls, trailing: true)
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !item.thinking.isEmpty {
                    ThinkingView(text: item.thinking, expanded: thinkingExpanded)
                }
                if !item.text.isEmpty {
                    MarkdownText(text: item.text)
                }
                if showsLinks, case let urls = LinkPreviewPolicy.previewable(in: item.text), !urls.isEmpty {
                    LinkChipRow(urls: urls)
                }
                if let onReact, !reactions.isEmpty {
                    ReactionChips(reactions: reactions, onTap: onReact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // React from the reply's corner while hovering, without moving the text.
            .overlay(alignment: .topTrailing) {
                if let onReact, !item.text.isEmpty, hovering || picking {
                    AddReactionButton(onPick: onReact, open: $picking)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .offset(y: -10)
                }
            }
        }
    }
}

/// A reply rendered by block: headings, lists, code, quotes and tables, with inline Markdown inside.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(TranscriptRow.markdown(text))
                .tavernFont(level <= 1 ? .title3 : .headline, weight: .semibold)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(TranscriptRow.markdown(text))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(TranscriptRow.markdown(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            Text(TranscriptRow.markdown(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .table(let source):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

extension TranscriptRow {
    func userBubble(_ text: String) -> some View {
        Text(Self.markdown(text))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tavernAccent.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Inline Markdown (bold, italics, code, links) with line breaks kept; plain text if it won't parse.
    /// Links survive only for http(s): replies can carry text from web pages or mail, so a
    /// `file:`, `x-apple…:` or app-scheme link stays plain text instead of something clickable.
    static func markdown(_ text: String) -> AttributedString {
        guard var parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in parsed.runs {
            if let url = run.link, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                parsed[run.range].link = nil
            }
        }
        return parsed
    }
}

/// Images the user sent with a message, as thumbnails; click to open full size. A path whose image
/// isn't on this Mac (sent from another client) shows as a small placeholder.
struct InlineImages: View {
    let paths: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                if let url = AttachmentCache.localFile(for: path), let image = NSImage(contentsOf: url) {
                    Button { Self.preview(url) } label: {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // Never upscale a small image; cap big ones.
                            .frame(maxWidth: min(image.size.width, paths.count == 1 ? 320 : 160),
                                   maxHeight: min(image.size.height, paths.count == 1 ? 240 : 140))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Open \((path as NSString).lastPathComponent)")
                } else {
                    Label("Image", systemImage: "photo")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                        .help(path)
                }
            }
        }
    }
}

extension InlineImages {
    /// Opens the image in Preview specifically, never the file's default handler.
    static func preview(_ url: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A quiet label chip in the composer (model, thinking level).
private struct Chip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .tavernFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

private struct ChipButton: View {
    let systemImage: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: systemImage)
                .tavernFont(.caption, weight: .medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RoundButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(isEnabled ? tint : Color.secondary.opacity(0.4), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A failed model call: what went wrong in words, the provider's message, and the status and
/// request id small underneath for looking it up.
struct ModelErrorCard: View {
    let error: ModelError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title).tavernFont(.callout, weight: .semibold)
                Text(error.message).tavernFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                let meta = [error.status.map { "HTTP \($0)" }, error.requestID].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).tavernFont(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A run of tool steps, collapsed to "Worked 48s · 9 steps" with a chevron; expands to the steps.
struct WorkRow: View {
    let work: PiWork
    @State private var expanded: Bool

    init(work: PiWork, expandedAtStart: Bool = false) {
        self.work = work
        _expanded = State(initialValue: expandedAtStart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if work.isRunning { ProgressView().controlSize(.mini) }
                    ForEach(work.kinds.prefix(4), id: \.self) { kind in
                        Image(systemName: kind.symbol).imageScale(.small)
                    }
                    WorkSummary(work: work)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                // A quiet inline line, not a chip, so replies stay the focus.
                .tavernFont(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                StepList(steps: work.steps)
                    .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each step on a thin timeline: icon, what it did, its kind, and how long it took.
struct StepList: View {
    let steps: [PiStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.kind.symbol)
                        .frame(width: 22, height: 22)
                        .background(.quaternary.opacity(0.6), in: Circle())
                        .foregroundStyle(step.failed ? Color.red : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).lineLimit(2).textSelection(.enabled)
                        Text(step.failed ? "\(step.kind.rawValue) · failed" : step.kind.rawValue)
                            .tavernFont(.caption)
                            .foregroundStyle(step.failed ? Color.red : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    StepDuration(step: step)
                }
                .tavernFont(.callout)
                .padding(.vertical, 5)
                if let change = step.change { ChangeView(change: change).padding(.leading, 32).padding(.bottom, 4) }
            }
        }
    }
}

/// An edit's diff or a write's new file, collapsed to "+12 −3" until opened.
struct ChangeView: View {
    let change: StepChange
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                    if change.isNewContent { Text("New file · \(change.added) lines") }
                    else {
                        Text("+\(change.added)").foregroundStyle(.green)
                        Text("−\(change.removed)").foregroundStyle(.red)
                    }
                }
                .tavernFont(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(change.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 8) {
                                Text(line.number).foregroundStyle(.tertiary).frame(minWidth: 28, alignment: .trailing)
                                Text(symbol(line.mark)).foregroundStyle(color(line.mark))
                                Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.mark == .gap ? .secondary : .primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(color(line.mark).opacity(line.mark == .added || line.mark == .removed ? 0.12 : 0))
                        }
                        if change.omitted > 0 {
                            Text("\(change.omitted) more lines").foregroundStyle(.secondary).padding(8)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
        }
    }

    private func symbol(_ mark: StepChange.Line.Mark) -> String {
        switch mark { case .added: "+"; case .removed: "−"; case .context, .gap: " " }
    }

    private func color(_ mark: StepChange.Line.Mark) -> Color {
        switch mark { case .added: .green; case .removed: .red; case .context, .gap: .secondary }
    }
}

/// "Worked 48s · 9 steps", counting up while the work runs.
struct WorkSummary: View {
    let work: PiWork

    var body: some View {
        if work.isRunning {
            TimelineView(.periodic(from: work.started ?? Date(), by: 0.1)) { context in
                Text(work.summary(at: context.date)).monospacedDigit()
            }
        } else {
            Text(work.summary)
        }
    }
}

/// A step's duration, right-aligned; a running step counts up live.
struct StepDuration: View {
    let step: PiStep

    var body: some View {
        if step.isRunning {
            TimelineView(.periodic(from: step.started, by: 0.1)) { context in
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    label(step.elapsed(at: context.date))
                }
            }
        } else {
            label(step.elapsed(at: Date()))
        }
    }

    private func label(_ seconds: TimeInterval) -> some View {
        Text(PiWork.format(seconds))
            .tavernFont(.caption)
            .foregroundStyle(step.failed ? Color.red : Color.secondary)
            .monospacedDigit()
    }
}

extension PiStep.Kind {
    var symbol: String {
        switch self {
        case .shell: return "terminal"
        case .read: return "doc.text"
        case .write: return "square.and.pencil"
        case .edit: return "pencil"
        case .search: return "magnifyingglass"
        case .webSearch: return "globe"
        case .fetch: return "arrow.down.doc"
        case .thought: return "brain"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// The model's thinking, dimmed and collapsible.
private struct ThinkingView: View {
    let text: String
    @State private var expanded: Bool

    init(text: String, expanded: Bool) {
        self.text = text
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .tavernFont(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .tavernFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }
}

/// The loud "waiting on you" state for extension dialogs that pause the agent, shown above the
/// composer: what it wants, the command in full, and the answers.
struct DialogBanner: View {
    let dialog: PiDialog
    let onAnswer: (PiDialogAnswer) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(dialog.title, systemImage: "hand.raised.fill")
                .tavernFont(.callout, weight: .semibold)
                .foregroundStyle(.orange)
            if let message = dialog.message, !message.isEmpty {
                if dialog.isApproval {
                    ScrollView {
                        Text(message).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(message)
                }
            }
            switch dialog.method {
            case .confirm where dialog.isApproval:
                // No default key: Return shouldn't run a risky command.
                HStack {
                    Spacer()
                    Button("Deny") { onAnswer(.confirmed(false)) }.controlSize(.large)
                    Button("Allow") { onAnswer(.confirmed(true)) }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                }
            case .confirm:
                HStack {
                    Spacer()
                    Button("Cancel") { onAnswer(.cancelled) }
                    Button("No") { onAnswer(.confirmed(false)) }
                    Button("Yes") { onAnswer(.confirmed(true)) }.keyboardShortcut(.defaultAction)
                }
            case .select:
                FlowLayout(spacing: 8) {
                    ForEach(dialog.options, id: \.self) { option in
                        Button(option) { onAnswer(.value(option)) }
                    }
                    Button("Cancel") { onAnswer(.cancelled) }
                }
            case .input, .editor:
                TextField(dialog.placeholder ?? "", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(dialog.method == .editor ? 3...10 : 1...3)
                    .onAppear { text = dialog.prefill ?? "" }
                HStack {
                    Spacer()
                    Button("Cancel") { onAnswer(.cancelled) }
                    Button("Submit") { onAnswer(.value(text)) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange.opacity(0.45)))
    }
}
