import Foundation

/// A reference to one transcript result, or an explicitly identified stream of whole-widget
/// replacements. Legacy pins stay snapshots; titles never establish identity.
public struct PinnedCard: Codable, Equatable, Identifiable, Sendable {
    public struct LiveReference: Codable, Equatable, Sendable {
        public let server: String
        public let resourceUri: String
        public let widgetID: String
        public let minimumRevision: Int
    }

    public enum Resolution: Equatable, Sendable {
        case available(ToolCard)
        case missingSource
        case conflictingRevision(Int)

        public var card: ToolCard? {
            if case .available(let card) = self { return card }
            return nil
        }
    }

    public let agentID: String
    /// The original row is retained for provenance, including for a live pin.
    public let rowID: String
    public let live: LiveReference?
    /// nil preserves the original individual-agent pin namespace.
    public let projectID: String?
    public var id: String {
        let scope = projectID.map { "project:\($0.utf8.count):\($0):" } ?? ""
        if let live {
            return scope + "live:" + [agentID, live.server, live.resourceUri, live.widgetID]
                .map { "\($0.utf8.count):\($0)" }.joined()
        }
        return scope + "\(agentID.count):\(agentID)\(rowID)"
    }

    public init(agentID: String, rowID: String, projectID: String? = nil) {
        self.agentID = agentID
        self.rowID = rowID
        self.projectID = projectID
        self.live = nil
    }

    /// Opt in only when the producer supplied a valid explicit identity and revision.
    public init?(following card: ToolCard, agentID: String, rowID: String, projectID: String? = nil) {
        guard let widget = card.widgetRevision else { return nil }
        self.agentID = agentID
        self.rowID = rowID
        self.projectID = projectID
        self.live = LiveReference(server: card.server, resourceUri: card.resourceUri,
                                  widgetID: widget.id, minimumRevision: widget.revision)
    }

    public func resolve(in rows: [PiThreadRow], agentID: String) -> ToolCard? {
        resolution(in: rows, agentID: agentID).card
    }

    /// The explicit agent argument prevents accidentally resolving against another agent's
    /// rows. Higher revisions win regardless of arrival order; a conflicting equal revision
    /// fails closed rather than choosing whichever unrelated payload happened to arrive last.
    public func resolution(in rows: [PiThreadRow], agentID: String) -> Resolution {
        guard self.agentID == agentID else { return .missingSource }
        let cards = Self.cards(in: rows)
        guard let live else {
            return cards.first(where: { $0.rowID == rowID }).map { .available($0.card) } ?? .missingSource
        }
        var newest: (revision: Int, card: ToolCard)?
        var conflict = false
        for (_, card) in cards {
            guard card.server == live.server, card.resourceUri == live.resourceUri,
                  let widget = card.widgetRevision, widget.id == live.widgetID,
                  widget.revision >= live.minimumRevision else { continue }
            if newest == nil || widget.revision > newest!.revision {
                newest = (widget.revision, card)
                conflict = false
            } else if widget.revision == newest!.revision,
                      card.structuredContent != newest!.card.structuredContent {
                conflict = true
            }
        }
        guard let newest else { return .missingSource }
        return conflict ? .conflictingRevision(newest.revision) : .available(newest.card)
    }

    private static func cards(in rows: [PiThreadRow]) -> [(rowID: String, card: ToolCard)] {
        rows.flatMap { row in
            switch row {
            case .card(_, let card): return [(row.id, card)]
            case .background(let run): return cards(in: run.rows)
            default: return []
            }
        }
    }
}

/// Atomic persistence; a failed save leaves the previous pins intact.
public enum PinnedCardFile {
    public static func load(from url: URL) throws -> [PinnedCard] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PinnedCard].self, from: Data(contentsOf: url))
    }
    public static func save(_ pins: [PinnedCard], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var seen = Set<String>()
        let unique = pins.filter { seen.insert($0.id).inserted }
        try JSONEncoder().encode(unique).write(to: url, options: .atomic)
    }
}
