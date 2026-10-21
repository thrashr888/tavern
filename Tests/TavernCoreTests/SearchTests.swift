import XCTest
@testable import TavernCore

final class SearchTests: XCTestCase {
    private func mail(_ id: String, subject: String, body: String) -> TavernEvent {
        let message = GmailMessage(id: id, threadID: "t-\(id)", internalDate: Date(timeIntervalSince1970: 1_760_500_000),
                                   subject: subject, from: "Rook <rook@mail.instinct.example>", snippet: body, body: body)
        return MailItem.event(for: message, roster: .fixture)
    }

    func testFindsPiMessagesAndMailButNotToolResults() throws {
        let store = try EventStore(path: ":memory:")
        try store.append(PiEntries.events(from: FakePi.entries(["e1", "e2", "e3"]), sessionID: "s1", agentID: "flint"))
        try store.append([mail("m1", subject: "The Guild: Latin mottos", body: "Pick your motto for the portrait")])

        XCTAssertEqual(try store.search("reply e2").map(\.event.sourceID), ["s1:e2"])
        XCTAssertEqual(try store.search("mott").map(\.event.sourceID), ["m1"], "last word matches as a prefix")
        XCTAssertEqual(try store.search("bash"), [], "tool results aren't indexed")
        XCTAssertTrue(try store.search("portrait").first?.snippet.contains("portrait") == true)
    }

    func testQueriesWithFTSSyntaxDoNotThrow() throws {
        let store = try EventStore(path: ":memory:")
        try store.append([mail("m1", subject: "Hi", body: "a \"quoted\" (thing) OR NOT -x")])
        XCTAssertNoThrow(try store.search("\"quoted\" (thing) OR NOT -x*"))
        XCTAssertEqual(try store.search("  ** "), [])
        XCTAssertEqual(SearchText.ftsQuery("Latin mot"), "\"Latin\" \"mot\"*")
    }

    func testDuplicatesAreIndexedOnce() throws {
        let store = try EventStore(path: ":memory:")
        let events = [mail("m1", subject: "Tavern icon", body: "beer mug")]
        try store.append(events)
        try store.append(events)
        XCTAssertEqual(try store.search("mug").count, 1)
    }

    func testOlderStoreIsIndexedWhenReopened() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try EventStore(path: url.path)
            try store.append([mail("m1", subject: "Goals", body: "linear issues")])
            try store.rebuildSearchIndex()
        }
        let reopened = try EventStore(path: url.path)
        XCTAssertEqual(try reopened.search("linear").count, 1)
    }

    func testCountsForTheDashboard() throws {
        let store = try EventStore(path: ":memory:")
        try store.append([mail("m1", subject: "A", body: "x"), mail("m2", subject: "B", body: "y")])
        XCTAssertEqual(try store.countsByAuthor(source: EventSource.gmail), ["rook": 2])
        XCTAssertEqual(try store.countsByThread(source: EventSource.gmail).count, 2)
        let daily = try store.dailyCounts(source: EventSource.gmail, since: .distantPast)
        XCTAssertEqual(daily.map(\.key), ["rook"])
        XCTAssertEqual(daily.map(\.count), [2])
    }
}
