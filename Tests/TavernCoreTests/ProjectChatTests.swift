import XCTest
@testable import TavernCore

final class ProjectChatTests: XCTestCase {
    func testLeadingMentionsAndAddressedDelivery() throws {
        XCTAssertEqual(ProjectChatStore.leadingMentions(in: "@Ember @flint: please review"), ["ember", "flint"])
        XCTAssertEqual(ProjectChatStore.leadingMentions(in: "@ember, @ember: hello"), ["ember"])
        for text in ["mail a@ember.com", "> @ember: example", "```@ember```", "Hello @ember", "@ember.example"] {
            XCTAssertEqual(ProjectChatStore.leadingMentions(in: text), [])
        }
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Team", participants: ["a", "b", "c"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        XCTAssertThrowsError(try store.prepareAddressed(chat: chat, recipients: ["outsider"], text: "hello", allowedPiIDs: ["outsider"]))
        XCTAssertEqual(try store.messages().count, 0)
        let requests = try store.prepareAddressed(chat: chat, recipients: ["b", "c"], text: "@b @c hello", allowedPiIDs: ["a", "b", "c"])
        XCTAssertEqual(Set(requests.compactMap(\.recipient)), ["b", "c"])
        XCTAssertTrue(requests.allSatisfy { $0.permitsSilence == false })
        XCTAssertEqual(Set(requests.compactMap(\.rootRequestID)).count, 1)
    }

    func testGroupSilenceIsDurableInvisibleAndOnlyForBroadcasts() throws {
        let db = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: db)
        let chat = try store.create(title: "Group", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let requests = try store.prepareAll(chat: chat, text: "FYI", allowedPiIDs: ["a", "b"])
        XCTAssertTrue(requests.allSatisfy { $0.permitsSilence == true })
        XCTAssertTrue(requests[0].prompt!.contains("Respond only when addressed"))
        let silent = TranscriptItem(id: "quiet", role: .assistant, text: "[TAVERN_NO_REPLY]", date: Date())
        XCTAssertTrue(try store.consumeSilentResponse(to: requests[0], item: silent))
        XCTAssertTrue(try store.consumeSilentResponse(to: requests[0], item: silent))
        let reopened = ProjectChatStore(store: db)
        XCTAssertEqual(try reopened.messages().count, 2)
        XCTAssertEqual(try reopened.messages().first { $0.id == requests[0].id }?.state, .replied)
        XCTAssertFalse(try reopened.messages().contains { $0.text.contains("TAVERN_NO_REPLY") })
        let direct = try store.prepare(chat: chat, recipient: requests[0].recipient, text: "Question", allowedPiIDs: ["a", "b"])
        XCTAssertFalse(try store.consumeSilentResponse(to: direct, item: silent))
        let quoted = TranscriptItem(id: "quote", role: .assistant, text: "The marker is [TAVERN_NO_REPLY].", date: Date())
        XCTAssertFalse(try store.consumeSilentResponse(to: requests[1], item: quoted))
    }

