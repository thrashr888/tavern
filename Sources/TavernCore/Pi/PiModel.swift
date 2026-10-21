import Foundation

/// A Pi agent's model as `get_state` reports it (plan 3c). Read-only in Tavern unless unlocked.
public struct PiModel: Codable, Equatable, Hashable, Sendable {
    public var provider: String
    public var id: String

    public init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }

    /// "provider/id", or just the id when there's no provider.
    public var label: String { provider.isEmpty ? id : "\(provider)/\(id)" }

    /// A short name for chips: "claude-sonnet-4-6" is "Sonnet 4.6", "qwen3.5:35b-a3b-coding" is
    /// "qwen3.5:35b". Falls back to the id.
    public var shortName: String {
        if id.hasPrefix("claude-") {
            var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if parts.last.map({ $0.count == 8 && Int($0) != nil }) == true { parts.removeLast() } // date suffix
            guard let family = parts.first, parts.count > 1, parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return id }
            return family.capitalized + " " + parts.dropFirst().joined(separator: ".")
        }
        if let dash = id.firstIndex(of: "-"), id.contains(":") { return String(id[..<dash]) }
        return id
    }

    /// `{"provider": ..., "id": ...}` as in `get_state.model` and `get_available_models`.
    public init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue ?? json["modelId"]?.stringValue else { return nil }
        self.init(provider: json["provider"]?.stringValue ?? "", id: id)
    }
}

/// The read-only part of `get_state` that the Agent config page shows.
public struct PiAgentConfig: Equatable, Sendable {
    public var model: PiModel?
    public var thinkingLevel: String?
    public var sessionID: String?
    /// True when the far end is a Tavern durable host rather than `pi --mode rpc`.
    public var durable: Bool
    /// The host's heartbeat, when the agent has a HEARTBEAT.md.
    public var heartbeat: PiHeartbeat?
    /// Tokens and cost so far (durable hosts, from Pi Durable's usage document).
    public var usage: PiUsage?

    public init(model: PiModel? = nil, thinkingLevel: String? = nil, sessionID: String? = nil, durable: Bool = false,
                heartbeat: PiHeartbeat? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.sessionID = sessionID
        self.durable = durable
        self.heartbeat = heartbeat
    }

    public init(state: JSONValue?) {
        self.init(
            model: PiModel(json: state?["model"]),
            thinkingLevel: state?["thinkingLevel"]?.stringValue,
            sessionID: state?["sessionId"]?.stringValue,
            durable: state?["durable"]?.boolValue == true,
            heartbeat: PiHeartbeat(json: state?["heartbeat"])
        )
        usage = PiUsage(json: state?["usage"])
    }
}

/// How often the durable host prompts the agent with its HEARTBEAT.md, and when.
public struct PiHeartbeat: Equatable, Sendable {
    public var everyMinutes: Int
    public var last: Date?
    public var next: Date?
    /// The host's checks this week: beats that woke the agent, and quiet ones that cost nothing.
    public var wokeThisWeek: Int?
    public var quietThisWeek: Int?

    public init(everyMinutes: Int, last: Date? = nil, next: Date? = nil) {
        self.everyMinutes = everyMinutes
        self.last = last
        self.next = next
    }

    init?(json: JSONValue?) {
        guard let minutes = json?["everyMinutes"]?.doubleValue, minutes > 0 else { return nil }
        self.init(everyMinutes: Int(minutes), last: PiEntries.parseTimestamp(json?["last"]?.stringValue),
                  next: PiEntries.parseTimestamp(json?["next"]?.stringValue))
        if let week = json?["checks"]?["week"] {
            wokeThisWeek = week["woke"]?.doubleValue.map(Int.init)
            quietThisWeek = week["quiet"]?.doubleValue.map(Int.init)
        }
    }

