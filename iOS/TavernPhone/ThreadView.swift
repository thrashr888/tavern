import PhotosUI
import SwiftUI
import TavernCore

/// An agent's one thread: Markdown replies with reactions and link previews, folded work and
/// heartbeats, MCP Apps cards, the reply as it streams, an approval when the agent waits on
/// you, and a composer with photos. Tap the title for the agent's info.
struct ThreadView: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession
    @State private var draft = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var images: [PiImage] = []
    @State private var showingInfo = false
    @State private var shownRows = 120
    @StateObject private var dictation = Dictation()
    /// The draft when dictation started; what's heard goes after it.
    @State private var dictationBase = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let rows = session.rows
                    if rows.count > shownRows {
                        Button("Show earlier") { shownRows += 120 }.font(.footnote).frame(maxWidth: .infinity)
                    }
                    ForEach(rows.suffix(shownRows)) { row in
                        RowView(row: row, session: session).id(row.id)
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
            .refreshable { await refresh() }
            .onChange(of: session.rows.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(session: session) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let dialog = session.dialog { ApprovalCard(dialog: dialog, session: session) }
                composer
            }
            .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showingInfo = true } label: {
                    HStack(spacing: 8) {
                        Avatar(name: agent.name, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(agent.name).font(.headline).foregroundStyle(.primary)
                            Text(session.dialog != nil ? "Waiting on you" : session.presence.label)
                                .font(.caption2).foregroundStyle(session.dialog != nil ? Color.tavernAccent : .secondary)
                        }
                    }
                }
                .accessibilityLabel("\(agent.name) info")
            }
            if session.isWorking {
                ToolbarItem { Button { Task { await session.abort() } } label: { Label("Stop", systemImage: "stop.circle") } }
            }
        }
        .sheet(isPresented: $showingInfo) { AgentInfoSheet(agent: agent, session: session) }
        .onChange(of: photos) { _, items in Task { await load(items) } }
        .onChange(of: dictation.text) { _, heard in
            guard dictation.listening, !heard.isEmpty else { return }
            draft = dictationBase.isEmpty ? heard : dictationBase + " " + heard
        }
        .onDisappear { dictation.stop() }
    }

    private func refresh() async {
        switch session.presence {
        case .idle, .working: try? await session.sync()
        default: await session.reconnectNow()
        }
    }

    @ViewBuilder private var live: some View {
        if let work = session.liveWork { WorkRow(work: work, expandedAtStart: true) }
        if !session.streamingText.isEmpty {
            Bubble(text: session.streamingText, mine: false)
        } else if session.currentTool == nil {
            Label("Thinking…", systemImage: "ellipsis").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = dictation.error { Text(error).font(.caption).foregroundStyle(.red) }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            if let ui = UIImage(data: image.data) {
                                Image(uiImage: ui).resizable().scaledToFill().frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .topTrailing) {
                                        Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo").font(.system(size: 18)).frame(width: 34, height: 34)
                }
                TextField("Message \(agent.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    if !dictation.listening { dictationBase = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
                    dictation.toggle()
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic").font(.system(size: 18))
                        .foregroundStyle(dictation.listening ? Color.red : Color.tavernAccent)
                        .symbolEffect(.pulse, isActive: dictation.listening)
                        .frame(width: 30, height: 34)
                }
                .accessibilityLabel(dictation.listening ? "Stop dictation" : "Dictate")
                Button(action: send) {
                    Image(systemName: session.isWorking ? "text.append" : "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? Color.tavernAccent : Color.secondary.opacity(0.4), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(session.isWorking ? "Queue" : "Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && (session.presence == .idle || session.presence == .working)
    }

    /// Sends now, or queues it after the current turn when the agent is busy.
    private func send() {
        dictation.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let attached = images
        draft = ""
        images = []
        photos = []
        Task { session.isWorking ? await session.followUp(text, images: attached) : await session.send(text, images: attached) }
    }

    /// Photos as JPEG, scaled so the long side is at most 1600 points.
    private func load(_ items: [PhotosPickerItem]) async {
        var loaded: [PiImage] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpeg = resized.jpegData(compressionQuality: 0.8) { loaded.append(PiImage(data: jpeg, mimeType: "image/jpeg")) }
        }
        images = loaded
    }
}

/// Offline, connecting or reconnecting, with a way to try again.
private struct ConnectionBanner: View {
    @ObservedObject var session: PiAgentSession

    var body: some View {
        switch session.presence {
        case .idle, .working:
            EmptyView()
        default:
            HStack(spacing: 8) {
                if session.presence == .connecting || session.presence == .reconnecting { ProgressView().controlSize(.small) }
                else { Image(systemName: "wifi.slash") }
                Text(message).font(.footnote).lineLimit(2)
                Spacer()
                Button("Retry") { Task { await session.reconnectNow() } }.font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.tavernAccent.opacity(0.15))
        }
    }

    private var message: String {
        switch session.presence {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting… \(session.lastConnectError ?? "")"
        case .failed(let reason): return "Can't connect: \(reason)"
        default: return "Not connected"
        }
    }
}

private struct RowView: View {
    let row: PiThreadRow
    @ObservedObject var session: PiAgentSession

    var body: some View {
        switch row {
        case .message(let item):
            if item.role == .user || item.role == .assistant, !item.text.isEmpty {
                MessageView(item: item, session: session)
            } else if item.role == .system, !item.text.isEmpty {
                Text(item.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        case .work(let work):
            WorkRow(work: work)
        case .background(let run):
            DisclosureGroup {
                ForEach(run.newItems, id: \.self) { Text($0).font(.footnote) }
                if let reply = run.reply { Text(PiReactions.withoutNotes(reply)).font(.footnote).foregroundStyle(.secondary) }
            } label: {
                Label("Heartbeat · \(run.title) · \(run.date.formatted(date: .omitted, time: .shortened))", systemImage: "waveform.path.ecg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .card(_, let card):
            CardView(card: card, session: session)
        case .spell(_, let spell):
            Label("Cast \(spell)", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A message: Markdown for the agent, a bubble for you, reactions underneath (long-press to
/// add one), and link previews.
private struct MessageView: View {
    let item: TranscriptItem
    @ObservedObject var session: PiAgentSession
    static let emoji = ["👍", "❤️", "😂", "🎉", "👀", "🚀", "😕", "👎"]

    var body: some View {
        let mine = item.role == .user
        let text = mine ? AttachmentCache.split(PiReactions.withoutNotes(item.text)).text : item.text
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if mine {
                Bubble(text: text, mine: true)
            } else {
                MarkdownView(text: text)
            }
            let reactions = session.reactions[item.id] ?? []
            if !reactions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(reactions, id: \.self) { reaction in
                        Text(reaction.emoji).font(.footnote).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .onTapGesture { session.toggleReaction(reaction.emoji, on: item) }
                    }
                }
            }
            let links = LinkPreviewPolicy.previewable(in: text, limit: 3)
            ForEach(links, id: \.self) { LinkChip(url: $0) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .contextMenu {
            ForEach(Self.emoji, id: \.self) { emoji in
                Button(emoji) { session.toggleReaction(emoji, on: item) }
            }
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }
}

/// Headings, paragraphs, lists, code and quotes, the way the agent wrote them.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level <= 1 ? .title3.bold() : .headline)
                case .paragraph(let text):
                    inline(text)
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                                inline(item)
                            }
                        }
                    }
                case .code(_, let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .quote(let text):
                    inline(text).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                case .table(let source):
                    let rows = MarkdownBlock.tableRows(source)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).font(.footnote.weight(index == 0 ? .semibold : .regular))
                                    }
                                }
                                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }
                        .padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}

struct Bubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(Color.tavernAccent) : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? Color.onTavernAccent : Color.primary)
            if !mine { Spacer(minLength: 48) }
        }
    }
}

