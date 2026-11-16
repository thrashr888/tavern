import XCTest
@testable import TavernCore

final class ProjectChatBudgetReviewTests: XCTestCase {
    private enum Outcome {
        case canceledBeforeSend, failed, uncertain, manuallyClosedInterruption
    }

    func testCanceledBeforeSendReservationsDoNotRefundBudgetAfterReopen() throws {
        try assertBudgetSurvivesReopen(outcomes: Array(repeating: .canceledBeforeSend, count: 4))
    }

    func testFailedAttemptsDoNotRefundBudgetAfterReopen() throws {
        try assertBudgetSurvivesReopen(outcomes: Array(repeating: .failed, count: 4))
    }

    func testUncertainAttemptsDoNotRefundBudgetOrReplayAfterReopen() throws {
        try assertBudgetSurvivesReopen(outcomes: Array(repeating: .uncertain, count: 4))
    }

    func testManuallyClosedInterruptedAttemptsDoNotRefundBudgetAfterReopen() throws {
        try assertBudgetSurvivesReopen(outcomes: Array(repeating: .manuallyClosedInterruption, count: 4))
    }

    func testBroadcastRepliesShareFourReservationsAcrossMixedOutcomes() throws {
        try assertBudgetSurvivesReopen(outcomes: [.canceledBeforeSend, .failed, .uncertain, .manuallyClosedInterruption])
    }

    private func assertBudgetSurvivesReopen(outcomes: [Outcome], file: StaticString = #filePath, line: UInt = #line) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let authors = ["a", "b", "c", "d", "e"]
        let targets = ["f", "g", "h", "i", "j"]
        let participants = authors + targets
        let allowed = Set(participants)

        // End this scope before opening the database again: receipts and budget must be durable,
        // not properties of a surviving ProjectChatStore or EventStore instance.
        let (chat, humanRequests, replies, reservations): (ProjectChat, [ProjectChatMessage], [ProjectChatMessage], [ProjectChatMessage]) = try {
            let store = ProjectChatStore(store: try EventStore(path: path))
            var chat = try store.create(title: "Routing attempt budget", participants: participants, lead: "a", allowedPiIDs: allowed)
            try store.setCoordinationEnabled(chat, true)
            chat = try XCTUnwrap(store.chats().first)
            let humans = try store.enqueue(chat: chat, recipients: authors, text: "Review together", allowedPiIDs: allowed, group: true)
            XCTAssertEqual(Set(humans.compactMap(\.rootRequestID)).count, 1, file: file, line: line)
            XCTAssertTrue(humans.allSatisfy { $0.permitsSilence == true }, file: file, line: line)
            var replies: [ProjectChatMessage] = []
            var reservations: [ProjectChatMessage] = []
            for index in 0..<4 {
                let request = try XCTUnwrap(store.claimNextQueued(recipient: authors[index], allowedPiIDs: allowed))
                let reply = try store.reply(to: request, item: TranscriptItem(id: "answer-\(index)", role: .assistant,
                    text: "@ask \(targets[index]): inspect this", date: Date()))
                replies.append(reply)
                let result = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: allowed, availablePiIDs: [])
                XCTAssertEqual(result.requests.count, 1, file: file, line: line)
                XCTAssertTrue(result.notices.isEmpty, file: file, line: line)
                let reserved = try XCTUnwrap(result.requests.first)
                XCTAssertEqual(reserved.rootRequestID, humans[0].rootRequestID, file: file, line: line)
                XCTAssertEqual(reserved.parentMessageID, reply.id, file: file, line: line)
                XCTAssertEqual(reserved.state, .queued, file: file, line: line)
                XCTAssertNil(reserved.prompt, file: file, line: line)
                switch outcomes[index] {
                case .canceledBeforeSend:
                    try store.cancelQueued(reserved.id)
                case .failed, .uncertain, .manuallyClosedInterruption:
                    var attempted = try XCTUnwrap(store.claimNextQueued(recipient: targets[index], allowedPiIDs: allowed))
                    XCTAssertEqual(attempted.id, reserved.id, file: file, line: line)
                    XCTAssertNotNil(attempted.prompt, file: file, line: line)
                    // Model the persisted outcomes used by the app; no transport runs in core tests.
                    switch outcomes[index] {
                    case .failed:
                        attempted.state = .closed
                        attempted.failureReason = "Provider failed after dispatch"
                    case .uncertain, .manuallyClosedInterruption:
                        attempted.state = .uncertain
                        attempted.failureReason = "Delivery acknowledgement interrupted"
                    case .canceledBeforeSend:
                        XCTFail("Unexpected outcome", file: file, line: line)
                    }
                    try store.save(attempted)
                    if outcomes[index] == .manuallyClosedInterruption {
                        attempted.state = .closed
                        attempted.failureReason = nil
                        try store.save(attempted)
                    }
                }
                reservations.append(try XCTUnwrap(store.messages().first { $0.id == reserved.id }))
            }
            return (chat, humans, replies, reservations)
        }()

