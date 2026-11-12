import CryptoKit
import Foundation

/// An MCP Apps card (SEP-1865) that came with a tool result: which server's `ui://` resource
/// shows it, and the call and result it shows. The durable host adds it as `details.ui`.
public struct ToolCard: Equatable, Sendable {
    public var server: String
    public var resourceUri: String
    public var toolName: String
    /// The call's arguments, sent to the card as `ui/notifications/tool-input`.
    public var arguments: JSONValue
    /// The tool's structured result, sent to the card as `ui/notifications/tool-result`.
    public var structuredContent: JSONValue

    /// Agent-authored widget headings occasionally contain a literal JSON Unicode escape.
    /// Repair only their presentation, including old saved cards. The original tool input,
    /// result, code, URLs and all other card fields must keep their exact contents.
    public var displayStructuredContent: JSONValue {
        guard server == "cards" else { return structuredContent }
        let widget = String(resourceUri.dropFirst("ui://cards/".count))
        guard resourceUri == "ui://cards/\(widget)",
              ["chart", "checklist", "timeline", "calendar", "compose"].contains(widget),
              case .object(var content) = structuredContent,
              case .object(var body) = content[widget] else { return structuredContent }
        Self.decodeTitle(in: &body)
        if widget == "compose", case .array(let blocks) = body["blocks"] {
            body["blocks"] = .array(blocks.map(Self.displayBlock))
        }
        content[widget] = .object(body)
        return .object(content)
    }

    private static func displayBlock(_ value: JSONValue) -> JSONValue {
        guard case .object(var block) = value, let type = block["type"]?.stringValue else { return value }
        if ["chart", "checklist", "timeline", "calendar"].contains(type), case .object(var widget) = block[type] {
            decodeTitle(in: &widget)
            block[type] = .object(widget)
        } else if type == "row", case .array(let blocks) = block["blocks"] {
            block["blocks"] = .array(blocks.map(displayBlock))
        } else if type == "table" {
            decodeTitle(in: &block)
        }
        return .object(block)
    }

    private static func decodeTitle(in object: inout [String: JSONValue]) {
        guard let title = object["title"]?.stringValue else { return }
        // Parse only complete Unicode escape runs, once. JSONDecoder handles surrogate pairs;
        // malformed sequences and explicitly doubled backslashes remain literal. This is not
        // a second JSON decode of the payload, and the card still HTML-escapes the resulting text.
        let pattern = #"(?<!\\)\\u[0-9a-fA-F]{4}(?:\\u[0-9a-fA-F]{4})*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let result = NSMutableString(string: title)
        for match in regex.matches(in: title, range: NSRange(title.startIndex..., in: title)).reversed() {
            let token = (title as NSString).substring(with: match.range)
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data("\"\(token)\"".utf8)) else { continue }
            result.replaceCharacters(in: match.range, with: decoded)
        }
        object["title"] = .string(result as String)
    }

    public init(server: String, resourceUri: String, toolName: String, arguments: JSONValue = .object([:]),
                structuredContent: JSONValue = .null) {
        self.server = server
        self.resourceUri = resourceUri
        self.toolName = toolName
        self.arguments = arguments
        self.structuredContent = structuredContent
    }

    /// From a tool result message's `details.ui`; only `ui://` resources count.
    init?(details: JSONValue?, toolName: String) {
        guard let ui = details?["ui"], let server = ui["server"]?.stringValue,
              let uri = ui["resourceUri"]?.stringValue, uri.hasPrefix("ui://") else { return nil }
        self.init(server: server, resourceUri: uri, toolName: toolName, structuredContent: ui["structuredContent"] ?? .null)
    }
}

/// A card's page, read through the host: self-contained HTML, plus the outside hosts it may load
/// images from (its `_meta.ui.csp.resourceDomains`).
public struct ToolCardPage: Equatable, Sendable {
    public var html: String
    public var imageDomains: [String]
    public var prefersBorder: Bool

    public init(html: String, imageDomains: [String] = [], prefersBorder: Bool = true) {
        self.html = html
        self.imageDomains = imageDomains
        self.prefersBorder = prefersBorder
    }

    init?(json: JSONValue?) {
        guard let html = json?["html"]?.stringValue else { return nil }
        let meta = json?["meta"]
        // Only https origins: anything else would widen the card's content policy.
        let domains = (meta?["csp"]?["resourceDomains"]?.arrayValue ?? []).compactMap(\.stringValue).filter {
            guard let url = URL(string: $0), url.scheme == "https", url.host != nil, url.path.isEmpty || url.path == "/" else { return false }
            return !$0.contains(";") && !$0.contains(" ")
        }
        self.init(html: html, imageDomains: domains, prefersBorder: meta?["prefersBorder"]?.boolValue ?? true)
    }
}

/// Card pages kept on disk, so a card in an old message still shows after its server stops
/// offering it (or while the agent is offline). Keyed by agent, server and `ui://` URI, so one
/// agent's server can never supply the page for another agent's card.
public enum ToolCardCache {
    static var folder: URL? { TavernPaths.file("cards") }

    static func file(_ card: ToolCard, agentID: String) -> URL? {
        let key = SHA256.hash(data: Data("\(agentID)\u{0}\(card.server)\u{0}\(card.resourceUri)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(key + ".json")
    }

    public static func load(_ card: ToolCard, agentID: String) -> ToolCardPage? {
        guard let url = file(card, agentID: agentID), let data = try? Data(contentsOf: url), let json = try? JSONValue.decode(data) else { return nil }
        return ToolCardPage(json: json)
    }

    public static func save(_ page: ToolCardPage, for card: ToolCard, agentID: String) {
        guard let url = file(card, agentID: agentID), let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json: JSONValue = ["html": .string(page.html),
                               "meta": ["prefersBorder": .bool(page.prefersBorder),
                                        "csp": ["resourceDomains": .array(page.imageDomains.map(JSONValue.string))]]]
        try? json.encoded().write(to: url, options: .atomic)
    }
}
