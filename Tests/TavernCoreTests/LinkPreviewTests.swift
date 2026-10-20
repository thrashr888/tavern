import CryptoKit
import XCTest
@testable import TavernCore

final class LinkPreviewTests: XCTestCase {
    func testMetaParserPrefersOpenGraph() {
        let html = """
        <!doctype html><html><head>
        <title>Fallback &amp; title</title>
        <meta name="description" content="Plain description">
        <meta property="og:description" content="Apple&#39;s bots, &quot;previewed&quot; &mdash; neatly.">
        <META PROPERTY='og:title' CONTENT='Apple Bots'>
        <meta property=og:site_name content=MacStories>
        </head><body><meta property="og:description" content="not in the head"></body></html>
        """
        let meta = LinkMeta.parse(html)
        XCTAssertEqual(meta.title, "Apple Bots")
        XCTAssertEqual(meta.description, "Apple's bots, \"previewed\" — neatly.")
        XCTAssertEqual(meta.siteName, "MacStories")
    }

    func testMetaParserFindsImageAndIcon() {
        let html = """
        <head>
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="shortcut icon" href="/favicon.ico">
        <link href="/touch.png" rel="apple-touch-icon">
        <meta property="og:image" content=" https://cdn.example.com/hero.jpg?w=1200&amp;h=630 ">
        </head>
        """
        let meta = LinkMeta.parse(html)
        XCTAssertEqual(meta.image, "https://cdn.example.com/hero.jpg?w=1200&h=630")
        XCTAssertEqual(meta.icon, "/touch.png")
        XCTAssertEqual(LinkMeta.parse("<head><link rel=icon href=fav.png><meta name=twitter:image content=t.png>").icon, "fav.png")
        XCTAssertEqual(LinkMeta.parse("<head><meta name=twitter:image content=t.png>").image, "t.png")
        XCTAssertNil(LinkMeta.parse("<head><link rel=icon href=/only.svg></head>").icon)
    }

    func testMetaParserFallsBackAndTidies() {
        let html = """
        <head><title>
          Just a   title
        </title><meta content="  Spread
        over lines  " name="twitter:description"><meta name="description" content=""></head>
        """
        let meta = LinkMeta.parse(html)
        XCTAssertEqual(meta.title, "Just a title")
        XCTAssertEqual(meta.description, "Spread over lines")
        XCTAssertNil(meta.siteName)
        XCTAssertEqual(LinkMeta.parse("<html><body>nothing</body></html>"), LinkMeta())
        XCTAssertEqual(LinkMeta.parse("<head><meta name=description content='&#x1F37A; &bogus; &lt;b&gt;'>").description,
                       "🍺 &bogus; <b>")
    }