    /// "Every 30 min · next 4:30 PM".
    public var summary: String {
        var parts = ["Every \(everyMinutes) min"]
        if let next { parts.append("next \(next.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }
}

/// Per-agent model-switch lock, locked by default (2026-10-15 05:08). While locked Tavern
/// never sends `set_model`. It guards Tavern only, not the host or Pi's own `/model` command.
/// Also remembers each agent's last known good model: the model of the last turn that settled
/// without an error.
public struct ModelLockStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isLocked(_ agentID: String) -> Bool {
        defaults.object(forKey: "tavern.modelLock.\(agentID)") as? Bool ?? true
    }

    public func setLocked(_ locked: Bool, for agentID: String) {
        defaults.set(locked, forKey: "tavern.modelLock.\(agentID)")
    }

    public func lastKnownGood(_ agentID: String) -> PiModel? {
        guard let data = defaults.data(forKey: "tavern.lastGoodModel.\(agentID)") else { return nil }
        return try? JSONDecoder().decode(PiModel.self, from: data)
    }

    public func setLastKnownGood(_ model: PiModel, for agentID: String) {
        defaults.set(try? JSONEncoder().encode(model), forKey: "tavern.lastGoodModel.\(agentID)")
    }
}

public enum ModelSwitchError: Error, Equatable, CustomStringConvertible {
    case locked
    case unchanged
    case notConnected
    case rejected(String)

    public var description: String {
        switch self {
        case .locked: return "Model switching is locked for this agent"
        case .unchanged: return "That model is already in use"
        case .notConnected: return "Not connected"
        case .rejected(let reason): return "The agent refused the switch: \(reason)"
        }
    }
}

/// Tavern's own log of model switches it sent, stored in the event log next to the agent's thread
/// so the transcript shows a line for each one.
public enum ModelChangeLog {
    public static let kind = "tavern.model_change"

    public static func event(agentID: String, from: PiModel?, to: PiModel, reason: String,
                             date: Date = Date()) -> TavernEvent {
        var payload: [String: JSONValue] = [
            "type": "tavern_model_change",
            "provider": .string(to.provider),
            "modelId": .string(to.id),
            "reason": .string(reason),
        ]
        if let from { payload["from"] = .string(from.label) }
        return TavernEvent(
            source: EventSource.tavern,
            sourceID: "model:\(agentID):\(UUID().uuidString)",
            threadKey: PiEntries.threadKey(agentID: agentID),
            authorAgent: "paul",
            sourceTS: date,
            receivedTS: date,
            kind: kind,
            payload: (try? JSONValue.object(payload).encoded()) ?? Data()
        )
    }

    /// The switches for one agent, newest first.
    public static func entries(agentID: String, store: EventStore) -> [Entry] {
        let events = (try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? []
        return events.filter { $0.kind == kind }.compactMap(Entry.init(event:)).reversed()
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String
        public var date: Date
        public var from: String?
        public var to: PiModel
        public var reason: String

        init?(event: TavernEvent) {
            guard let json = try? JSONValue.decode(event.payload), let to = PiModel(json: json) else { return nil }
            id = event.sourceID
            date = event.sourceTS
            from = json["from"]?.stringValue
            self.to = to
            reason = json["reason"]?.stringValue ?? ""
        }
    }
}

/// What a durable session has spent: tokens in and out (with cache) and cost in dollars.
public struct PiUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cost: Double

    init?(json: JSONValue?) {
        guard let json, json["input"] != nil else { return nil }
        input = Int(json["input"]?.doubleValue ?? 0)
        output = Int(json["output"]?.doubleValue ?? 0)
        cacheRead = Int(json["cacheRead"]?.doubleValue ?? 0)
        cost = json["cost"]?.doubleValue ?? 0
    }

    public var tokens: Int { input + output + cacheRead }

    /// "$4.12 · 1.3M tokens".
    public var summary: String {
        let tokenText = tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : tokens >= 1_000 ? "\(tokens / 1_000)K" : "\(tokens)"
        return (cost > 0 ? String(format: "$%.2f · ", cost) : "") + "\(tokenText) tokens"
    }
}
