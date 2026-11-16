import Foundation

/// The cards producer's opt-in whole-widget replacement contract. IDs are exact and scoped
/// by the pin's agent, server and resource URI. Unidentified results remain snapshot-only.
public struct WidgetRevision: Equatable, Sendable {
    public let id: String
    public let revision: Int

    init?(json: JSONValue?) {
        guard let id = json?["id"]?.stringValue,
              id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil,
              // ICU's $ also accepts a final newline; require every byte to be in the grammar.
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 58, 45].contains($0) }),
              let revision = json?["revision"]?.doubleValue,
              revision.isFinite, revision >= 1, revision <= 9_007_199_254_740_991,
              revision.rounded(.towardZero) == revision else { return nil }
        self.id = id
        self.revision = Int(revision)
    }
}

extension ToolCard {
    public var widgetRevision: WidgetRevision? {
        guard server == "cards", structuredContent["ok"]?.boolValue != false,
              let kind = structuredContent["kind"]?.stringValue,
              ["chart", "checklist", "timeline", "calendar", "compose"].contains(kind),
              resourceUri == "ui://cards/\(kind)" else { return nil }
        return WidgetRevision(json: structuredContent["widget"])
    }
}
