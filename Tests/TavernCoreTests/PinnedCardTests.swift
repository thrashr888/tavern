import XCTest
@testable import TavernCore

final class PinnedCardTests: XCTestCase {
    func testReferencesResolveLatestExactResultNotSimilarWidgets() {
        let pin = PinnedCard(agentID: "ember", rowID: "card:one")
        let old = ToolCard(server: "cards", resourceUri: "ui://cards/chart", toolName: "chart", structuredContent: ["value": .number(1)])
        let new = ToolCard(server: "cards", resourceUri: "ui://cards/chart", toolName: "chart", structuredContent: ["value": .number(2)])
        XCTAssertEqual(pin.resolve(in: [.card(id: "one", old)], agentID: "ember"), old)
        XCTAssertEqual(pin.resolve(in: [.card(id: "one", new), .card(id: "two", old)], agentID: "ember"), new)
        XCTAssertNil(pin.resolve(in: [.card(id: "two", new)], agentID: "ember"))
        XCTAssertNotEqual(pin.id, PinnedCard(agentID: "tally", rowID: "card:one").id)
    }
    func testAtomicPersistenceDeduplicatesAndUnpins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pins.json")
        let pin = PinnedCard(agentID: "ember", rowID: "card:one")
        XCTAssertEqual(try PinnedCardFile.load(from: url), [])
        try PinnedCardFile.save([pin, pin], to: url)
        XCTAssertEqual(try PinnedCardFile.load(from: url), [pin])
        try PinnedCardFile.save([], to: url)
        XCTAssertEqual(try PinnedCardFile.load(from: url), [])
    }
    func testMalformedFileDoesNotSilentlyDiscardPins() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try PinnedCardFile.load(from: url))
    }
}