        let events = try EventStore(path: path)
        let reopened = ProjectChatStore(store: events)
        for (index, reserved) in reservations.enumerated() {
            XCTAssertEqual(try reopened.messages().first { $0.id == reserved.id }, reserved, file: file, line: line)
            XCTAssertNil(try reopened.claimNextQueued(recipient: targets[index], allowedPiIDs: allowed), file: file, line: line)
        }
        // Reprocessing successful reservation receipts must neither reserve again nor append events.
        let eventCount = try events.eventRecords(source: "tavern.project-chat").count
        for reply in replies {
            let replay = try reopened.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: allowed, availablePiIDs: allowed)
            XCTAssertTrue(replay.requests.isEmpty, file: file, line: line)
            XCTAssertTrue(replay.notices.isEmpty, file: file, line: line)
        }
        XCTAssertEqual(try events.eventRecords(source: "tavern.project-chat").count, eventCount, file: file, line: line)

        // A later participant reply from the same broadcast cannot get a fifth reservation,
        // even though none of the first four handoffs completed successfully.
        let laterHuman = try XCTUnwrap(reopened.claimNextQueued(recipient: "e", allowedPiIDs: allowed))
        let laterReply = try reopened.reply(to: laterHuman, item: TranscriptItem(id: "later-answer", role: .assistant,
            text: "@ask j: fifth request", date: Date()))
        let refused = try reopened.prepareHandoffs(chat: chat, reply: laterReply, allowedPiIDs: allowed, availablePiIDs: allowed)
        XCTAssertTrue(refused.requests.isEmpty, file: file, line: line)
        XCTAssertEqual(refused.notices, ["Handoff limit reached; request to j was not sent."], file: file, line: line)
        XCTAssertEqual(try reopened.messages().filter {
            $0.rootRequestID == humanRequests[0].rootRequestID && $0.parentMessageID != nil && $0.recipient != nil
        }.count, 4, file: file, line: line)

        let receiptEvents = try events.eventRecords(source: "tavern.project-chat").filter { $0.event.kind == "handoff-receipt" }
        XCTAssertEqual(receiptEvents.count, 5, file: file, line: line)
        XCTAssertEqual(Set(receiptEvents.map { $0.event.sourceID }).count, 5, file: file, line: line)
        let afterRefusalCount = try events.eventRecords(source: "tavern.project-chat").count
        let reopenedAgain = ProjectChatStore(store: try EventStore(path: path))
        let replayedRefusal = try reopenedAgain.prepareHandoffs(chat: chat, reply: laterReply, allowedPiIDs: allowed, availablePiIDs: allowed)
        XCTAssertTrue(replayedRefusal.requests.isEmpty, file: file, line: line)
        XCTAssertTrue(replayedRefusal.notices.isEmpty, file: file, line: line)
        XCTAssertEqual(try events.eventRecords(source: "tavern.project-chat").count, afterRefusalCount, file: file, line: line)

        // The cap belongs to this human root, not the entire chat or participant.
        let fresh = try reopenedAgain.prepare(chat: chat, recipient: "a", text: "New human turn", allowedPiIDs: allowed)
        XCTAssertNotEqual(fresh.rootRequestID, humanRequests[0].rootRequestID, file: file, line: line)
        let freshReply = try reopenedAgain.reply(to: fresh, item: TranscriptItem(id: "fresh-answer", role: .assistant,
            text: "@ask j: new budget", date: Date()))
        let freshResult = try reopenedAgain.prepareHandoffs(chat: chat, reply: freshReply, allowedPiIDs: allowed, availablePiIDs: allowed)
        XCTAssertEqual(freshResult.requests.count, 1, file: file, line: line)
        XCTAssertTrue(freshResult.notices.isEmpty, file: file, line: line)
    }
}
