import AppKit
import XCTest
import WebKit
@testable import TavernApp

final class CardScrollTests: XCTestCase {
    @MainActor private func scroller(flipped: Bool = true, height: CGFloat = 1000) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = flipped ? FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
            : NSView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        return scroll
    }

    @MainActor func testPixelWheelAndMomentumDeltasReachParent() {
        let parent = scroller()
        let card = NSView(frame: .zero)
        parent.documentView!.addSubview(card)
        for delta in [30.0, 12.5, 4.0, 1.5] { CardScrollBridge.forward(x: 0, y: delta, mode: 0, from: card) }
        XCTAssertEqual(parent.contentView.bounds.origin.y, 48, accuracy: 0.01)
        CardScrollBridge.forward(x: 0, y: -28, mode: 0, from: card)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 20, accuracy: 0.01)
    }

    @MainActor func testNonFlippedDocumentScrollsInCorrectDirection() {
        let parent = scroller(flipped: false)
        let card = NSView(frame: .zero)
        parent.documentView!.addSubview(card)
        parent.contentView.scroll(to: NSPoint(x: 0, y: 600))
        CardScrollBridge.forward(x: 0, y: 30, mode: 0, from: card)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 570, accuracy: 0.01)
    }

    @MainActor func testNestedNativeContainerPassesOnlyRemainder() {
        let parent = scroller()
        let inner = scroller(height: 250)
        parent.documentView!.addSubview(inner)
        let card = NSView(frame: .zero)
        inner.documentView!.addSubview(card)
        CardScrollBridge.forward(x: 0, y: 80, mode: 0, from: card)
        XCTAssertEqual(inner.contentView.bounds.origin.y, 50, accuracy: 0.01)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 30, accuracy: 0.01)
        CardScrollBridge.forward(x: 0, y: -90, mode: 0, from: card)
        XCTAssertEqual(inner.contentView.bounds.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 0, accuracy: 0.01)
    }

    @MainActor func testLineAndPageUnitsAndInvalidDeltas() {
        let parent = scroller()
        parent.verticalLineScroll = 20
        let card = NSView(frame: .zero)
        parent.documentView!.addSubview(card)
        CardScrollBridge.forward(x: 0, y: 2, mode: 1, from: card)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 40, accuracy: 0.01)
        CardScrollBridge.forward(x: 0, y: 1, mode: 2, from: card)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 240, accuracy: 0.01)
        CardScrollBridge.forward(x: .nan, y: 10, mode: 0, from: card)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 240, accuracy: 0.01)
    }


    @MainActor func testWebKitRoutesOnlyUnconsumedWheelEvents() async throws {
        let parent = scroller(height: 2000)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let bridge = CardScrollBridge()
        bridge.install(on: web)
        defer { CardScrollBridge.remove(from: web) }
        parent.documentView!.addSubview(web)
        let window = NSWindow(contentRect: parent.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parent
        defer { window.close() }
        let loaded = expectation(description: "WebKit fixture loaded")
        let navigation = CardLoadObserver { loaded.fulfill() }
        web.navigationDelegate = navigation
        web.loadHTMLString("""
            <!doctype html><html><head><style>
            html,body { margin:0; overflow:hidden; }
            #plain { height:40px; overflow:auto; }
            #outer { height:100px; overflow:auto; }
            #inner { height:60px; overflow:auto; }
            #wide { width:80px; height:40px; overflow:auto; }
            </style></head><body>
            <div id="plain">No actual overflow</div>
            <div id="outer"><div id="inner"><div id="target" style="height:300px">Nested content</div></div>
            <div style="height:300px">Outer content</div></div>
            <div id="wide"><div id="wideTarget" style="width:400px;height:20px">Horizontal content</div></div>
            </body></html>
            """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)

        func wheel(_ target: String, x: Double = 0, y: Double = 30, extra: String = "") async throws {
            _ = try await web.evaluateJavaScript("""
                document.getElementById('\(target)').dispatchEvent(new WheelEvent('wheel',
                  { bubbles:true, composed:true, cancelable:true, deltaX:\(x), deltaY:\(y)\(extra) }));
                """)
            // The isolated world's script message is asynchronous relative to evaluateJavaScript.
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await wheel("plain")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 30, accuracy: 0.01)
        try await wheel("target") // Both inner and outer have room: WebKit owns the gesture.
        XCTAssertEqual(parent.contentView.bounds.origin.y, 30, accuracy: 0.01)
        _ = try await web.evaluateJavaScript("document.getElementById('inner').scrollTop=1000")
        try await wheel("target") // Inner exhausted, outer HTML scroller still has room.
        XCTAssertEqual(parent.contentView.bounds.origin.y, 30, accuracy: 0.01)
        _ = try await web.evaluateJavaScript("document.getElementById('outer').scrollTop=1000")
        try await wheel("target") // All HTML scrollers exhausted: native parent moves.
        XCTAssertEqual(parent.contentView.bounds.origin.y, 60, accuracy: 0.01)
        try await wheel("target", y: -30) // Reversal must return to the inner scroller.
        XCTAssertEqual(parent.contentView.bounds.origin.y, 60, accuracy: 0.01)
        try await wheel("wideTarget") // Horizontal overflow must not steal vertical gestures.
        XCTAssertEqual(parent.contentView.bounds.origin.y, 90, accuracy: 0.01)
        try await wheel("wideTarget", x: 30, y: 0)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 90, accuracy: 0.01)
        try await wheel("plain", extra: ", ctrlKey:true")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 90, accuracy: 0.01)
        _ = try await web.evaluateJavaScript("document.getElementById('plain').addEventListener('wheel', e=>e.preventDefault())")
        try await wheel("plain")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 90, accuracy: 0.01)
        // Body overflow propagates to a default (visible-overflow) HTML viewport.
        // Tall hidden content must not trap the wheel merely because scrollHeight is large.
        _ = try await web.evaluateJavaScript("""
            document.documentElement.style.overflow='visible';
            document.getElementById('wide').insertAdjacentHTML('afterend','<div id="tail" style="height:900px">Tall hidden content</div>');
            """)
        let rootExtent = try await web.evaluateJavaScript("document.scrollingElement.scrollHeight - innerHeight") as! Double
        XCTAssertGreaterThan(rootExtent, 0)
        try await wheel("tail")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 120, accuracy: 0.01)
        // A genuinely capped root page owns scrolling until its lower boundary.
        _ = try await web.evaluateJavaScript("document.body.style.overflow='visible'")
        try await wheel("tail")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 120, accuracy: 0.01)
        _ = try await web.evaluateJavaScript("document.scrollingElement.scrollTop=10000")
        try await wheel("tail")
        XCTAssertEqual(parent.contentView.bounds.origin.y, 150, accuracy: 0.01)
        try await wheel("tail", y: -30)
        XCTAssertEqual(parent.contentView.bounds.origin.y, 150, accuracy: 0.01)
        // The page cannot call the host's isolated handler directly.
        let isolated = try await web.evaluateJavaScript("typeof window.webkit?.messageHandlers?.tavernScroll") as? String
        XCTAssertEqual(isolated, "undefined")
        withExtendedLifetime(navigation) {}
    }


    @MainActor func testScriptIsBundled() {
        XCTAssertTrue(CardScrollBridge.script.contains("event.composedPath()"))
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class CardLoadObserver: NSObject, WKNavigationDelegate {
    let loaded: () -> Void
    init(loaded: @escaping () -> Void) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
