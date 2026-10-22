import SwiftUI
import TavernCore
import UIKit
import WebKit

/// An MCP Apps card (SEP-1865), as on the Mac: the server's page in a sandboxed web view that
/// can't reach the network or navigate. Links open in Safari; a button that runs a tool asks
/// first.
struct CardView: View {
    let card: ToolCard
    @ObservedObject var session: PiAgentSession
    @State private var page: ToolCardPage?
    @State private var failure: String?
    @State private var height: CGFloat = 160

    var body: some View {
        Group {
            if let page {
                CardWebView(card: card, page: page, session: session, height: $height).frame(height: height)
            } else if let failure {
                Label("Couldn't show the \(card.toolName) card: \(failure)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: "\(card.resourceUri) \(session.presence.label)") {
            guard page == nil, session.presence == .idle || session.presence == .working else { return }
            do {
                page = try await session.cardPage(card)
                failure = nil
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

private struct CardWebView: UIViewRepresentable {
    let card: ToolCard
    let page: ToolCardPage
    let session: PiAgentSession
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> CardHost { CardHost(card: card, session: session, height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: """
            window.parent = { postMessage: (message) => window.webkit.messageHandlers.mcp.postMessage(JSON.stringify(message)) };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "mcp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.theme = colorScheme == .dark ? "dark" : "light"
        view.loadHTMLString(Self.withPolicy(page), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: CardHost) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mcp")
    }

    /// The page with Tavern's content policy first: no network, no frames, no forms.
    static func withPolicy(_ page: ToolCardPage) -> String {
        let images = (["data:"] + page.imageDomains).joined(separator: " ")
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src \(images); font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
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
    private var loaded = false

    init(card: ToolCard, session: PiAgentSession, height: Binding<CGFloat>) {
        self.card = card
        self.session = session
        self.height = height
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !loaded, action.request.url?.absoluteString == "about:blank" {
            loaded = true
            return .allow
        }
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), action.navigationType == .linkActivated {
            await UIApplication.shared.open(url)
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
                "hostContext": ["theme": .string(theme), "displayMode": "inline", "platform": "mobile",
                                "toolInfo": ["tool": ["name": .string(card.toolName)]]],
            ])
        case "ui/notifications/initialized":
            notify("ui/notifications/tool-input", ["arguments": card.arguments])
            notify("ui/notifications/tool-result", ["content": .array([]), "structuredContent": card.structuredContent])
        case "ui/notifications/size-changed":
            if let h = params["height"]?.doubleValue { height.wrappedValue = min(max(CGFloat(h), 40), 700) }
        case "ui/open-link":
            if let raw = params["url"]?.stringValue, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
                respond(id, result: [:])
            } else {
                respond(id, error: "Only web links open")
            }
        case "tools/call":
            callTool(id: id, params: params)
        case "ping":
            respond(id, result: [:])
        default:
            if id != nil { respond(id, error: "\(method) isn't supported here") }
        }
    }

    /// A card button running a tool on its own server, after the user agrees.
    private func callTool(id: JSONValue?, params: JSONValue) {
        guard let name = params["name"]?.stringValue else { return respond(id, error: "No tool name") }
        let alert = UIAlertController(title: "Run \(name)?", message: "The \(card.toolName) card wants to run \(name) on \(card.server).", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don't Run", style: .cancel) { _ in self.respond(id, error: "The user declined") })
        alert.addAction(UIAlertAction(title: "Run", style: .default) { _ in
            Task {
                do {
                    let result = try await self.session.callCardTool(self.card, name: name, arguments: params["arguments"] ?? .object([:]))
                    if case .object(let object) = result { self.respond(id, result: object) } else { self.respond(id, result: [:]) }
                } catch {
                    self.respond(id, error: String(describing: error))
                }
            }
        })
        webView?.window?.rootViewController?.present(alert, animated: true)
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
