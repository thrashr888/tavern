import Foundation

/// An emoji someone put on a message: an iMessage tapback, or the user's reaction to a Pi reply.
public struct Reaction: Equatable, Hashable, Sendable {
    public var emoji: String
    public var fromMe: Bool

    public init(emoji: String, fromMe: Bool) {
        self.emoji = emoji
        self.fromMe = fromMe
    }
}

/// An iMessage tapback, which Messages stores as its own message: `Liked “…”`, `Reacted 🎉 to “…”`,
/// `Removed a heart from “…”`. The quote is the start of the message it points to.
public struct Tapback: Equatable, Sendable {
    public var emoji: String
    public var quoted: String
    public var removed: Bool

    static let verbs: [(String, String)] = [
        ("Loved", "❤️"), ("Liked", "👍"), ("Disliked", "👎"), ("Laughed at", "😂"),
        ("Emphasized", "‼️"), ("Questioned", "❓"),
    ]
    static let removals: [(String, String)] = [
        ("Removed a heart from", "❤️"), ("Removed a like from", "👍"), ("Removed a dislike from", "👎"),
        ("Removed a laugh from", "😂"), ("Removed an exclamation from", "‼️"), ("Removed a question mark from", "❓"),
    ]

    public init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func quote(after prefix: String) -> String? {
            guard text.hasPrefix(prefix + " ") else { return nil }
            var rest = text.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces)
            guard let open = rest.first, "“\"".contains(open), let close = rest.last, "”\"".contains(close), rest.count >= 2 else { return nil }
            rest = String(rest.dropFirst().dropLast())
            return rest
        }
        for (verb, emoji) in Self.verbs {
            if let q = quote(after: verb) { self.init(emoji: emoji, quoted: q, removed: false); return }
        }
        for (verb, emoji) in Self.removals {
            if let q = quote(after: verb) { self.init(emoji: emoji, quoted: q, removed: true); return }
        }
        // "Reacted 🎉 to “…”" (any emoji), and "Removed 🎉 from “…”".
        for (lead, middle, removed) in [("Reacted ", " to ", false), ("Removed ", " from ", true)] where text.hasPrefix(lead) {
            let afterLead = text.dropFirst(lead.count)
            guard let range = afterLead.range(of: middle) else { continue }
            let emoji = String(afterLead[..<range.lowerBound])
            guard !emoji.isEmpty, emoji.count <= 3, emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }),
                  let q = Self.quote(String(afterLead[range.upperBound...])) else { continue }
            self.init(emoji: emoji, quoted: q, removed: removed)
            return
        }
        return nil
    }

    private static func quote(_ raw: String) -> String? {
        let rest = raw.trimmingCharacters(in: .whitespaces)
        guard rest.count >= 2, let open = rest.first, "“\"".contains(open), let close = rest.last, "”\"".contains(close) else { return nil }
        return String(rest.dropFirst().dropLast())
    }

    public init(emoji: String, quoted: String, removed: Bool) {
        self.emoji = emoji
        self.quoted = quoted
        self.removed = removed
    }

    /// Whether `text` is the message this tapback quotes. Messages quotes the start of the text,
    /// sometimes cut with an ellipsis.
    func points(to text: String) -> Bool {
        let quote = quoted.hasSuffix("…") ? String(quoted.dropLast()) : quoted
        let normalized = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let q = normalized(quote), t = normalized(text)
        return !q.isEmpty && (t == q || t.hasPrefix(q))
    }
}

/// A message with the reactions that point at it.
public struct ReactedMessage: Equatable, Identifiable, Sendable {
    public var message: IMessage
    public var reactions: [Reaction]
    public var id: String { message.id }
}

extension IMessage {
    public var tapback: Tapback? { Tapback(text: text) }

    /// Folds tapbacks into the messages they point at (the latest earlier message whose text they
    /// quote). A tapback whose message isn't in view stays as a plain message.
    public static func withReactions(_ messages: [IMessage]) -> [ReactedMessage] {
        var out: [ReactedMessage] = []
        for message in messages {
            guard let tapback = message.tapback,
                  let index = out.lastIndex(where: { $0.message.tapback == nil && tapback.points(to: $0.message.text) }) else {
                out.append(ReactedMessage(message: message, reactions: []))
                continue
            }
            let reaction = Reaction(emoji: tapback.emoji, fromMe: message.fromMe)
            if tapback.removed {
                out[index].reactions.removeAll { $0 == reaction }
            } else if !out[index].reactions.contains(reaction) {
                out[index].reactions.append(reaction)
            }
        }
        return out
    }
}
