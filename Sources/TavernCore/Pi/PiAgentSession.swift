import Combine
import Foundation

/// Live state for one Pi agent's single thread: presence, streaming text, the current tool,
/// any dialog waiting on the user, and the stored transcript.
@MainActor
public final class PiAgentSession: ObservableObject {
    public enum Presence: Equatable, Sendable {
        case disconnected
        case connecting
        case idle
        case working
        case reconnecting
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected: return "not connected"
            case .connecting: return "connecting"
            case .idle: return "idle"
            case .working: return "working"
            case .reconnecting: return "reconnecting"
            case .failed: return "connection failed"
            }
        }
    }

    public let agentID: String
    private let store: EventStore
    /// The event log, for reactions (PiReactions.swift).
    var reactionStore: EventStore? { store }
    /// The user's reactions per transcript item id.
    @Published public internal(set) var reactions: [String: [Reaction]] = [:]
    private let makeTransport: () throws -> PiTransport
    private var client: PiClient?
    private var listener: Task<Void, Never>?

    @Published public private(set) var presence: Presence = .disconnected
    @Published public private(set) var transcript: [TranscriptItem] = []
    /// Assistant text streaming in for the current turn; cleared when the turn settles.
    @Published public private(set) var streamingText = ""
    /// Thinking streaming in for the current turn, so a long think doesn't look idle.
    @Published public private(set) var streamingThinking = ""
    @Published public private(set) var currentTool: String?
    /// Tool steps of the turn in progress, live from `tool_execution_*`; cleared when it settles.
    @Published public private(set) var liveSteps: [PiStep] = []
    /// An extension dialog that has paused the agent until answered.
    @Published public private(set) var dialog: PiDialog?
    @Published public private(set) var notices: [String] = []
    @Published public private(set) var lastError: String?
    /// Model, thinking level and session from the last `get_state` (plan 3c). Read-only.
    @Published public private(set) var config = PiAgentConfig()
    /// Models the agent offers, from `get_available_models`; empty until asked or when unsupported.
    @Published public private(set) var availableModels: [PiModel] = []
    /// A confirmed switch waiting for the current turn to settle.
    @Published public private(set) var pendingModel: PiModel?
    public let modelLocks: ModelLockStore
    private var pendingReason = ""
    private var turnFailed = false
    /// Messages the user sent that the agent hasn't committed yet. Shown at once, so a slow start
    /// (a model loading, a queued follow-up) doesn't look like nothing happened.
    @Published public private(set) var pendingMessages: [TranscriptItem] = []
    private var pendingSince: [String: Int] = [:]
    /// Text an abort took back from the queue, for the composer to restore (Pi's TUI does the same).
    @Published public var returnedDraft: String?

    public init(agentID: String, store: EventStore, modelLocks: ModelLockStore = ModelLockStore(),
                makeTransport: @escaping () throws -> PiTransport) {
        self.agentID = agentID
        self.store = store
        self.modelLocks = modelLocks
        self.makeTransport = makeTransport
        reloadTranscript()
    }

    public var modelLocked: Bool { modelLocks.isLocked(agentID) }
    public var lastKnownGoodModel: PiModel? { modelLocks.lastKnownGood(agentID) }

    public func setModelLocked(_ locked: Bool) {
        objectWillChange.send()
        modelLocks.setLocked(locked, for: agentID)
        if locked { pendingModel = nil }
    }

    public var isWorking: Bool { presence == .working }

    /// The transcript with tool runs folded into "Worked · N steps" rows.
    public var rows: [PiThreadRow] { PiActivity.rows(from: transcript) }

    /// The turn in progress as a work row, while it has run any tools.
    public var liveWork: PiWork? {
        liveSteps.isEmpty ? nil : PiWork(id: "live", steps: liveSteps)
    }

    /// Working, with thinking streaming and no reply text yet.
    public var isThinking: Bool { isWorking && currentTool == nil && streamingText.isEmpty && !streamingThinking.isEmpty }

    // MARK: - Connection

    /// Retry after a dropped or failed connection (remote hosts sleep, tunnels drop).
    public var autoReconnect = true
    /// Delay before reconnect attempt `n` (1-based). Exponential, capped at a minute.
    public var backoff: (Int) -> Duration = { attempt in .seconds(min(60, 1 << min(attempt, 6))) }
    /// Why the last attempt failed, kept while reconnecting so the UI can say so.
    @Published public private(set) var lastConnectError: String?

    private var wantsConnection = false
    private var connecting = false
    private var attempts = 0
    private var reconnectTask: Task<Void, Never>?
    /// Where the running live thought starts in `streamingThinking`.
    private var liveThoughtFrom: String.Index?

    public func connect() async {
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        // A page and the app can both ask at once; a second connection would replace the first
        // one's listener and drop what the host sent it on connect (a waiting approval).
        guard client == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        if presence == .disconnected { presence = .connecting }
        do {
            let client = PiClient(transport: try makeTransport())
            try await client.start()
            self.client = client
            listen(to: client)
            let state = try await client.send(.getState)
            config = PiAgentConfig(state: state.data)
            presence = state.data?["isStreaming"]?.boolValue == true ? .working : .idle
            attempts = 0
            lastConnectError = nil
            try await sync()
        } catch {
            await dropConnection()
            lastConnectError = String(describing: error)
            if autoReconnect && wantsConnection {
                scheduleReconnect()
            } else {
                presence = .failed(String(describing: error))
            }
        }
    }

    /// User-initiated disconnect: stops reconnecting.
    public func disconnect() async {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await dropConnection()
        presence = .disconnected
    }

    /// After the Mac wakes or the network changes: drop the old stream and connect again now.
    public func reconnectNow() async {
        guard wantsConnection else { return }
        await dropConnection()
        presence = .reconnecting
        attempts = 0
        await connect()
    }

    private func dropConnection() async {
        listener?.cancel()
        listener = nil
        await client?.close()
        client = nil
        streamingText = ""
        streamingThinking = ""
        currentTool = nil
        liveSteps = []
        dialog = nil
    }

    private func scheduleReconnect() {
        attempts += 1
        presence = .reconnecting
        let delay = backoff(attempts)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.wantsConnection else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    /// The stream ended without a user disconnect.
    private func streamEnded() {
        client = nil
        dialog = nil
        currentTool = nil
        streamingText = ""
        if autoReconnect && wantsConnection {
            scheduleReconnect()
        } else {
            presence = .disconnected
        }
    }

    /// Pulls new entries since the stored cursor and stores them with the new cursor in one
    /// transaction. A changed session id or an unknown `since` id falls back to a full read;
    /// dedup on `(source, source_id)` makes the replay harmless.
    public func sync() async throws {
        guard let client else { throw PiClientError.disconnected }
        let state = try await client.send(.getState)
        config = PiAgentConfig(state: state.data)
        guard let sessionID = state.data?["sessionId"]?.stringValue else { return }

        let cursorKey = PiEntries.cursorSource(agentID: agentID)
        let cursor = PiEntries.Cursor(stored: try store.cursor(for: cursorKey))
        var response: PiResponse
        if let cursor, cursor.sessionID == sessionID {
            response = try await client.request(.getEntries(since: cursor.entryID))
            if !response.success {
                response = try await client.send(.getEntries(since: nil))
            }
        } else {
            response = try await client.send(.getEntries(since: nil))
        }

        let entries = response.data?["entries"]?.arrayValue ?? []
        guard let lastID = entries.last?["id"]?.stringValue else { return }
        let events = PiEntries.events(from: entries, sessionID: sessionID, agentID: agentID)
        try store.append(events, cursor: (cursorKey, PiEntries.Cursor(sessionID: sessionID, entryID: lastID).stored))
        reloadTranscript()
    }

    // MARK: - Controls (plan section 4; no new or switch session)

    /// A tool result's MCP Apps card page, read through the durable host.
    public func cardPage(_ card: ToolCard) async throws -> ToolCardPage {
        guard let client else { throw PiClientError.disconnected }
        let response = try await client.send(.readCard(server: card.server, uri: card.resourceUri))
        guard let page = ToolCardPage(json: response.data) else { throw PiClientError.rejected(command: "read_card", error: "no card page") }
        return page
    }

    /// A card's button calling one of its server's tools. Ask the user before calling this.
    public func callCardTool(_ card: ToolCard, name: String, arguments: JSONValue) async throws -> JSONValue {
        guard let client else { throw PiClientError.disconnected }
        return try await client.send(.callCardTool(server: card.server, name: name, arguments: arguments)).data ?? .null
    }

    /// Sends a prompt when idle. While working, use `steer` or `followUp` instead.
    public func send(_ text: String, images: [PiImage] = []) async {
        let text = withReactionNotes(text)
        await submit(text, .prompt(text, streamingBehavior: nil, images: images)) { response in
            if response.data?["disposition"]?.stringValue == "started" { self.presence = .working }
        }
    }

    public func steer(_ text: String, images: [PiImage] = []) async {
        let text = withReactionNotes(text)
        await submit(text, .steer(text, images: images))
    }
    public func followUp(_ text: String, images: [PiImage] = []) async {
        let text = withReactionNotes(text)
        await submit(text, .followUp(text, images: images))
    }

    /// Shows `text` as pending until a sync stores it, and drops it again if the send fails.
    private func submit(_ text: String, _ command: PiCommand, then handle: ((PiResponse) -> Void)? = nil) async {
        var attached: [PiImage] = []
        switch command {
        case .prompt(_, _, let images), .steer(_, let images), .followUp(_, let images): attached = images
        default: break
        }
        attached.forEach(AttachmentCache.store)
        // Pending, the message shows its images from the local copies, as the stored one will.
        let paths = attached.compactMap(AttachmentCache.localPath(for:))
        let visible = PiReactions.withoutNotes(text)
        let shown = paths.isEmpty ? visible : visible + "\n\nAttached images:\n" + paths.map { "- " + $0 }.joined(separator: "\n")
        let item = TranscriptItem(id: "pending:\(UUID().uuidString)", role: .user, text: shown, date: Date())
        pendingMessages.append(item)
        pendingSince[item.id] = transcript.count
        if !(await run(command, then: handle)) { dropPending(item.id) }
    }

    private func dropPending(_ id: String) {
        pendingMessages.removeAll { $0.id == id }
        pendingSince[id] = nil
    }
    /// Stops the run. Pi drops queued steers and follow-ups with it, so they go back to the composer.
    public func abort() async {
        let queued = pendingMessages
        guard await run(.abort) else { return }
        let dropped = queued.filter { item in pendingMessages.contains { $0.id == item.id } }
        dropped.forEach { dropPending($0.id) }
        // The prompt that started the run was already stored; only never-stored messages come back.
        if !dropped.isEmpty { returnedDraft = dropped.map(\.text).joined(separator: "\n") }
    }
    public func compact() async { await run(.compact) }

    /// Hands the agent an outside happening (durable hosts only); the host runs each `key` once.
    public func deliverEvent(source: String, text: String, key: String) async {
        guard config.durable else { return }
        await run(.event(source: source, text: text, key: key))
    }

    public func answer(_ answer: PiDialogAnswer) async {
        guard let client, let dialog else { return }
        do {
            try await client.answer(dialog, with: answer)
            self.dialog = nil
            _ = try? store.append([ApprovalLog.event(agentID: agentID, dialog: dialog, answer: answer)])
            approvalsVersion += 1
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Bumped when an approval is logged, so the inspector re-reads the log.
    @Published public private(set) var approvalsVersion = 0

    // MARK: - Model (plan 3c: locked by default; switches apply after the turn settles)

    /// Asks the agent which models it offers. Leaves the list empty if it doesn't say.
    public func loadAvailableModels() async {
        guard let client, let response = try? await client.request(.getAvailableModels), response.success else { return }
        availableModels = (response.data?["models"]?.arrayValue ?? []).compactMap { PiModel(json: $0) }
    }

    /// Sends `set_model`, never while locked. While a turn runs, the switch waits for it to settle.
    public func switchModel(to model: PiModel, reason: String = "Switched in Tavern") async throws {
        guard !modelLocked else { throw ModelSwitchError.locked }
        guard model != config.model else { throw ModelSwitchError.unchanged }
        guard client != nil else { throw ModelSwitchError.notConnected }
        if isWorking {
            pendingModel = model
            pendingReason = reason
            return
        }
        try await applyModel(model, reason: reason)
    }

    /// Switches back to the model of the last turn that settled cleanly. Untested as recovery.
    public func revertToLastKnownGood() async throws {
        guard let good = lastKnownGoodModel else { throw ModelSwitchError.rejected("no last known good model yet") }
        try await switchModel(to: good, reason: "Revert to last known good")
    }

    public func cancelPendingModel() { pendingModel = nil }

    private func applyModel(_ model: PiModel, reason: String) async throws {
        guard !modelLocked else { throw ModelSwitchError.locked }
        guard let client else { throw ModelSwitchError.notConnected }
        let response = try await client.request(.setModel(model))
        guard response.success else { throw ModelSwitchError.rejected(response.error ?? "no reason given") }
        let from = config.model
        config.model = PiModel(json: response.data) ?? model
        try store.append([ModelChangeLog.event(agentID: agentID, from: from, to: model, reason: reason)])
        reloadTranscript()
    }

    @discardableResult
    private func run(_ command: PiCommand, then handle: ((PiResponse) -> Void)? = nil) async -> Bool {
        guard let client else {
            lastError = "Not connected"
            return false
        }
        do {
            let response = try await client.send(command)
            lastError = nil
            handle?(response)
            if command == .compact || command == .abort { try await sync() }
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    // MARK: - Events

    private func listen(to client: PiClient) {
        listener = Task { [weak self] in
            for await record in client.records {
                guard let self, !Task.isCancelled else { return }
                await self.handle(record)
            }
            guard let self, !Task.isCancelled else { return }
            self.streamEnded()
        }
    }

    func handle(_ record: PiRecord) async {
        switch record {
        case .dialog(let dialog):
            self.dialog = dialog
        case .extensionNotice(let method, let raw):
            if method == "notify", let message = raw["message"]?.stringValue {
                notices.append(message)
            }
        case .response:
            break
        case .event(let type, let raw):
            switch type {
            case "agent_start":
                presence = .working
                turnFailed = false
            case "agent_end", "message_end":
                endLiveThought()
                if raw["message"]?["stopReason"]?.stringValue == "error" { turnFailed = true }
            case "message_update":
                let update = raw["assistantMessageEvent"]
                let delta = update?["delta"]?.stringValue ?? ""
                switch update?["type"]?.stringValue ?? "" {
                case "text_delta":
                    endLiveThought()
                    streamingText += delta
                case "thinking_delta":
                    updateLiveThought(adding: delta)
                default: break
                }
            case "tool_execution_start":
                let name = raw["toolName"]?.stringValue ?? "tool"
                currentTool = name
                endLiveThought()
                let call = PiToolCall(id: raw["toolCallId"]?.stringValue ?? UUID().uuidString, name: name,
                                      arguments: raw["args"] ?? .null)
                liveSteps.append(PiStep(call: call, started: Date()))
            case "tool_execution_end":
                currentTool = nil
                let id = raw["toolCallId"]?.stringValue
                if let index = liveSteps.lastIndex(where: { $0.isRunning && (id == nil || $0.id == id) }) {
                    liveSteps[index].ended = Date()
                    liveSteps[index].failed = raw["isError"]?.boolValue == true
                }
            case "agent_settled":
                // `agent_end` can be followed by retries or compaction; only settled means done.
                presence = .idle
                currentTool = nil
                try? await sync()
                streamingText = ""
                streamingThinking = ""
                liveSteps = []
                if !turnFailed, transcript.last?.role == .assistant, let model = config.model {
                    modelLocks.setLastKnownGood(model, for: agentID)
                }
                if let model = pendingModel {
                    pendingModel = nil
                    do {
                        try await applyModel(model, reason: pendingReason)
                    } catch {
                        lastError = String(describing: error)
                    }
                }
            default:
                if type.contains("compaction") && type.hasSuffix("end") {
                    try? await sync()
                }
            }
        }
    }

    /// Thinking shows in the live step list as a running thought step, titled by its first line,
    /// until the model moves on to text or a tool call.
    private func updateLiveThought(adding delta: String) {
        if liveSteps.last?.kind != .thought || liveSteps.last?.isRunning != true {
            liveThoughtFrom = streamingThinking.endIndex
            liveSteps.append(PiStep(thoughtID: "thought:\(UUID().uuidString)", thinking: "", started: Date()))
        }
        streamingThinking += delta
        let from = liveThoughtFrom.flatMap { $0 <= streamingThinking.endIndex ? $0 : nil } ?? streamingThinking.startIndex
        liveSteps[liveSteps.count - 1].title = PiStep.thoughtSummary(String(streamingThinking[from...].prefix(400)))
    }

    private func endLiveThought() {
        guard let index = liveSteps.indices.last, liveSteps[index].kind == .thought, liveSteps[index].isRunning else { return }
        liveSteps[index].ended = Date()
    }

    private func reloadTranscript() {
        let events = (try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? []
        transcript = events.compactMap(TranscriptItem.init(event:))
        loadReactions()
        // A pending message is done once a user row with its text lands after it was sent.
        for item in pendingMessages {
            let start = min(pendingSince[item.id] ?? 0, transcript.count)
            if transcript[start...].contains(where: { $0.role == .user && $0.text == item.text }) { dropPending(item.id) }
        }
    }
}