    func testRenamePreservesIdentityHistoryAndLatestSettings() throws {
        let db = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: db)
        let chat = try store.create(title: "Original", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        let request = try store.prepare(chat: chat, recipient: "a", text: "Keep history", allowedPiIDs: ["a", "b"])
        try store.setParticipants(chat, participants: ["a", "b", "c"], allowedPiIDs: ["a", "b", "c"])
        try store.setLead(chat, "b")
        try store.setCoordinationEnabled(chat, true)
        try store.rename(chat, title: "  New name  ")
        let updated = try XCTUnwrap(ProjectChatStore(store: db).chats().first)
        XCTAssertEqual(updated.id, chat.id)
        XCTAssertEqual(updated.title, "New name")
        XCTAssertEqual(updated.participants, ["a", "b", "c"])
        XCTAssertEqual(updated.lead, "b")
        XCTAssertEqual(updated.coordinationEnabled, true)
        XCTAssertEqual(try store.messages(), [request])
        for name in ["", "  ", "\n\t", String(repeating: "x", count: 121), "Two\nlines"] {
            XCTAssertThrowsError(try store.rename(chat, title: name))
        }
        XCTAssertEqual(try store.chats().first, updated)
        XCTAssertNoThrow(try store.rename(chat, title: String(repeating: "x", count: 120)))
    }
    func testParticipantsAndLead() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        XCTAssertThrowsError(try store.create(title: "Work", participants: ["a"], lead: "a", allowedPiIDs: ["a", "b"]))
        XCTAssertThrowsError(try store.create(title: "Work", participants: ["a", "hosted"], lead: nil, allowedPiIDs: ["a", "b"]))
        XCTAssertThrowsError(try store.create(title: "Work", participants: ["a", "b"], lead: "c", allowedPiIDs: ["a", "b"]))
        let chat = try store.create(title: "Work", participants: ["a", "b", "a"], lead: "b", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(chat.participants, ["a", "b"])
        XCTAssertEqual(try store.chats(), [chat])
    }
    func testRoutingAndNoAutomaticRetry() throws {
        let db = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: db)
        let chat = try store.create(title: "Work", participants: ["a", "b"], lead: "b", allowedPiIDs: ["a", "b"])
        XCTAssertThrowsError(try store.prepare(chat: chat, recipient: "c", text: "hello", allowedPiIDs: ["a", "b"]))
        let request = try store.prepare(chat: chat, recipient: nil, text: "hello", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(request.recipient, "b")
        let reopened = ProjectChatStore(store: db)
        XCTAssertEqual(try reopened.messages().first?.state, .dispatching)
        XCTAssertThrowsError(try reopened.prepare(chat: chat, recipient: "b", text: "again", allowedPiIDs: ["a", "b"]))
        XCTAssertNoThrow(try reopened.prepare(chat: chat, recipient: "a", text: "different agent", allowedPiIDs: ["a", "b"]))
    }
    func testReplyCorrelationAndDeduplication() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Work", participants: ["a", "b"], lead: nil, allowedPiIDs: ["a", "b"])
        let request = try store.prepare(chat: chat, recipient: "a", text: "hello", allowedPiIDs: ["a", "b"])
        let before = TranscriptItem(id: "old", role: .assistant, text: "private old content", date: Date())
        let prompt = TranscriptItem(id: "prompt", role: .user, text: request.prompt!, date: Date())
        let answer = TranscriptItem(id: "answer", role: .assistant, text: "result", date: Date())
        XCTAssertNil(ProjectChatStore.response(to: request, transcript: [before, answer]))
        XCTAssertEqual(ProjectChatStore.response(to: request, transcript: [before, prompt, answer]), answer)
        let other = TranscriptItem(id: "other", role: .user, text: "unrelated", date: Date())
        XCTAssertNil(ProjectChatStore.response(to: request, transcript: [prompt, other, answer]))
        try store.reply(to: request, item: answer)
        try store.reply(to: request, item: answer)
        let messages = try store.messages(chatID: chat.id)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.author, "a")
        XCTAssertFalse(messages.contains { $0.text.contains("private old") })
        XCTAssertNoThrow(try store.prepare(chat: chat, recipient: "a", text: "next", allowedPiIDs: ["a", "b"]))
    }
    func testHomeIsDurableMainThreadAndCannotBeRemoved() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        XCTAssertNil(try store.ensureHome(participants: []))
        let home = try XCTUnwrap(store.ensureHome(participants: ["a", "b"]))
        XCTAssertEqual(home.id, ProjectChatStore.homeID)
        XCTAssertEqual(home.lead, "a")
        let message = try store.prepare(chat: home, recipient: nil, text: "main thread", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(try store.ensureHome(participants: ["a", "b"]), home)
        try store.setArchived(home, true)
        XCTAssertNotEqual(try store.chats().first?.archived, true)
        XCTAssertEqual(try store.messages().first, message)
        XCTAssertEqual(try store.chats().count, 1)
    }
    func testDefaultLeadAndSwitchPreserveConversation() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Work", participants: ["b", "a"], lead: nil, allowedPiIDs: ["a", "b"])
        XCTAssertEqual(chat.lead, "b")
        let request = try store.prepare(chat: chat, recipient: nil, text: "first", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(request.recipient, "b")
        XCTAssertThrowsError(try store.setLead(chat, "outsider"))
        try store.setLead(chat, "a")
        let updated = try XCTUnwrap(store.chats().first)
        XCTAssertEqual(updated.id, chat.id)
        XCTAssertEqual(updated.lead, "a")
        XCTAssertEqual(try store.messages().first, request)
        XCTAssertEqual(try store.prepare(chat: updated, recipient: nil, text: "next", allowedPiIDs: ["a", "b"]).recipient, "a")
    }
    func testRemovalIsRecoverableAndPreservesMessages() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Keep", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let message = try store.prepare(chat: chat, recipient: nil, text: "Keep this history", allowedPiIDs: ["a", "b"])
        try store.setArchived(chat, true)
        XCTAssertEqual(try store.chats().first?.archived, true)
        XCTAssertEqual(try store.messages().first, message)
        try store.setArchived(try XCTUnwrap(store.chats().first), false)
        XCTAssertEqual(try store.chats().first?.archived, false)
        XCTAssertEqual(try store.messages().first, message)
    }
    func testDiskPersistenceAndExplicitClose() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = ProjectChatStore(store: try EventStore(path: path))
        let chat = try store.create(title: "Disk", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        var request = try store.prepare(chat: chat, recipient: nil, text: "persist", allowedPiIDs: ["a", "b"])
        let reopened = ProjectChatStore(store: try EventStore(path: path))
        XCTAssertEqual(try reopened.chats(), [chat])
        XCTAssertEqual(try reopened.messages().first?.state, .dispatching)
        request.state = .closed
        try reopened.save(request)
        XCTAssertEqual(try store.messages().first?.state, .closed)
        XCTAssertNoThrow(try store.prepare(chat: chat, recipient: nil, text: "new explicit send", allowedPiIDs: ["a", "b"]))
    }
    func testContextsDoNotMixAcrossProjects() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let one = try store.create(title: "One", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        let two = try store.create(title: "Two", participants: ["a", "b"], lead: "b", allowedPiIDs: ["a", "b"])
        _ = try store.prepare(chat: one, recipient: nil, text: "only project one", allowedPiIDs: ["a", "b"])
        let other = try store.prepare(chat: two, recipient: nil, text: "hello", allowedPiIDs: ["a", "b"])
        XCTAssertFalse(other.prompt!.contains("only project one"))
    }
    func testBroadcastPreflightAndSharedRoot() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        let chat = try store.create(title: "Team", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        XCTAssertThrowsError(try store.prepareAll(chat: chat, text: "hi", allowedPiIDs: ["a"]))
        XCTAssertEqual(try store.messages().count, 0)
        var busy = try store.prepare(chat: chat, recipient: "b", text: "busy", allowedPiIDs: ["a", "b"])
        XCTAssertThrowsError(try store.prepareAll(chat: chat, text: "hi", allowedPiIDs: ["a", "b"]))
        XCTAssertEqual(try store.messages().count, 1)
        busy.state = .closed; try store.save(busy)
        let all = try store.prepareAll(chat: chat, text: "hi", allowedPiIDs: ["a", "b"])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.compactMap(\.rootRequestID)).count, 1)
        XCTAssertEqual(Set(all.compactMap(\.recipient)), ["a", "b"])
    }
    func testHandoffParserIgnoresQuotedCasualAndCode() {
        let text = """
        mention @a casually
        > @ask a: quoted
            @ask b: indented
        ```
        @ask a: code
        ```
        ~~~swift
        @ask a: also code
        ~~~
        @ask b: actual question
        @ask b: duplicate
        @ask unknown id: invalid
        """
        let parsed = ProjectChatStore.handoffDirectives(in: text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.recipient, "b")
        XCTAssertEqual(parsed.first?.text, "actual question")
    }
    func testHandoffBoundAndIdempotency() throws {
        let db = try EventStore(path: ":memory:")
        let store = ProjectChatStore(store: db)
        var chat = try store.create(title: "Team", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        try store.setCoordinationEnabled(chat, true); chat = try XCTUnwrap(store.chats().first)
        var request = try store.prepare(chat: chat, recipient: "a", text: "coordinate", allowedPiIDs: ["a", "b"])
        for hop in 0..<5 {
            let target = request.recipient == "a" ? "b" : "a"
            let item = TranscriptItem(id: "answer-\(hop)", role: .assistant, text: "@ask \(target): help", date: Date())
            let reply = try store.reply(to: request, item: item)
            let result = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: ["a", "b"])
            XCTAssertEqual(result.requests.count, hop < 4 ? 1 : 0)
            XCTAssertTrue(try ProjectChatStore(store: db).prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: ["a", "b"]).requests.isEmpty)
            if let next = result.requests.first {
                XCTAssertEqual(next.author, request.recipient)
                XCTAssertEqual(next.rootRequestID, request.rootRequestID)
                XCTAssertEqual(next.state, .queued)
                request = try XCTUnwrap(store.claimNextQueued(recipient: next.recipient!, allowedPiIDs: ["a", "b"]))
                XCTAssertTrue(request.prompt!.contains("not a new human instruction or permission"))
            }
        }
    }
    func testBusyHandoffQueuedOnceAndNotReplayed() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        var chat = try store.create(title: "Team", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b"])
        try store.setCoordinationEnabled(chat, true); chat = try XCTUnwrap(store.chats().first)
        let request = try store.prepare(chat: chat, recipient: "a", text: "hi", allowedPiIDs: ["a", "b"])
        let reply = try store.reply(to: request, item: TranscriptItem(id: "r", role: .assistant, text: "@ask b: help", date: Date()))
        let blocked = try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: ["a"])
        XCTAssertEqual(blocked.requests.count, 1)
        XCTAssertEqual(blocked.requests.first?.state, .queued)
        XCTAssertNil(blocked.requests.first?.prompt)
        XCTAssertTrue(blocked.notices.isEmpty)
        XCTAssertTrue(try store.prepareHandoffs(chat: chat, reply: reply, allowedPiIDs: ["a", "b"], availablePiIDs: ["a", "b"]).requests.isEmpty)
        XCTAssertEqual(try store.claimNextQueued(recipient: "b", allowedPiIDs: ["a", "b"])?.id, blocked.requests.first?.id)
    }
    func testParticipantChangesPreserveLeadHistoryAndOutstandingAttribution() throws {
        let store = ProjectChatStore(store: try EventStore(path: ":memory:"))
        var chat = try store.create(title: "Team", participants: ["a", "b"], lead: "a", allowedPiIDs: ["a", "b", "c"])
        try store.setCoordinationEnabled(chat, true); chat = try XCTUnwrap(store.chats().first)
        let outstanding = try store.prepare(chat: chat, recipient: "a", text: "work", allowedPiIDs: ["a", "b", "c"])
        try store.setParticipants(chat, participants: ["c", "a", "b"], allowedPiIDs: ["a", "b", "c"])
        XCTAssertEqual(try store.chats().first?.lead, "a")
        try store.setParticipants(chat, participants: ["c", "b"], allowedPiIDs: ["a", "b", "c"])
        let updated = try XCTUnwrap(store.chats().first)
        XCTAssertEqual(updated.lead, "c")
        XCTAssertEqual(try store.messages().first, outstanding)
        let reply = try store.reply(to: outstanding, item: TranscriptItem(id: "late", role: .assistant, text: "@ask b: help", date: Date()))
        XCTAssertEqual(reply.author, "a")
        let blocked = try store.prepareHandoffs(chat: updated, reply: reply, allowedPiIDs: ["a", "b", "c"], availablePiIDs: ["a", "b", "c"])
        XCTAssertTrue(blocked.requests.isEmpty)
        XCTAssertThrowsError(try store.setParticipants(updated, participants: ["c"], allowedPiIDs: ["a", "b", "c"]))
        XCTAssertThrowsError(try store.setParticipants(updated, participants: ["c", "outside"], allowedPiIDs: ["a", "b", "c"]))
        let home = try XCTUnwrap(store.ensureHome(participants: ["a", "b"]))
        XCTAssertNoThrow(try store.setParticipants(home, participants: ["b"], allowedPiIDs: ["a", "b"]))
    }

}
