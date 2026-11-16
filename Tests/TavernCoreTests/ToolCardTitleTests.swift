import XCTest
@testable import TavernCore

final class ToolCardTitleTests: XCTestCase {
    private func card(_ title: String, widget: String = "checklist", server: String = "cards") -> ToolCard {
        ToolCard(server: server, resourceUri: "ui://cards/\(widget)", toolName: "cards__\(widget)",
                 arguments: ["title": .string(title)],
                 structuredContent: [widget: ["title": .string(title)]])
    }

    func testEscapedAndAlreadyDecodedWidgetTitlesDisplayIdentically() {
        for widget in ["checklist", "chart", "timeline", "calendar", "compose"] {
            let escaped = card(#"AgentKernel tasks \u2014 Nov 6"#, widget: widget)
            let decoded = card("AgentKernel tasks — Nov 6", widget: widget)
            XCTAssertEqual(escaped.displayStructuredContent, decoded.displayStructuredContent, widget)
            XCTAssertEqual(escaped.structuredContent[widget]?["title"]?.stringValue,
                           #"AgentKernel tasks \u2014 Nov 6"#, "Do not rewrite saved history")
            XCTAssertEqual(escaped.arguments["title"]?.stringValue, #"AgentKernel tasks \u2014 Nov 6"#)
        }
    }

    func testUnicodePairsAndMultipleEscapes() {
        let c = card(#"🚧 \uD83D\uDE80 \u201cCaf\u00e9\u201d"#)
        XCTAssertEqual(c.displayStructuredContent["checklist"]?["title"]?.stringValue, "🚧 🚀 “Café”")
    }

    func testExplicitLiteralsAndMalformedEscapesArePreserved() {
        for title in [#"Literal \\u2014"#, #"C:\users\new"#, #"A \u201"#, #"A \uZZZZ"#,
                      #"A \uD800"#, #"A \uDC00"#, #"A \u{2014}"#, #"A \n B"#] {
            XCTAssertEqual(card(title).displayStructuredContent["checklist"]?["title"]?.stringValue, title)
        }
        XCTAssertEqual(card(#"\u005cu2014"#).displayStructuredContent["checklist"]?["title"]?.stringValue,
                       #"\u2014"#, "Decode once, not recursively")
    }

    func testUnrelatedContentAndOtherServersAreNotDecoded() {
        let raw = #"\u2014"#
        var c = card(raw)
        c.structuredContent = ["kind": "checklist", "checklist": [
            "title": .string(raw),
            "items": .array([["text": .string(raw), "note": .string(raw),
                              "url": .string("https://example.com/" + raw)]])
        ]]
        XCTAssertEqual(c.displayStructuredContent["checklist"]?["items"], c.structuredContent["checklist"]?["items"])
        for c in [card(raw, server: "other"), card(raw, widget: "mail"), card(raw, widget: "github")] {
            XCTAssertEqual(c.displayStructuredContent, c.structuredContent)
        }
        c.resourceUri = "ui://other/checklist"
        XCTAssertEqual(c.displayStructuredContent, c.structuredContent)
        c = card(raw)
        c.structuredContent = .null
        XCTAssertEqual(c.displayStructuredContent, .null)
    }

    func testComposedWidgetTitlesOnly() {
        let raw: JSONValue = .string(#"Tasks \u2014 today"#)
        let widget: JSONValue = ["type": "checklist", "checklist": ["title": raw]]
        let text: JSONValue = ["type": "text", "text": raw]
        var c = card("Dashboard", widget: "compose")
        c.structuredContent = ["compose": ["title": raw, "blocks": .array([
            text, ["type": "row", "blocks": .array([widget, ["type": "table", "title": raw]])]
        ])]]
        let shown = c.displayStructuredContent["compose"]
        XCTAssertEqual(shown?["title"]?.stringValue, "Tasks — today")
        let blocks = shown?["blocks"]?.arrayValue
        XCTAssertEqual(blocks?.first, text)
        let row = blocks?[1]["blocks"]?.arrayValue
        XCTAssertEqual(row?[0]["checklist"]?["title"]?.stringValue, "Tasks — today")
        XCTAssertEqual(row?[1]["title"]?.stringValue, "Tasks — today")
    }

    func testWireJSONIsDecodedExactlyOnceBeforeTitlePresentation() throws {
        // Standard JSON Unicode escape is already a character after JSON decoding.
        let decoded = try JSONValue.decode(Data(#"{"title":"Tasks \u2014 today"}"#.utf8))
        // An over-escaped agent argument contains literal \u2014 after JSON decoding.
        let literal = try JSONValue.decode(Data(#"{"title":"Tasks \\u2014 today"}"#.utf8))
        XCTAssertEqual(decoded["title"]?.stringValue, "Tasks — today")
        XCTAssertEqual(literal["title"]?.stringValue, #"Tasks \u2014 today"#)
        XCTAssertEqual(card(decoded["title"]!.stringValue!).displayStructuredContent,
                       card(literal["title"]!.stringValue!).displayStructuredContent)
    }
}