/// "Worked 48s · 3 steps", opening to each step and how long it took.
private struct WorkRow: View {
    let work: PiWork
    var expandedAtStart = false
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? expandedAtStart }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(work.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(step.kind)).foregroundStyle(step.failed ? .red : .secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.footnote).lineLimit(3)
                            Text(step.failed ? "\(step.kind.rawValue) · failed" : step.kind.rawValue).font(.caption2).foregroundStyle(step.failed ? .red : .secondary)
                        }
                        Spacer()
                        if step.isRunning { ProgressView().controlSize(.mini) }
                        else { Text(PiWork.format(step.elapsed(at: Date()))).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label(work.summary, systemImage: "hammer").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func symbol(_ kind: PiStep.Kind) -> String {
        switch kind {
        case .shell: "terminal"
        case .read: "doc.text"
        case .write: "square.and.pencil"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .webSearch: "globe"
        case .fetch: "arrow.down.circle"
        case .thought: "brain"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// A link under a message: its site icon and title once fetched, one width throughout.
private struct LinkChip: View {
    let url: URL
    @State private var preview: LinkPreview?

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.caption)
                Text(preview?.displayTitle ?? LinkPreview.domain(of: url)).font(.caption.weight(.medium)).lineLimit(1)
                    .frame(width: 200, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .task { preview = await LinkPreviewFetcher.shared.preview(for: url) }
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
            Label(dialog.title, systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.tavernAccent)
            if let message = dialog.message, !message.isEmpty {
                ScrollView { Text(message).font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            switch dialog.method {
            case .confirm:
                HStack {
                    Button("Deny", role: .destructive) { reply(.confirmed(false)) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Allow") { reply(.confirmed(true)) }.buttonStyle(.borderedProminent).tint(Color.tavernAccent)
                }
                if let always = dialog.alwaysLabel {
                    Button(always) { reply(.alwaysAllow) }.font(.footnote).frame(maxWidth: .infinity, alignment: .trailing)
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
                    Button("Send") { reply(.value(answer)) }.buttonStyle(.borderedProminent).tint(Color.tavernAccent)
                }
            }
        }
        .padding(12)
        .background(Color.tavernAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.tavernAccent.opacity(0.45)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func reply(_ answer: PiDialogAnswer) {
        Task { await session.answer(answer) }
    }
}

/// What the agent is and how it runs, with the controls a phone needs.
private struct AgentInfoSheet: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: agent.name, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(.title2.bold())
                            HStack(spacing: 6) {
                                PresenceDot(presence: session.presence, waiting: session.dialog != nil)
                                Text(session.presence.label.capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("How it runs") {
                    LabeledContent("Model", value: session.config.model?.shortName ?? "Not reported")
                    LabeledContent(agent.isLocal ? "Runs on" : "Endpoint", value: agent.endpoint)
                    if !agent.isLocal {
                        LabeledContent("Host", value: session.config.durable ? "Durable host" : "Pi RPC")
                    }
                    if let usage = session.config.usage {
                        LabeledContent("Spent", value: usage.cost.formatted(.currency(code: "USD")))
                    }
                }
                if !session.config.alwaysAllow.isEmpty {
                    Section {
                        ForEach(session.config.alwaysAllow, id: \.self) { key in
                            HStack {
                                Text(key.hasPrefix("bash:") ? String(key.dropFirst(5)) : key).font(.callout.monospaced())
                                Spacer()
                                Button("Ask again") { Task { await session.forgetAlwaysAllow(key) } }.font(.footnote)
                            }
                        }
                    } header: {
                        Text("Always allowed")
                    } footer: {
                        Text("Runs without asking. Deletes, sudo, secrets and force-pushes still ask.")
                    }
                }
                if let heartbeat = session.config.heartbeat {
                    Section("Heartbeat") {
                        LabeledContent("Every", value: "\(heartbeat.everyMinutes) min")
                        if let last = heartbeat.last { LabeledContent("Last", value: last.formatted(.relative(presentation: .named))) }
                        if let next = heartbeat.next { LabeledContent("Next", value: next.formatted(date: .omitted, time: .shortened)) }
                        if let woke = heartbeat.wokeThisWeek, let quiet = heartbeat.quietThisWeek {
                            LabeledContent("This week", value: "\(woke) woke · \(quiet) quiet")
                        }
                    }
                }
                if agent.isLocal, let runtime = LocalAgentRuntime.runtime(id: agent.id) {
                    Section {
                        Picker("Check mail", selection: Binding(get: { runtime.everyMinutes }, set: { minutes in
                            runtime.setHeartbeat(minutes: minutes)
                            Task { try? await session.sync() }
                        })) {
                            Text("Off").tag(0)
                            ForEach([15, 30, 60, 120, 240], id: \.self) { Text($0 < 60 ? "Every \($0) min" : "Every \($0 / 60) h").tag($0) }
                        }
                        NavigationLink("What to do on a beat") { HeartbeatTaskEditor(runtime: runtime) }
                    } header: {
                        Text("Heartbeat")
                    } footer: {
                        Text("New mail wakes \(agent.name) with HEARTBEAT.md. While Tavern is open it checks on time; closed, iOS decides when, often later.")
                    }
                    Section {
                        if let role = agent.role { Text(role) }
                        let memory = LocalAgentRuntime.memory(of: agent)
                        Text(memory.isEmpty ? "Nothing yet." : memory).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    } header: {
                        Text("Memory")
                    } footer: {
                        Text("Kept on this iPhone. Tell \(agent.name) to remember something and it adds a line.")
                    }
                }
                Section {
                    if !agent.isLocal || session.config.heartbeat != nil {
                    Button {
                        checking = true
                        Task {
                            checkResult = await session.heartbeatCheck() ?? (session.lastError ?? "Not connected")
                            checking = false
                        }
                    } label: { Label(checking ? "Checking…" : "Run heartbeat check", systemImage: "waveform.path.ecg") }
                        .disabled(checking)
                    if let checkResult { Text(checkResult).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if !agent.isLocal {
                        Button { Task { await session.compact() } } label: { Label("Compact the context", systemImage: "rectangle.compress.vertical") }
                    }
                    Button { Task { await session.reconnectNow() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { Task { await session.abort() } } label: { Label("Stop the current turn", systemImage: "stop.circle") }
                        .disabled(!session.isWorking)
                }
            }
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A phone agent's HEARTBEAT.md: what it does when new mail wakes it. Saved on the way out.
private struct HeartbeatTaskEditor: View {
    let runtime: LocalAgentRuntime
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .padding(.horizontal, 12)
            .navigationTitle("HEARTBEAT.md")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { text = runtime.heartbeatTask }
            .onDisappear { runtime.heartbeatTask = text }
    }
}
