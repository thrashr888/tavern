import XCTest
@testable import TavernCore

final class ProjectChatReviewRegressionTests: XCTestCase {
    private let source = "tavern.project-chat"

    func testClockRollbackCannotReviveQueuedOrWaitingRequests() throws {
        let events = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: events)
        let chat = try store.create(title: "Clock regression", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let queued = try XCTUnwrap(store.enqueue(chat: chat, recipients: ["a"], text: "once only", allowedPiIDs: ["a", "b"]).first)
        var attempted = queued
        attempted.state = .dispatching
        attempted.prompt = "exact submitted prompt"
        try append(attempted, to: events, timestamp: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(try store.messages().first?.state, .dispatching)
        XCTAssertNil(try store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]), "An attempted request must never be claimed twice")
        attempted.state = .replied
        try append(attempted, to: events, timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try store.messages().first?.state, .replied)
        XCTAssertEqual(try ProjectChatStore(store: events).messages().first?.state, .replied, "Restart must use durable append order too")
    }

    func testClockRollbackCannotRestoreOldMembershipOrHandoffSettings() throws {
        let events = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: events)
        var chat = try store.create(title: "Latest settings", participants: ["a", "b", "c"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        try store.setCoordinationEnabled(chat, true)
        chat.participants = ["a", "b"]
        chat.coordinationEnabled = false
        try events.append([TavernEvent(source: source, sourceID: UUID().uuidString, threadKey: "project:\(chat.id)",
                                     sourceTS: Date(timeIntervalSince1970: 0), kind: "chat", payload: JSONEncoder().encode(chat))])
        XCTAssertEqual(try store.chats().first?.participants, ["a", "b"])
        XCTAssertEqual(try ProjectChatStore(store: events).chats().first?.participants, ["a", "b"])
        XCTAssertEqual(try store.chats().first?.coordinationEnabled, false)
    }

    func testIncrementalIndexObservesOtherConnectionsAndPreservesDisplayOrder() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let firstEvents = try EventStore(path: path)
        let first = ProjectChatStore(store: firstEvents)
        let chat = try first.create(title: "Two readers", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let secondEvents = try EventStore(path: path)
        let second = ProjectChatStore(store: secondEvents)
        XCTAssertEqual(try second.chats(), [chat])
        XCTAssertTrue(try second.messages().isEmpty)
        var request = try first.prepare(chat: chat, recipient: "a", text: "first", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(try second.messages(), [request])
        request.state = .closed
        request.prompt = nil
        try second.save(request)
        XCTAssertEqual(try first.messages(), [request], "Cached state must see another connection's explicit prompt clear")
        try second.rename(chat, title: "Newest title")
        XCTAssertEqual(try first.chats().first?.title, "Newest title")

        let records = try firstEvents.eventRecords(source: source)
        XCTAssertTrue(zip(records, records.dropFirst()).allSatisfy { $0.position < $1.position })
        XCTAssertTrue(try firstEvents.eventRecords(source: source, after: records.last!.position).isEmpty)
        XCTAssertEqual(try firstEvents.eventRecords(source: "other").count, 0)
        // Transcript and mail consumers still use chronological reads, not state replay order.
        let later = TavernEvent(source: "other", sourceID: "later", threadKey: "other", sourceTS: Date(timeIntervalSince1970: 2), kind: "text", payload: Data())
        let earlier = TavernEvent(source: "other", sourceID: "earlier", threadKey: "other", sourceTS: Date(timeIntervalSince1970: 1), kind: "text", payload: Data())
        try firstEvents.append([later, earlier])
        XCTAssertEqual(try firstEvents.events(source: "other").map(\.sourceID), ["earlier", "later"])
        XCTAssertEqual(try firstEvents.eventRecords(source: "other").map { $0.event.sourceID }, ["later", "earlier"])
    }

    func testHandoffNamesAreCaseInsensitiveAndRoutingCancellationHasReason() throws {
        let events = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: events)
        var chat = try store.create(title: "Handoff", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        try store.setCoordinationEnabled(chat, true)
        chat = try XCTUnwrap(store.chats().first)
        let request = try store.prepare(chat: chat, recipient: "a", text: "review", allowedPiIDs: ["a", "b"])
        let reply = try store.reply(to: request, item: TranscriptItem(id: "reply", role: .assistant,
            text: "@ask B: question\n@ask b: duplicate", date: Date()))
        let handoffs = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: [])
        XCTAssertEqual(handoffs.requests.count, 1)
        XCTAssertEqual(handoffs.requests.first?.recipient, "b")
        try store.setCoordinationEnabled(chat, false)
        XCTAssertNil(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"]))
        let canceled = try XCTUnwrap(store.messages().first { $0.id == handoffs.requests[0].id })
        XCTAssertEqual(canceled.state, .closed)
        XCTAssertNotNil(canceled.failureReason)
        XCTAssertNil(canceled.prompt)
        // The four-handoff budget counts accepted routing attempts, not successful work.
        // Canceling one does not refund a slot and create an unbounded retry loop.
        XCTAssertEqual(try store.messages().filter { $0.parentMessageID != nil && $0.recipient != nil }.count, 1)
    }

    func testStaleMembershipCannotBypassAmbiguousHandoffNames() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Case ambiguity", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b", "B"])
        try store.setCoordinationEnabled(chat, true)
        let request = try store.prepare(chat: chat, recipient: "a", text: "review", allowedPiIDs: ["a", "b"])
        let reply = try store.reply(to: request, item: TranscriptItem(id: "reply", role: .assistant, text: "@ask b: question", date: Date()))
        try store.setParticipants(chat, participants: ["a", "b", "B"], allowedPiIDs: ["a", "b", "B"])
        let result = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b", "B"], availablePiIDs: ["b", "B"])
        XCTAssertTrue(result.requests.isEmpty)
        XCTAssertEqual(result.notices.count, 1)
    }

    func testLongHistorySteadyStateReadsAndClaimsStayBounded() throws {
        guard ProcessInfo.processInfo.environment["TAVERN_HISTORY_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in large-history benchmark")
        }
        let events = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: events)
        let chat = try store.create(title: "Long-lived Home", participants: ["a", "b", "c"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        let template = try store.prepare(chat: chat, recipient: "a", text: "seed", allowedPiIDs: ["a", "b", "c"])
        var records: [TavernEvent] = []
        let prompt = String(repeating: "x", count: 40_000)
        for index in 0..<2_000 {
            var message = template
            message.id = index == 0 ? template.id : "historical-\(index)"
            message.text = String(repeating: "x", count: 2_000)
            message.prompt = prompt
            message.queueSequence = Int64(index)
            for state in [ProjectChatMessage.State.dispatching, .waiting, .replied] {
                message.state = state
                records.append(try event(message, timestamp: Date(timeIntervalSince1970: Double(index))))
            }
        }
        try events.append(records)
        let coldStart = Date()
        XCTAssertEqual(try store.messages().count, 2_000)
        let cold = Date().timeIntervalSince(coldStart)
        let start = Date()
        for _ in 0..<10 {
            XCTAssertEqual(try store.messages().count, 2_000)
            XCTAssertEqual(try store.chats().count, 1)
        }
        let read = Date().timeIntervalSince(start) / 10
        let claimStart = Date()
        _ = try store.enqueue(chat: chat, recipients: ["b"], text: "after large history", allowedPiIDs: ["a", "b", "c"])
        XCTAssertNotNil(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b", "c"]))
        let claim = Date().timeIntervalSince(claimStart)
        print("PROJECT_HISTORY_BENCHMARK cold=\(cold)s steady-read=\(read)s enqueue-and-claim=\(claim)s events=6001 payload=252MB")
        XCTAssertLessThan(read, 0.1, "Repeated reads must not decode the entire history on the main actor")
        XCTAssertLessThan(claim, 0.2, "Warm enqueue/claim must stay interactive")
    }

    private func event(_ message: ProjectChatMessage, timestamp: Date) throws -> TavernEvent {
        TavernEvent(source: source, sourceID: UUID().uuidString, threadKey: "project:\(message.chatID)",
                    sourceTS: timestamp, kind: "message", payload: try JSONEncoder().encode(message))
    }

    private func append(_ message: ProjectChatMessage, to events: EventStore, timestamp: Date) throws {
        try events.append([event(message, timestamp: timestamp)])
    }
}
