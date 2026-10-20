import Foundation

/// The user's emoji reactions to messages in a Pi thread. Pi has no reactions, so they live in
/// Tavern's event log, and the agent hears about new ones as a note on the user's next message
/// (`[Reaction] 👍 on your reply: “…”`) rather than as a turn of their own.
public enum PiReactions {
    public static let kind = "tavern.reaction"
    static let notePrefix = "[Reaction] "

    public struct Stored: Equatable, Sendable {
        public var target: String
        public var emoji: String
        public var on: Bool
        public var delivered: Bool
        public var preview: String
        var sourceID: String
        var date: Date
    }

    static func sourceID(agentID: String, target: String, emoji: String) -> String {
        "reaction:\(agentID):\(target):\(emoji)"
    }

    static func event(agentID: String, _ r: Stored) -> TavernEvent {
        let payload: JSONValue = ["type": "tavern_reaction", "target": .string(r.target), "emoji": .string(r.emoji),
                                  "on": .bool(r.on), "delivered": .bool(r.delivered), "preview": .string(r.preview)]
        return TavernEvent(source: EventSource.tavern, sourceID: r.sourceID, threadKey: PiEntries.threadKey(agentID: agentID),
                           authorAgent: "paul", sourceTS: r.date, receivedTS: r.date, kind: kind,
                           payload: (try? payload.encoded()) ?? Data())
    }

    static func stored(_ events: [TavernEvent]) -> [Stored] {
        events.filter { $0.kind == kind }.compactMap { event in
            guard let json = try? JSONValue.decode(event.payload), let target = json["target"]?.stringValue,
                  let emoji = json["emoji"]?.stringValue else { return nil }
            return Stored(target: target, emoji: emoji, on: json["on"]?.boolValue ?? false,
                          delivered: json["delivered"]?.boolValue ?? false, preview: json["preview"]?.stringValue ?? "",
                          sourceID: event.sourceID, date: event.sourceTS)
        }
    }

    /// The note added to the user's next message for reactions the agent hasn't heard about.
    static func note(for pending: [Stored]) -> String? {
        let lines = pending.filter { $0.on && !$0.delivered }.map { r -> String in
            let preview = r.preview.replacingOccurrences(of: "\n", with: " ")
            let short = preview.count > 100 ? String(preview.prefix(100)) + "…" : preview
            return "\(notePrefix)\(r.emoji) on your reply: “\(short)”"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A user message as the thread shows it: without the reaction notes Tavern added for the agent.
    public static func withoutNotes(_ text: String) -> String {
        guard text.contains(notePrefix) else { return text }
        return text.components(separatedBy: "\n").filter { !$0.hasPrefix(notePrefix) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PiAgentSession {
    /// Adds the emoji to a message, or takes it off if it's there.
    public func toggleReaction(_ emoji: String, on item: TranscriptItem) {
        guard let store = reactionStore else { return }
        let id = PiReactions.sourceID(agentID: agentID, target: item.id, emoji: emoji)
        let all = PiReactions.stored((try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? [])
        if var existing = all.first(where: { $0.sourceID == id }) {
            // Taking one off before the agent heard about it means it never hears; putting it
            // back on later counts as new.
            existing.on.toggle()
            if existing.on { existing.delivered = false }
            try? store.replace(PiReactions.event(agentID: agentID, existing))
        } else {
            let new = PiReactions.Stored(target: item.id, emoji: emoji, on: true, delivered: false,
                                         preview: item.text, sourceID: id, date: Date())
            _ = try? store.append([PiReactions.event(agentID: agentID, new)])
        }
        loadReactions()
    }

    /// Reactions per transcript item id, from the event log.
    func loadReactions() {
        guard let store = reactionStore else { return }
        let all = PiReactions.stored((try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? [])
        var map: [String: [Reaction]] = [:]
        for r in all where r.on { map[r.target, default: []].append(Reaction(emoji: r.emoji, fromMe: true)) }
        reactions = map
    }

    /// `text` with notes for reactions the agent hasn't heard about, marking them heard.
    func withReactionNotes(_ text: String) -> String {
        guard let store = reactionStore else { return text }
        let all = PiReactions.stored((try? store.events(threadKey: PiEntries.threadKey(agentID: agentID))) ?? [])
        guard let note = PiReactions.note(for: all) else { return text }
        for var r in all where r.on && !r.delivered {
            r.delivered = true
            try? store.replace(PiReactions.event(agentID: agentID, r))
        }
        return text + "\n\n" + note
    }
}
