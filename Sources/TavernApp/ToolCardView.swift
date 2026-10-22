import AppKit
import CryptoKit
import SwiftUI
import TavernCore
import WebKit

/// An MCP Apps card (SEP-1865) in a Pi thread: the server's HTML page, run as an MCP Apps host
/// would. The page can't reach the network (its content policy allows inline code and only the
/// image hosts the card declares), can't navigate, and keeps no storage. Links open in the
/// browser; a button that runs a tool asks first.
struct ToolCardView: View {
    let card: ToolCard
    @ObservedObject var session: PiAgentSession
    @State private var page: ToolCardPage?
    @State private var failure: String?
    @State private var height: CGFloat

    init(card: ToolCard, session: PiAgentSession) {
        self.card = card
        self.session = session
        // The size it last drew at, so scrolling back to it doesn't jump from a placeholder.
        _height = State(initialValue: CardHeights.height(for: card) ?? 120)
    }

    var body: some View {
        Group {
            if let page {
                CardWebView(card: card, page: page, session: session, height: $height)
                    .frame(height: height)
            } else if let failure {
                Label("Couldn't show the \(card.toolName) card: \(failure)", systemImage: "exclamationmark.triangle")
                    .tavernFont(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if page?.prefersBorder ?? true { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // The thread can show from the store before the agent connects; load (again) once it does.
        .task(id: "\(card.resourceUri) \(session.presence.label)") {
            if page == nil, session.presence != .idle, session.presence != .working, let cached = ToolCardCache.load(card, agentID: session.agentID) {
                page = cached
            }
            guard page == nil || failure != nil, session.presence == .idle || session.presence == .working else { return }
            do {
                let fresh = try await session.cardPage(card)
                ToolCardCache.save(fresh, for: card, agentID: session.agentID)
                page = fresh
                failure = nil
            } catch {
                // An older card its server no longer offers still shows from the last copy.
                if let cached = ToolCardCache.load(card, agentID: session.agentID) { page = cached } else { failure = String(describing: error) }
            }
        }
    }
}

private struct CardWebView: NSViewRepresentable {
    let card: ToolCard
    let page: ToolCardPage
    let session: PiAgentSession
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> CardHost { CardHost(card: card, session: session, height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        // The page talks to `window.parent` as if framed; route that to Tavern.
        controller.addUserScript(WKUserScript(source: """
            window.parent = { postMessage: (message) => window.webkit.messageHandlers.mcp.postMessage(JSON.stringify(message)) };
            window.addEventListener("error", (e) => window.webkit.messageHandlers.mcp.postMessage(JSON.stringify({ method: "tavern/log", params: { message: String(e.message) + " @" + e.lineno } })));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let tint = Self.tintScript() {
            controller.addUserScript(WKUserScript(source: tint, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.add(context.coordinator, name: "mcp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        context.coordinator.theme = Self.theme(colorScheme, view, page: page)
        // The content policy is spliced into the card's own HTML, so WebKit also blocks every load
        // but data: and the card's declared image hosts, whatever the page's markup does.
        let page = page
        Task { @MainActor in
            if let rules = await CardNetworkRules.list(imageDomains: page.imageDomains) { controller.add(rules) }
            view.loadHTMLString(Self.withPolicy(page), baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.setTheme(Self.theme(colorScheme, view, page: page))
    }

    /// The appearance the card is drawn in; SwiftUI's color scheme can lag the window's. Cards
    /// only know light and dark; Parchment and Hearth tint them on Tavern's side.
    static func theme(_ scheme: ColorScheme, _ view: NSView, page: ToolCardPage) -> String {
        let appearance = view.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: CardHost) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mcp")
    }

    /// A party theme's tint, laid over the card by Tavern so any card follows the theme without
    /// knowing about it: hues warmed toward sepia, then the page color multiplied in (Parchment:
    /// white turns to parchment, ink stays ink) or screened in (Hearth: black turns to umber,
    /// light text stays light).
    static func tintScript() -> String? {
        let theme = Theme.current
        guard theme.palette != nil else { return nil }
        let blend = theme == .parchment ? "multiply" : "screen"
        let base = theme == .parchment ? "#f3e8cf" : "#2a1e16"
        let css = "html{filter:sepia(.35) saturate(1.05)}html::after{content:'';position:fixed;inset:0;pointer-events:none;background:\(base);mix-blend-mode:\(blend);z-index:2147483647}"
        return "(()=>{const s=document.createElement('style');s.textContent=\"\(css)\";(document.head||document.documentElement).appendChild(s);})();"
    }

    /// The page with Tavern's content policy first in `<head>`. Policies only add up, so a policy
    /// the page carries can tighten this one but never loosen it.
    static func withPolicy(_ page: ToolCardPage) -> String {
        let images = (["data:"] + page.imageDomains).joined(separator: " ")
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src \(images); font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        if let head = page.html.range(of: "<head>", options: .caseInsensitive) {
            var html = page.html
            html.insert(contentsOf: meta, at: head.upperBound)
            return html
        }
        return "<!doctype html><html><head>\(meta)</head><body>\(page.html)</body></html>"
    }
}

/// The host side of the MCP Apps protocol for one card: JSON-RPC over the page's messages.
@MainActor
final class CardHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let card: ToolCard
    let session: PiAgentSession
    var height: Binding<CGFloat>
    weak var webView: WKWebView?
    var theme = "light"
    private var initialized = false
    private var loaded = false

    init(card: ToolCard, session: PiAgentSession, height: Binding<CGFloat>) {
        self.card = card
        self.session = session
        self.height = height
    }

    func setTheme(_ value: String) {
        guard value != theme else { return }
        theme = value
        if initialized { notify("ui/notifications/host-context-changed", ["theme": .string(value)]) }
    }

    // Only the card itself loads; links and redirects never navigate the frame.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !loaded, action.request.url?.absoluteString == "about:blank" {
            loaded = true
            return .allow
        }
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let json = try? JSONValue.decode(data), let method = json["method"]?.stringValue else { return }
        let id = json["id"]
        let params = json["params"] ?? .object([:])
        switch method {
        case "ui/initialize":
            respond(id, result: [
                "protocolVersion": params["protocolVersion"] ?? .string("2026-01-26"),
                "hostInfo": ["name": "Tavern", "version": "1"],
                "hostCapabilities": ["openLinks": .object([:]), "serverTools": .object([:])],
                "hostContext": [
                    "theme": .string(theme),
                    "displayMode": "inline",
                    "availableDisplayModes": .array(["inline"]),
                    "platform": "desktop",
                    "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
                    "timeZone": .string(TimeZone.current.identifier),
                    "toolInfo": ["tool": ["name": .string(card.toolName)]],
                ],
            ])
        case "ui/notifications/initialized":
            initialized = true
            notify("ui/notifications/tool-input", ["arguments": card.arguments])
            notify("ui/notifications/tool-result", ["content": .array([]), "structuredContent": card.structuredContent])
        case "ui/notifications/size-changed":
            if let h = params["height"]?.doubleValue {
                let value = min(max(CGFloat(h), 40), 640)
                height.wrappedValue = value
                CardHeights.remember(value, for: card)
            }
        case "ui/open-link":
            if let raw = params["url"]?.stringValue, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                respond(id, result: [:])
            } else {
                respond(id, error: "Only web links open")
            }
        case "tools/call":
            callTool(id: id, params: params)
        case "tavern/log":
            NSLog("Tavern card %@: %@", card.resourceUri, params["message"]?.stringValue ?? "")
        case "ping":
            respond(id, result: [:])
        default:
            if id != nil { respond(id, error: "\(method) isn't supported here") }
        }
    }

    /// A card button running a tool: ask, then run it on the card's own server.
    private func callTool(id: JSONValue?, params: JSONValue) {
        guard let name = params["name"]?.stringValue else { return respond(id, error: "No tool name") }
        let alert = NSAlert()
        alert.messageText = "Run \(name)?"
        alert.informativeText = "The \(card.toolName) card wants to run \(name) on \(card.server)."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Don't Run")
        guard alert.runModal() == .alertFirstButtonReturn else { return respond(id, error: "The user declined") }
        Task {
            do {
                let result = try await session.callCardTool(card, name: name, arguments: params["arguments"] ?? .object([:]))
                if case .object(let object) = result { respond(id, result: object) } else { respond(id, result: [:]) }
            } catch {
                respond(id, error: String(describing: error))
            }
        }
    }

    private func respond(_ id: JSONValue?, result: [String: JSONValue]) {
        guard let id else { return }
        post(["jsonrpc": "2.0", "id": id, "result": .object(result)])
    }

    private func respond(_ id: JSONValue?, error: String) {
        guard let id else { return }
        post(["jsonrpc": "2.0", "id": id, "error": ["code": .number(-32000), "message": .string(error)]])
    }

    private func notify(_ method: String, _ params: [String: JSONValue]) {
        post(["jsonrpc": "2.0", "method": .string(method), "params": .object(params)])
    }

    private func post(_ message: [String: JSONValue]) {
        guard let data = try? JSONValue.object(message).encoded(), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.dispatchEvent(new MessageEvent('message', { data: \(json) }))")
    }
}

/// Each card's last drawn height, kept across launches (the newest 500), so a card shows at its
/// real size right away instead of growing from a placeholder and pushing the thread around.
@MainActor
enum CardHeights {
    private static let key = "tavern.cardHeights"
    private static var heights: [String: Double] = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    private static var order: [String] = UserDefaults.standard.stringArray(forKey: key + ".order") ?? []

    static func id(_ card: ToolCard) -> String {
        // A stable digest (String.hashValue changes every launch).
        let content = (try? card.structuredContent.encoded()) ?? Data()
        let digest = SHA256.hash(data: content).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(card.server)|\(card.resourceUri)|\(digest)"
    }

    static func height(for card: ToolCard) -> CGFloat? { heights[id(card)].map { CGFloat($0) } }

    static func remember(_ height: CGFloat, for card: ToolCard) {
        let id = id(card)
        guard heights[id] != Double(height) else { return }
        heights[id] = Double(height)
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > 500 {
            for old in order.prefix(order.count - 500) { heights.removeValue(forKey: old) }
            order.removeFirst(order.count - 500)
        }
        UserDefaults.standard.set(heights, forKey: key)
        UserDefaults.standard.set(order, forKey: key + ".order")
    }
}

/// WebKit content rules for cards: block every load except data: URLs, the page itself
/// (about:blank) and https images from the hosts a card declares. Compiled once per host set.
@MainActor
enum CardNetworkRules {
    private static var cache: [String: WKContentRuleList] = [:]

    static func list(imageDomains: [String]) async -> WKContentRuleList? {
        let hosts = imageDomains.compactMap { URL(string: $0)?.host ?? ($0.contains("/") ? nil : $0) }.sorted()
        let key = hosts.joined(separator: ",")
        if let cached = cache[key] { return cached }
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^(data|about):"], "action": ["type": "ignore-previous-rules"]],
        ]
        for host in hosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            rules.append(["trigger": ["url-filter": "^https://\\(escaped)/", "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else { return nil }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "tavern.cards.\(key.hashValue)", encodedContentRuleList: json)
        if let list { cache[key] = list }
        return list
    }
}
