import Foundation

/// Maps Pi session entries (`get_entries`) into Tavern's event log, and back into transcript rows.
public enum PiEntries {
    /// The cursor value stored per agent: the session id plus the last stored entry id.
    public struct Cursor: Equatable, Sendable {
        public var sessionID: String
        public var entryID: String

        public init(sessionID: String, entryID: String) {
            self.sessionID = sessionID
            self.entryID = entryID
        }

        public var stored: String { "\(sessionID)|\(entryID)" }

        public init?(stored: String?) {
            guard let parts = stored?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
            self.init(sessionID: String(parts[0]), entryID: String(parts[1]))
        }
    }

    /// Cursor key in the store. One per agent, since each agent has its own Pi.
    public static func cursorSource(agentID: String) -> String { "pi:\(agentID)" }

    /// Every Pi agent has exactly one Tavern thread, whatever Pi session it is on.
    public static func threadKey(agentID: String) -> String { "pi:\(agentID)" }

    public static func events(from entries: [JSONValue], sessionID: String, agentID: String,
                              received: Date = Date()) -> [TavernEvent] {
        entries.compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            let type = entry["type"]?.stringValue ?? "unknown"
            let role = entry["message"]?["role"]?.stringValue
            let kind = type == "message" ? "pi.message.\(role ?? "unknown")" : "pi.\(type)"
            return TavernEvent(
                source: EventSource.pi,
                sourceID: "\(sessionID):\(id)",
                threadKey: threadKey(agentID: agentID),
                authorAgent: role == "user" ? "paul" : agentID,
                sourceTS: parseTimestamp(entry["timestamp"]?.stringValue) ?? received,
                receivedTS: received,
                kind: kind,
                payload: (try? entry.encoded()) ?? Data()
            )
        }
    }

    static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// One row in a Pi agent's transcript.
public struct TranscriptItem: Equatable, Identifiable, Sendable {
    public enum Role: Equatable, Sendable {
        case user, assistant, tool, system
    }

    public var id: String
    public var role: Role
    public var text: String
    /// The model's thinking for an assistant turn, shown collapsed above the reply.
    public var thinking: String
    public var date: Date
    /// Tool calls an assistant turn made; their results arrive as later `.tool` items.
    public var toolCalls: [PiToolCall]
    /// For `.tool` items: which call this is the result of, the tool, and whether it failed.
    public var toolCallID: String?
    public var toolName: String?
    public var failed: Bool
    /// For `.tool` items: an MCP Apps card to show with the result.
    public var card: ToolCard?
    /// For an edit's result: Pi's display diff (`details.diff`).
    public var diff: String?

    public init(id: String, role: Role, text: String, thinking: String = "", date: Date,
                toolCalls: [PiToolCall] = [], toolCallID: String? = nil, toolName: String? = nil, failed: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.date = date
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.failed = failed
    }

    /// Nil for entries the transcript doesn't show (custom data, labels, usage).
    public init?(event: TavernEvent) {
        guard let entry = try? JSONValue.decode(event.payload) else { return nil }
        id = event.sourceID
        date = event.sourceTS
        thinking = ""
        toolCalls = []
        toolCallID = nil
        toolName = nil
        failed = false
        switch entry["type"]?.stringValue ?? "" {
        case "message":
            let message = entry["message"]
            switch message?["role"]?.stringValue ?? "" {
            case "user":
                role = .user
                text = PiReactions.withoutNotes(Self.text(of: message?["content"]))
            case "assistant":
                text = Self.text(of: message?["content"])
                thinking = Self.thinking(of: message?["content"])
                toolCalls = Self.toolCalls(of: message?["content"])
                // A failed or aborted model call stores an empty reply; show why instead of nothing.
                if text.isEmpty, thinking.isEmpty, let error = message?["errorMessage"]?.stringValue {
                    role = .system
                    if message?["stopReason"]?.stringValue == "aborted" {
                        text = "Aborted"
                    } else {
                        // The raw provider error; the thread shows it through `ModelError`.
                        text = error
                        failed = true
                    }
                } else {
                    role = .assistant
                }
            case "toolResult":
                role = .tool
                let name = message?["toolName"]?.stringValue ?? "tool"
                failed = message?["isError"]?.boolValue == true
                toolName = name
                toolCallID = message?["toolCallId"]?.stringValue
                text = failed ? "\(name) failed" : "Ran \(name)"
                card = failed ? nil : ToolCard(details: message?["details"], toolName: name)
                diff = failed ? nil : message?["details"]?["diff"]?.stringValue
            default:
                return nil
            }
        case "compaction":
            role = .system
            text = "Context compacted"
        case "model_change":
            role = .system
            let provider = entry["provider"]?.stringValue ?? ""
            let model = entry["modelId"]?.stringValue ?? ""
            text = "Model changed to \(provider) \(model)".trimmingCharacters(in: .whitespaces)
        case "tavern_model_change":
            role = .system
            let to = PiModel(json: entry)?.label ?? "another model"
            if let from = entry["from"]?.stringValue {
                text = "Tavern switched the model from \(from) to \(to)"
            } else {
                text = "Tavern switched the model to \(to)"
            }
        case "thinking_level_change":
            role = .system
            text = "Thinking level \(entry["thinkingLevel"]?.stringValue ?? "changed")"
        default:
            return nil
        }
        if text.isEmpty && thinking.isEmpty && toolCalls.isEmpty && role == .assistant { return nil }
    }

    /// Content is a string, or an array of blocks where only `text` blocks are shown.
    static func text(of content: JSONValue?) -> String {
        if let string = content?.stringValue { return string }
        let blocks = content?.arrayValue ?? []
        return blocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }

    /// `toolCall` blocks of an assistant message.
    static func toolCalls(of content: JSONValue?) -> [PiToolCall] {
        (content?.arrayValue ?? []).compactMap { block in
            guard block["type"]?.stringValue == "toolCall", let id = block["id"]?.stringValue else { return nil }
            return PiToolCall(id: id, name: block["name"]?.stringValue ?? "tool", arguments: block["arguments"] ?? .null)
        }
    }

    /// Joined `thinking` blocks of an assistant message.
    static func thinking(of content: JSONValue?) -> String {
        (content?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "thinking" }
            .compactMap { $0["thinking"]?.stringValue }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
