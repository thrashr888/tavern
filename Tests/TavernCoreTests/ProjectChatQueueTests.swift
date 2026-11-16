import XCTest
@testable import TavernCore

final class ProjectChatQueueTests: XCTestCase {
    func testBusyAgentDoesNotBlockOtherRecipientAndFIFOAcrossChats() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "One", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let other = try store.create(title: "Two", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        var busy = try store.prepare(chat: chat, recipient: "a", text: "working", allowedPiIDs: ["a", "b"])
        let first = try store.enqueue(chat: chat, recipients: ["a", "b"], text: "first", allowedPiIDs: ["a", "b"], group: true, now: Date(timeIntervalSince1970: 20))
        let second = try store.enqueue(chat: other, recipients: ["a"], text: "second", allowedPiIDs: ["a", "b"], now: Date(timeIntervalSince1970: 10))[0]
        XCTAssertTrue(first.allSatisfy { $0.state == .queued && $0.prompt == nil })
        XCTAssertNil(try store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertNotNil(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"]))
        busy.state = .closed; try store.save(busy)
        let claimed = try XCTUnwrap(store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertEqual(claimed.text, "first")
        XCTAssertFalse(claimed.prompt!.contains("second"))
        XCTAssertNil(try store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        _ = try store.reply(to: claimed, item: TranscriptItem(id: "done", role: .assistant, text: "done", date: Date()))
        XCTAssertEqual(try store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"])?.id, second.id)
    }

    func testQueuedSurvivesReopenButClaimedNeverReplaysAndCanCancel() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let first = ProjectChatStore(store: try EventStore(path: path))
        let chat = try first.create(title: "Queue", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let queued = try first.enqueue(chat: chat, recipients: ["a"], text: "queued", allowedPiIDs: ["a", "b"])[0]
        let reopened = ProjectChatStore(store: try EventStore(path: path))
        XCTAssertEqual(try reopened.messages().first?.state, .queued)
        let claimed = try XCTUnwrap(reopened.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertEqual(claimed.id, queued.id)
        XCTAssertThrowsError(try reopened.cancelQueued(claimed.id))
        let more = try reopened.enqueue(chat: chat, recipients: ["a"], text: "more", allowedPiIDs: ["a", "b"])[0]
        XCTAssertNil(try ProjectChatStore(store: try EventStore(path: path)).claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        try reopened.cancelQueued(more.id)
        XCTAssertEqual(try reopened.messages().first { $0.id == more.id }?.state, .closed)
    }

    func testRemovedParticipantAndArchivedChatCannotReceiveQueue() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Queue", participants: ["a", "b", "c"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        let queued = try store.enqueue(chat: chat, recipients: ["a", "b"], text: "queued", allowedPiIDs: ["a", "b", "c"])
        try store.setParticipants(chat, participants: ["b", "c"], allowedPiIDs: ["a", "b", "c"])
        XCTAssertNil(try store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b", "c"]))
        try store.setArchived(chat, true)
        XCTAssertNil(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b", "c"]))
        XCTAssertEqual(try store.messages().filter { $0.state == .closed }.count, queued.count)
        XCTAssertThrowsError(try store.enqueue(chat: chat, recipients: ["b"], text: "later", allowedPiIDs: ["a", "b", "c"]))
    }

    func testDispatchContextIncludesPriorReplyNotFutureQueuedText() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Queue", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "one", allowedPiIDs: ["a", "b"])
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "two", allowedPiIDs: ["a", "b"])
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "FUTURE_SECRET", allowedPiIDs: ["a", "b"])
        let one = try XCTUnwrap(store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertFalse(one.prompt!.contains("FUTURE_SECRET"))
        _ = try store.reply(to: one, item: TranscriptItem(id: "r", role: .assistant, text: "prior answer", date: Date()))
        let two = try XCTUnwrap(store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertTrue(two.prompt!.contains("prior answer"))
        XCTAssertFalse(two.prompt!.contains("FUTURE_SECRET"))
    }
}

extension ProjectChatQueueTests {
    func testHandoffsKeepFIFOAndHonorDisabledCoordinationAtDispatch() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        var chat = try store.create(title: "Queue", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        try store.setCoordinationEnabled(chat, true)
        chat = try XCTUnwrap(store.chats().first)
        let root = try store.prepare(chat: chat, recipient: "a", text: "coordinate", allowedPiIDs: ["a", "b"])
        let earlier = try store.enqueue(chat: chat, recipients: ["b"], text: "earlier human message", allowedPiIDs: ["a", "b"])[0]
        let reply = try store.reply(to: root, item: TranscriptItem(id: "r", role: .assistant, text: "@ask b: help", date: Date()))
        let handoff = try XCTUnwrap(store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: []).requests.first)
        XCTAssertEqual(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"])?.id, earlier.id)
        var closed = earlier; closed.state = .closed; try store.save(closed)
        try store.setCoordinationEnabled(chat, false)
        XCTAssertNil(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"]))
        XCTAssertEqual(try store.messages().first { $0.id == handoff.id }?.state, .closed)
    }

    func testQueuedHandoffKeepsItsHumanQuestionAndParentReply() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        var chat = try store.create(title: "Queue", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        try store.setCoordinationEnabled(chat, true); chat = try XCTUnwrap(store.chats().first)
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "ORIGINAL_QUESTION", allowedPiIDs: ["a", "b"])
        let request = try XCTUnwrap(store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b"]))
        let reply = try store.reply(to: request, item: TranscriptItem(id: "r", role: .assistant, text: "PARENT_CONTEXT\n@ask b: help", date: Date()))
        _ = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: [])
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "FUTURE_QUESTION", allowedPiIDs: ["a", "b"])
        let handoff = try XCTUnwrap(store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"]))
        XCTAssertTrue(handoff.prompt!.contains("ORIGINAL_QUESTION"))
        XCTAssertTrue(handoff.prompt!.contains("PARENT_CONTEXT"))
        XCTAssertFalse(handoff.prompt!.contains("FUTURE_QUESTION"))
    }

    func testFailedOrAbortedTurnIsCorrelatedWithoutCopyingOtherPrivateFailures() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Queue", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let request = try store.prepare(chat: chat, recipient: "a", text: "hello", allowedPiIDs: ["a", "b"])
        let prompt = TranscriptItem(id: "u", role: .user, text: request.prompt!, date: Date())
        let failure = TranscriptItem(id: "f", role: .system, text: "Provider unavailable", date: Date(), failed: true)
        let abort = TranscriptItem(id: "x", role: .system, text: "Aborted", date: Date())
        let preamble = TranscriptItem(id: "p", role: .assistant, text: "Let me check", date: Date())
        XCTAssertNil(ProjectChatStore.response(to: request, transcript: [prompt, preamble, failure]))
        XCTAssertEqual(ProjectChatStore.failure(to: request, transcript: [prompt, failure]), "Provider unavailable")
        XCTAssertEqual(ProjectChatStore.failure(to: request, transcript: [prompt, abort]), "Aborted")
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [failure]))
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, TranscriptItem(id: "v", role: .user, text: "private", date: Date()), failure]))
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, TranscriptItem(id: "c", role: .system, text: "Context compacted", date: Date()), failure]))
    }
}

extension ProjectChatQueueTests {
    func testPartialFailedAssistantNeverCountsAsReplyOrHandoff() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Failures", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let request = try store.prepare(chat: chat, recipient: "a", text: "test", allowedPiIDs: ["a", "b"])
        let prompt = TranscriptItem(id: "u", role: .user, text: request.prompt!, date: Date())
        for stop in ["error", "aborted"] {
            let entry: JSONValue = ["id": "failed", "type": "message", "message": [
                "role": "assistant", "stopReason": .string(stop), "errorMessage": "provider failed",
                "content": .array([["type": "text", "text": "Partial answer\n@ask b: do not send this"]])]]
            let event = try XCTUnwrap(PiEntries.events(from: [entry], sessionID: "s", agentID: "a").first)
            let partial = try XCTUnwrap(TranscriptItem(event: event))
            XCTAssertEqual(partial.role, .assistant)
            XCTAssertNil(ProjectChatStore.response(to: request, transcript: [prompt, partial]))
            XCTAssertEqual(ProjectChatStore.failure(to: request, transcript: [prompt, partial]), stop == "aborted" ? "Aborted" : "provider failed")
        }
    }
}
