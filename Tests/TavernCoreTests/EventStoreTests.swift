import XCTest
@testable import TavernCore

final class EventStoreTests: XCTestCase {
    private func makeStore() throws -> EventStore {
        try EventStore(path: ":memory:")
    }

    private func event(_ id: String, thread: String = "pi:tally", at seconds: TimeInterval) -> TavernEvent {
        TavernEvent(
            source: EventSource.pi,
            sourceID: id,
            threadKey: thread,
            authorAgent: "tally",
            sourceTS: Date(timeIntervalSince1970: seconds),
            kind: "message",
            payload: Data(id.utf8)
        )
    }

    func testDuplicateSourceIDsAreStoredOnce() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.append([event("s1:e1", at: 1), event("s1:e2", at: 2)]), 2)
        // A replay after reconnect sends the same entries again.
        XCTAssertEqual(try store.append([event("s1:e2", at: 2), event("s1:e3", at: 3)]), 1)
        XCTAssertEqual(try store.eventCount(), 3)
    }

    func testSameSourceIDFromDifferentSourcesIsNotADuplicate() throws {
        let store = try makeStore()
        var mail = event("x1", thread: "mail:tavern", at: 1)
        mail.source = EventSource.gmail
        try store.append([event("x1", at: 1), mail])
        XCTAssertEqual(try store.eventCount(), 2)
    }

    func testCursorAdvancesWithItsEvents() throws {
        let store = try makeStore()
        try store.append([event("s1:e1", at: 1)], cursor: (EventSource.pi, "s1:e1"))
        XCTAssertEqual(try store.cursor(for: EventSource.pi), "s1:e1")
        XCTAssertNil(try store.cursor(for: EventSource.gmail))
    }

    func testFailedBatchLeavesCursorAndEventsUntouched() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tavern-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try EventStore(path: path)
        try store.append([event("s1:e1", at: 1)], cursor: (EventSource.pi, "s1:e1"))

        // A second connection holds the write lock, so the next append cannot commit.
        let blocker = try EventStore(path: path)
        try blocker.beginExclusiveForTesting()
        XCTAssertThrowsError(try store.append([event("s1:e2", at: 2)], cursor: (EventSource.pi, "s1:e2")))
        try blocker.rollbackForTesting()

        XCTAssertEqual(try store.cursor(for: EventSource.pi), "s1:e1")
        XCTAssertEqual(try store.eventCount(), 1)
    }

    func testEventsSortBySourceTimeNotArrival() throws {
        let store = try makeStore()
        try store.append([event("late", at: 30)])
        try store.append([event("early", at: 10), event("middle", at: 20)])
        let ids = try store.events(threadKey: "pi:tally").map(\.sourceID)
        XCTAssertEqual(ids, ["early", "middle", "late"])
    }

    func testPayloadRoundTrips() throws {
        let store = try makeStore()
        let payload = Data(#"{"type":"agent_settled"}"#.utf8)
        var settled = event("s1:e9", at: 9)
        settled.payload = payload
        var empty = event("s1:e10", at: 10)
        empty.payload = Data()
        try store.append([settled, empty])
        let stored = try store.events(threadKey: "pi:tally")
        XCTAssertEqual(stored.first?.payload, payload)
        XCTAssertEqual(stored.last?.payload, Data())
    }

    func testResetCursorForFullResync() throws {
        let store = try makeStore()
        try store.append([], cursor: (EventSource.gmail, "12345"))
        try store.resetCursor(source: EventSource.gmail)
        XCTAssertNil(try store.cursor(for: EventSource.gmail))
    }
}
