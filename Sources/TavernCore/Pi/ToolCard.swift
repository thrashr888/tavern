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
