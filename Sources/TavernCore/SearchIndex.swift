import Foundation

/// What ⌘K search indexes for each event (plan 3f): Pi user and assistant text, and the subject,
/// sender and body of Smithery mail. Tool results, thinking and Tavern's own logs aren't indexed.
public enum SearchText {
    public static func text(for event: TavernEvent) -> String? {
        switch event.source {
        case EventSource.pi:
            guard let item = TranscriptItem(event: event), item.role == .user || item.role == .assistant else { return nil }
            return item.text.isEmpty ? nil : item.text
        case EventSource.gmail:
            guard let json = try? JSONValue.decode(event.payload) else { return nil }
            let parts = ["subject", "from", "body"].compactMap { json[$0]?.stringValue }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// Turns what the user typed into an FTS5 query: every word must match, the last as a prefix.
    /// Quoting each word keeps FTS5 syntax characters from breaking the query.
    public static func ftsQuery(_ text: String) -> String? {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { index, word in
            index == words.count - 1 ? "\"\(word)\"*" : "\"\(word)\""
        }.joined(separator: " ")
    }
}

/// One local search result: the matching event and a short snippet around the match.
public struct SearchHit: Equatable, Sendable {
    public var event: TavernEvent
    public var snippet: String
}
