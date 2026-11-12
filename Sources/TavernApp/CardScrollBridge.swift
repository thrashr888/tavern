import AppKit
import WebKit

/// Wheel events cannot cross WKWebView's native boundary by themselves. An isolated-world
/// listener checks the live DOM for directional scroll capacity and forwards only the events
/// it cannot use. Real HTML scrollers, controls and their native WebKit momentum stay intact.
@MainActor
final class CardScrollBridge: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "TavernCardScrolling")
    static let handlerName = "tavernScroll"
    weak var webView: WKWebView?

    static var script: String {
        guard let url = Bundle.module.url(forResource: "CardScrollBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }

    func install(on view: WKWebView) {
        webView = view
        let controller = view.configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
    }

    static func remove(from view: WKWebView) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = webView, message.webView === view,
              let value = message.body as? [String: NSNumber],
              let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue,
              let mode = value["mode"]?.intValue,
              x.isFinite, y.isFinite, (0...2).contains(mode) else { return }
        Self.forward(x: x, y: y, mode: mode, from: view)
    }

    /// Use wheel deltas, including WebKit's momentum events, rather than synthesizing new
    /// NSEvents (which lose device units/phases). Start outside WebKit's private scroll views.
    /// Any unused delta can continue through another enclosing native scroll container.
    static func forward(x: Double, y: Double, mode: Int, from view: NSView) {
        guard x.isFinite, y.isFinite else { return }
        var remaining = NSPoint(x: x, y: y)
        var ancestor = view.superview
        var normalized = mode == 0
        while let current = ancestor {
            defer { ancestor = current.superview }
            guard let scroll = current as? NSScrollView, let document = scroll.documentView else { continue }
            let clip = scroll.contentView
            if !normalized {
                remaining.x *= mode == 1 ? scroll.horizontalLineScroll : clip.bounds.width
                remaining.y *= mode == 1 ? scroll.verticalLineScroll : clip.bounds.height
                normalized = true
            }
            let old = clip.bounds.origin
            let sign: CGFloat = document.isFlipped ? 1 : -1
            var requested = clip.bounds
            requested.origin.x += remaining.x
            requested.origin.y += remaining.y * sign
            let destination = clip.constrainBoundsRect(requested).origin
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            remaining.x -= clip.bounds.origin.x - old.x
            remaining.y -= (clip.bounds.origin.y - old.y) * sign
            if abs(remaining.x) < 0.01 && abs(remaining.y) < 0.01 { return }
        }
    }
}
