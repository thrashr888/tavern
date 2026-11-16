import XCTest
@testable import TavernCore

final class ProjectChatAdversarialTests: XCTestCase {
    func testCancelledUnsentMessageNeverLeaksIntoLaterSharedContext() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Cancellation", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let cancelled = try store.enqueue(chat: chat, recipients: ["a"], text: "CANCELLED_UNSENT_CONTENT", allowedPiIDs: ["a", "b"])[0]
        try store.cancelQueued(cancelled.id)
        _ = try store.enqueue(chat: chat, recipients: ["b"], text: "Next actual message", allowedPiIDs: ["a", "b"])
        let next = try XCTUnwrap(store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"]))
        XCTAssertFalse(try XCTUnwrap(next.prompt).contains("CANCELLED_UNSENT_CONTENT"))
    }

    func testCancelledUnsentMessageNeverLeaksIntoImmediatePrepareContext() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Cancellation", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let cancelled = try store.enqueue(chat: chat, recipients: ["a"], text: "CANCELLED_UNSENT_CONTENT", allowedPiIDs: ["a", "b"])[0]
        try store.cancelQueued(cancelled.id)
        let next = try store.prepare(chat: chat, recipient: "b", text: "Next actual message", allowedPiIDs: ["a", "b"])
        XCTAssertFalse(try XCTUnwrap(next.prompt).contains("CANCELLED_UNSENT_CONTENT"))
    }

    func testSettledFailedToolWithoutAssistantReplyClosesTheRequest() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Interrupted tool", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let request = try store.prepare(chat: chat, recipient: "a", text: "Bounded tool check", allowedPiIDs: ["a", "b"])
        let prompt = TranscriptItem(id: "u", role: .user, text: try XCTUnwrap(request.prompt), date: Date())
        // Real durable-host shape observed after Stop: only an isError tool result, no
        // assistant stopReason=aborted or system abort entry. Callers require settled idle.
        let entry: JSONValue = ["id": "tool-end", "type": "message", "message": [
            "role": "toolResult", "toolName": "sandbox_run", "toolCallId": "call-1", "isError": true,
            "content": .array([["type": "text", "text": "<harness>\n[error] Tool sandbox_run was aborted\n</harness>"]])]]
        let event = try XCTUnwrap(PiEntries.events(from: [entry], sessionID: "s", agentID: "a").first)
        let failed = try XCTUnwrap(TranscriptItem(event: event))
        XCTAssertNil(ProjectChatStore.response(to: request, transcript: [prompt, failed]))
        XCTAssertEqual(ProjectChatStore.failure(to: request, transcript: [prompt, failed]), "sandbox_run failed without a final reply")

        let recovered = TranscriptItem(id: "answer", role: .assistant, text: "I recovered from the tool error", date: Date())
        XCTAssertEqual(ProjectChatStore.response(to: request, transcript: [prompt, failed, recovered])?.id, recovered.id)
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, failed, recovered]))
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [failed]))
        XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, TranscriptItem(id: "private", role: .user, text: "Unrelated private turn", date: Date()), failed]))
        for boundary in [
            TranscriptItem(id: "later", role: .user, text: "Next private turn", date: Date()),
            TranscriptItem(id: "compacted", role: .system, text: "Context compacted", date: Date()),
            TranscriptItem(id: "model", role: .system, text: "Model changed", date: Date())
        ] {
            XCTAssertEqual(ProjectChatStore.failure(to: request, transcript: [prompt, failed, boundary]), "sandbox_run failed without a final reply")
            XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, boundary, failed]))
            XCTAssertNil(ProjectChatStore.failure(to: request, transcript: [prompt, failed, recovered, boundary]))
        }
    }

    func testUnattemptedMessagesDoNotEnterHandoffOrRemovedParticipantContext() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        var chat = try store.create(title: "Membership", participants: ["a", "b", "c"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        try store.setCoordinationEnabled(chat, true)
        chat = try XCTUnwrap(store.chats().first)
        _ = try store.enqueue(chat: chat, recipients: ["c"], text: "REMOVED_RECIPIENT_UNSENT", allowedPiIDs: ["a", "b", "c"])
        try store.setParticipants(chat, participants: ["a", "b"], allowedPiIDs: ["a", "b", "c"])
        XCTAssertNil(try store.claimNextQueued(recipient: "c", allowedPiIDs: ["a", "b", "c"]))
        let root = try store.enqueue(chat: chat, recipients: ["a"], text: "Actual question", allowedPiIDs: ["a", "b", "c"])[0]
        let request = try XCTUnwrap(store.claimNextQueued(recipient: "a", allowedPiIDs: ["a", "b", "c"]))
        XCTAssertEqual(request.id, root.id)
        XCTAssertFalse(try XCTUnwrap(request.prompt).contains("REMOVED_RECIPIENT_UNSENT"))
        let reply = try store.reply(to: request, item: TranscriptItem(id: "r", role: .assistant, text: "@ask b: Answer the actual question", date: Date()))
        _ = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b", "c"], availablePiIDs: [])
        let handoff = try XCTUnwrap(store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b", "c"]))
        XCTAssertFalse(try XCTUnwrap(handoff.prompt).contains("REMOVED_RECIPIENT_UNSENT"))
        XCTAssertTrue(try XCTUnwrap(handoff.prompt).contains("Actual question"))
    }

    func testImmediatePrepareDoesNotDiscloseUnattemptedQueuedMessageToAnotherParticipant() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Queued", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        _ = try store.enqueue(chat: chat, recipients: ["a"], text: "STILL_UNSENT", allowedPiIDs: ["a", "b"])
        let next = try store.prepare(chat: chat, recipient: "b", text: "Independent request", allowedPiIDs: ["a", "b"])
        XCTAssertFalse(try XCTUnwrap(next.prompt).contains("STILL_UNSENT"))
    }

    func testAttemptedClosedMessageAndCompletedReplyRemainInContext() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "History", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        var attempted = try store.prepare(chat: chat, recipient: "a", text: "ATTEMPTED_REQUEST", allowedPiIDs: ["a", "b"])
        attempted.state = .closed
        try store.save(attempted)
        let answered = try store.prepare(chat: chat, recipient: "a", text: "ANSWERED_REQUEST", allowedPiIDs: ["a", "b"])
        _ = try store.reply(to: answered, item: TranscriptItem(id: "r", role: .assistant, text: "COMPLETED_REPLY", date: Date()))
        _ = try store.enqueue(chat: chat, recipients: ["b"], text: "Next request", allowedPiIDs: ["a", "b"])
        let prompt = try XCTUnwrap(store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"])?.prompt)
        XCTAssertTrue(prompt.contains("ATTEMPTED_REQUEST"))
        XCTAssertTrue(prompt.contains("ANSWERED_REQUEST"))
        XCTAssertTrue(prompt.contains("COMPLETED_REPLY"))
    }
}