    func testMetaParserStaysFastOnUnclosedTags() {
        let hostile = String(repeating: "<meta <link <title ", count: 3_400)
        let start = Date()
        XCTAssertEqual(LinkMeta.parse(hostile), LinkMeta())
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testMetaParserCapsLongDescriptions() {
        let long = String(repeating: "word ", count: 200)
        let description = LinkMeta.parse("<head><meta name=\"description\" content=\"\(long)\"></head>").description
        XCTAssertEqual(description?.count, 300)
        XCTAssertEqual(description?.last, "…")
    }

    func testPolicyAllowsPublicWebOnly() {
        let allowed = ["https://www.macstories.net/stories/apple-bots/", "http://example.com:8080/x",
                       "https://100.128.0.1/", "https://8.8.8.8", "https://[2606:4700::1111]/", "https://sub.example.co.uk."]
        for text in allowed {
            XCTAssertTrue(LinkPreviewPolicy.allows(URL(string: text)!), text)
        }
        let blocked = [
            // Loopback, LAN and odd IPv4 spellings
            "http://localhost:3000/", "http://LOCALHOST./", "http://127.0.0.1/", "http://127.1/", "http://2130706433/",
            "http://0x7f.0.0.1/", "http://0.0.0.0/", "http://10.0.0.5/", "http://172.16.4.1/", "http://172.31.255.1/",
            "http://192.168.1.10/", "http://169.254.169.254/latest/meta-data", "http://224.0.0.1/",
            // Tailnet
            "http://100.64.0.1/", "http://100.101.102.103:8080/", "http://100.127.255.254/", "https://ember.tail1234.ts.net/",
            "https://EMBER.TAIL1234.TS.NET/", "http://[fd7a:115c:a1e0::1]/",
            // IPv6 loopback, link-local, ULA, mapped
            "http://[::1]/", "http://[fe80::1]/", "http://[fc00::1]/", "http://[::ffff:192.168.0.1]/", "http://[::]/",
            "http://[::127.0.0.1]/", "http://[64:ff9b::10.0.0.1]/", "http://[2002:c0a8:0101::1]/", "http://[2001:0:4136:e378::1]/",
            // Local names
            "http://nas/", "http://printer.local/", "http://router.lan/", "http://box.home.arpa/", "http://svc.internal/",
            // Not http(s), or carrying credentials
            "file:///etc/passwd", "ftp://example.com/", "mailto:a@example.com", "x-apple.systempreferences:foo",
            "https://user:pass@example.com/",
        ]
        for text in blocked {
            XCTAssertFalse(LinkPreviewPolicy.allows(URL(string: text)!), text)
        }
        XCTAssertTrue(LinkPreviewPolicy.allows(URL(string: "https://172.32.0.1/")!))
        XCTAssertTrue(LinkPreviewPolicy.allows(URL(string: "https://[64:ff9b::8.8.8.8]/")!))
        XCTAssertTrue(LinkPreviewPolicy.allows(URL(string: "https://[2002:0808:0808::1]/")!))
    }

    func testPreviewableLinksSkipPrivateAndRepeats() {
        let text = """
        See https://example.com/a and [the docs](https://docs.example.com/x), plus http://localhost:8080/,
        https://example.com/a#section again, and https://ember.tail1.ts.net/admin.
        """
        XCTAssertEqual(LinkPreviewPolicy.previewable(in: text).map(\.absoluteString),
                       ["https://example.com/a", "https://docs.example.com/x"])
        XCTAssertEqual(LinkPreviewPolicy.previewable(in: "no links here"), [])
        let many = (1...6).map { "https://e\($0).example.com" }.joined(separator: " ")
        XCTAssertEqual(LinkPreviewPolicy.previewable(in: many).count, 4)
    }

    func testCacheKeyIsSHA256OfTheAddressWithoutFragment() {
        let url = URL(string: "https://example.com/page?q=1")!
        let expected = SHA256.hash(data: Data("https://example.com/page?q=1".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(LinkPreviewCache.key(for: url), expected)
        XCTAssertEqual(LinkPreviewCache.key(for: url).count, 64)
        XCTAssertEqual(LinkPreviewCache.key(for: URL(string: "https://example.com/page?q=1#top")!), expected)
        XCTAssertNotEqual(LinkPreviewCache.key(for: URL(string: "https://example.com/page?q=2")!), expected)
    }

    func testCacheFilesOnlyResolveTavernNames() {
        let key = String(repeating: "a", count: 64)
        XCTAssertNotNil(LinkPreviewCache.file("\(key)-icon.png"))
        XCTAssertNotNil(LinkPreviewCache.file("\(key)-image.jpg"))
        XCTAssertNil(LinkPreviewCache.file("../../secrets.png"))
        XCTAssertNil(LinkPreviewCache.file("\(key)-icon.png/../x"))
        XCTAssertNil(LinkPreviewCache.file(nil))
    }

    func testPreviewDomainDropsWWW() {
        XCTAssertEqual(LinkPreview(url: URL(string: "https://www.MacStories.net/x")!).domain, "macstories.net")
        XCTAssertEqual(LinkPreview(url: URL(string: "https://www.macstories.net/x")!).displayTitle, "macstories.net")
    }

    /// Fetches a real page. Off by default: TAVERN_LIVE_LINKS=1 swift test --filter LinkPreview
    func testLiveFetch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAVERN_LIVE_LINKS"] == "1", "set TAVERN_LIVE_LINKS=1")
        let preview = await LinkPreviewFetcher.fetch(URL(string: "https://www.apple.com/")!)
        print("live preview:", preview)
        XCTAssertFalse(preview.failed)
        XCTAssertNotNil(preview.title)
        XCTAssertNotNil(preview.iconFile)
        let local = await LinkPreviewFetcher.get(URL(string: "http://127.0.0.1:9/")!, limit: 10, kind: "html")
        XCTAssertNil(local)
    }
}
