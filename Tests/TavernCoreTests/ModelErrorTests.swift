import XCTest
@testable import TavernCore

final class ModelErrorTests: XCTestCase {
    func testAnthropicBody() {
        let error = ModelError.parse(#"401 {"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."},"request_id":"req_011CgAV2"}"#)
        XCTAssertEqual(error, ModelError(title: "Not signed in", message: "OAuth access token is invalid.", status: 401, requestID: "req_011CgAV2"))
    }

    func testNoticeWrapsAQuotedError() {
        let error = ModelError.parse(#"No answer: model_error "400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Needs a workspace.\"}}""#)
        XCTAssertEqual(error.title, "Request rejected")
        XCTAssertEqual(error.message, "Needs a workspace.")
        XCTAssertEqual(error.status, 400)
    }

    func testNoModelAndPlainText() {
        XCTAssertEqual(ModelError.parse("No answer: no_model").title, "No model configured")
        let plain = ModelError.parse("404: model not found")
        XCTAssertEqual(plain.title, "Model error")
        XCTAssertEqual(plain.message, "404: model not found")
        XCTAssertEqual(ModelError.parse("429 slow down").summary, "Rate limited or out of quota: slow down")
    }
}

final class DockerTests: XCTestCase {
    func testParsesJSONLinesRunningFirst() {
        let out = """
        {"ID":"b2","Names":"redis","Image":"redis:7","State":"exited","Status":"Exited (0) 2 days ago","Ports":""}
        {"ID":"a1","Names":"web","Image":"nginx","State":"running","Status":"Up 13 days","Ports":"0.0.0.0:80->80/tcp"}
        not json
        """
        let containers = DockerContainer.parse(out)
        XCTAssertEqual(containers.map(\.name), ["web", "redis"])
        XCTAssertTrue(containers[0].isRunning)
    }

    func testOneHostPerMachineThisMacFirst() {
        let hosts = DockerHost.hosts(for: .fixture)
        XCTAssertEqual(hosts.map(\.id), ["self", "server-a", "laptop-b"])
        XCTAssertEqual(hosts[1].argv.prefix(2), ["/usr/bin/ssh", "-T"])
    }
}

final class PiModelNameTests: XCTestCase {
    func testShortNames() {
        XCTAssertEqual(PiModel(provider: "anthropic", id: "claude-sonnet-4-6").shortName, "Sonnet 4.6")
        XCTAssertEqual(PiModel(provider: "anthropic", id: "claude-opus-4-5-20251101").shortName, "Opus 4.5")
        XCTAssertEqual(PiModel(provider: "ollama", id: "qwen3.5:35b-a3b-coding-nvfp4").shortName, "qwen3.5:35b")
        XCTAssertEqual(PiModel(provider: "openai", id: "gpt-5").shortName, "gpt-5")
    }
}

final class MarkdownBlockTests: XCTestCase {
    func testBlocks() {
        let text = """
        ## Result
        Docker is **up**.

        - rookery-web
        - redis
          (cache)
        1. first
        2. second

        ```sh
        docker ps
        ```
        > note
        | a | b |
        |---|---|
        ---
        tail
        """
        XCTAssertEqual(MarkdownBlock.parse(text), [
            .heading(level: 2, text: "Result"),
            .paragraph("Docker is **up**."),
            .list(items: ["rookery-web", "redis (cache)"], ordered: false),
            .list(items: ["first", "second"], ordered: true),
            .code(language: "sh", text: "docker ps"),
            .quote("note"),
            .table("| a | b |\n|---|---|"),
            .rule,
            .paragraph("tail"),
        ])
    }

    func testUnclosedFenceKeepsCode() {
        XCTAssertEqual(MarkdownBlock.parse("```\nlet x = 1"), [.code(language: nil, text: "let x = 1")])
        XCTAssertEqual(MarkdownBlock.parse("#hashtag"), [.paragraph("#hashtag")])
    }
}

final class AssignmentTests: XCTestCase {
    func testRecordMovesAndMergesLabels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assign-\(UUID()).json")
        let store = AssignmentStore(url: url)
        _ = try store.record(TaskAssignment(identifier: "PAUL-1", title: "One", url: nil, agentID: "tally"))
        let all = try store.record(TaskAssignment(identifier: "PAUL-1", title: "One", url: nil, agentID: "ember"))
        XCTAssertEqual(all.map(\.agentID), ["ember"])

        let ember = Roster.fixture.member(id: "ember")!
        let open = [LinearIssue(identifier: "PAUL-2", title: "Two", state: "Todo", labels: ["agent:Ember"])]
        let tasks = AssignmentStore.tasks(for: ember, assignments: store.load(), openIssues: open)
        XCTAssertEqual(tasks.map(\.identifier), ["PAUL-1", "PAUL-2"])
        XCTAssertNil(tasks[0].state, "PAUL-1 isn't open any more")
        XCTAssertTrue(tasks[1].fromLabel)
        XCTAssertTrue(tasks[0].isNewlyFinished)
        _ = try store.acknowledge("PAUL-1")
        XCTAssertFalse(AssignmentStore.tasks(for: ember, assignments: store.load(), openIssues: open)[0].isNewlyFinished)
    }
}

final class MailAskTests: XCTestCase {
    func mail(_ subject: String, _ body: String) -> MailThread {
        MailThread(threadID: "t", messages: [MailItem(id: "m", threadID: "t", subject: subject, from: "rook@x", author: "rook",
                                                     project: nil, date: Date(), snippet: "", body: body)])
    }

    func testAsksAndHeartbeats() {
        XCTAssertEqual(mail("The Guild: retro", "Wins.\nNeeds from Sam: approve the portrait.").ask(of: "Sam"), "approve the portrait")
        XCTAssertNil(mail("The Guild: retro", "Needs from Sam: nothing.").ask(of: "Sam"))
        XCTAssertNil(mail("The Guild: portrait", "Needs from Sam: none now. He'll review it.").ask(of: "Sam"))
        XCTAssertNil(mail("Ember Heartbeat — Action Needed", "x").ask(of: "Sam"))
        XCTAssertNotNil(mail("The Guild: Action needed on keys", "x").ask(of: "Sam"))
        XCTAssertTrue(mail("Tally Heartbeat — Party Mail", "x").isHeartbeat)
    }
}

final class PresenceTests: XCTestCase {
    func testLastSeenAndPages() {
        let old = MailItem(id: "a", threadID: "t1", subject: "s", from: "r", author: "rook", project: nil, date: Date(timeIntervalSince1970: 10), snippet: "", body: "")
        let new = MailItem(id: "b", threadID: "t2", subject: "s", from: "r", author: "rook", project: nil, date: Date(timeIntervalSince1970: 20), snippet: "", body: "")
        let threads = [MailThread(threadID: "t1", messages: [old]), MailThread(threadID: "t2", messages: [new])]
        XCTAssertEqual(threads.lastSeen()["rook"], Date(timeIntervalSince1970: 20))
        XCTAssertEqual(threads.involving("rook").map(\.threadID), ["t2", "t1"])
        XCTAssertEqual(Page(storageKey: "member:rook"), .member(id: "rook"))
        XCTAssertEqual(Page.restore("member:rook", roster: .fixture), .member(id: "rook"))
        XCTAssertEqual(Page.forMember(Roster.fixture.member(id: "tally")!), .agent(id: "tally"))
    }
}

final class AuthorTests: XCTestCase {
    func testSignOffsFromPaulsAddress() {
        let roster = Roster.fixture
        XCTAssertEqual(MailItem.detectAuthor(from: "Sam Rivera <sam@example.com>", body: "Plan is up.\r\n\r\nQuill\r\n", roster: roster), "quill")
        XCTAssertNil(MailItem.detectAuthor(from: "sam@example.com", body: "ok\n> \n> Rook", roster: roster), "a quoted sign-off isn't this mail's")
        XCTAssertEqual(MailItem.detectAuthor(from: "sam@example.com", body: "Hold the merge.\r\n\r\nInstinct", roster: roster), "rook")
        XCTAssertNil(MailItem.detectAuthor(from: "sam@example.com", body: "thanks!\nPaul", roster: roster))
    }
}

final class IMessageTests: XCTestCase {
    func testKeepsOneConversationOldestFirst() {
        let json = """
        [{"conversation":"+16505550100","id":2,"is_from_me":false,"sender":"+16505550100","service":"iMessage","text":"Doc pass done","timestamp":"2026-10-18T22:30:52Z"},
         {"conversation":"+16505550100","id":1,"is_from_me":true,"sender":"Me","service":"iMessage","text":"Ok, just fix em","timestamp":"2026-10-18T22:20:00Z"},
         {"conversation":"+14155550123","id":3,"is_from_me":false,"sender":"+14155550123","service":"iMessage","text":"someone else","timestamp":"2026-10-18T22:31:00Z"}]
        """
        let messages = CiderMessages.parse(Data(json.utf8), handle: "+1 (650) 555-0100")
        XCTAssertEqual(messages.map(\.text), ["Ok, just fix em", "Doc pass done"])
        XCTAssertTrue(messages[0].fromMe)
        XCTAssertTrue(CiderMessages.parse(Data(json.utf8), handle: "+44 6505550100").isEmpty, "a number that only shares the last digits doesn't match")
    }
}

final class AttachmentCacheTests: XCTestCase {
    func testNamesMatchTheHostAndSplitFindsPaths() {
        // node: crypto.createHash("sha256").update(Buffer.from([1,2,3])).digest("hex").slice(0,16)
        XCTAssertEqual(AttachmentCache.name(for: Data([1, 2, 3]), ext: "png"), "039058c6f2c0cb49.png")
        let split = AttachmentCache.split("Look\n\nAttached images (open with your read tool):\n- /a/x.png\n- /a/y.jpg")
        XCTAssertEqual(split.text, "Look")
        XCTAssertEqual(split.paths, ["/a/x.png", "/a/y.jpg"])
    }
}

final class IMessageAttachmentTests: XCTestCase {
    func testAttachmentsAndImageOnlyMessages() {
        let json = """
        [{"conversation":"+16505550100","id":"msg_9","is_from_me":false,"text":"[Attachment]","timestamp":"2026-10-18T22:30:52Z",
          "attachments":["/Users/p/Library/Messages/Attachments/a/IMG_1.HEIC","/Users/p/Library/Messages/Attachments/b/x.pluginPayloadAttachment"]}]
        """
        let message = CiderMessages.parse(Data(json.utf8), handle: "+16505550100")[0]
        XCTAssertEqual(message.images, ["/Users/p/Library/Messages/Attachments/a/IMG_1.HEIC"])
        XCTAssertEqual(message.displayText, "")
    }
}

final class ProjectOwnerTests: XCTestCase {
    func testOwnerMap() {
        XCTAssertEqual(Roster.fixture.owner(ofProject: "Cider")?.id, "ember")
        XCTAssertEqual(Roster.fixture.owner(ofProject: "Systemd runner")?.id, "peter")
        XCTAssertNil(Roster.fixture.owner(ofProject: "Tavern"))
    }
}

final class MailBodyTests: XCTestCase {
    func testSignOffAboveAQuotedReply() {
        let body = MailItem.stripQuotedReply("Rook,\n\nRetro below.\nWins: shipped.\n\nWololo\n> On Fri, Sam wrote: old")
        XCTAssertEqual(MailItem.detectAuthor(from: "sam@example.com", body: body, roster: .fixture), "wololo")
    }

    func testSignOffLineStartingWithName() {
        XCTAssertEqual(MailItem.detectAuthor(from: "sam@example.com", body: "All clear.\n\n— Tally, Forge Cleric ⚒️", roster: .fixture), "tally")
        XCTAssertEqual(MailItem.detectAuthor(from: "sam@example.com", body: "Done.\n— Ember 🔥, Cleric of the Guild", roster: .fixture), "ember")
        XCTAssertNil(MailItem.detectAuthor(from: "sam@example.com", body: "Tally flagged the same issue this morning and it is still open today.", roster: .fixture))
    }
}

final class MailAddresseeTests: XCTestCase {
    func item(_ body: String) -> MailItem {
        MailItem(id: "m", threadID: "t", subject: "s", from: "r", author: "rook", project: nil, date: Date(), snippet: "", body: body)
    }

    func testGreetingNamesOnly() {
        XCTAssertEqual(item("Peter, Ember, Tally - quick nudge on the ask above. Flint knows.").addressees(in: .fixture), ["tally", "ember", "peter"])
        XCTAssertEqual(item("Quill (cc Wololo, Tally), the plan is approved.\nRook").addressees(in: .fixture), ["tally", "quill", "wololo"])
        XCTAssertEqual(item("Hi all: Tally said it's done.").addressees(in: .fixture), [])
    }
}

final class TrustedSenderTests: XCTestCase {
    func testOnlyListedSendersAreTrusted() {
        var roster = Roster.fixture
        roster.trustedSenders = ["sam@example.com"]
        XCTAssertTrue(roster.isTrustedSender("Sam Rivera <sam@example.com>"))
        XCTAssertTrue(roster.isTrustedSender("Rook <rook@mail.instinct.example>"))
        XCTAssertFalse(roster.isTrustedSender("Mallory <mallory@evil.example>"))
        XCTAssertFalse(roster.isTrustedSender("sam@example.com <mallory@evil.example>"), "display name doesn't count")
        XCTAssertFalse(roster.isTrustedSender("x <rook@mail.instinct.example.evil>"))
        XCTAssertFalse(roster.isTrustedSender("<mallory@evil.example> <sam@example.com>"), "two mailboxes")
        XCTAssertFalse(roster.isTrustedSender("sam@example.com, mallory@evil.example"))
        XCTAssertTrue(roster.isTrustedSender("\"Sam <x@y.z>\" <sam@example.com>"), "a quoted display name is skipped")
    }
}

final class LinkedTextTests: XCTestCase {
    func testWebAddressesBecomeLinks() {
        let text = "Herald: https://files.example.com/herald-oct-19?via=im and www.example.org, not mailto:x@y.z or ftp://host/x."
        let links = LinkedText.links(in: text).map(\.absoluteString)
        XCTAssertEqual(links.first, "https://files.example.com/herald-oct-19?via=im")
        XCTAssertFalse(links.contains { $0.hasPrefix("mailto:") || $0.hasPrefix("ftp:") })
        XCTAssertEqual(String(LinkedText.attributed(text).characters), text, "the text itself is unchanged")
    }
}

final class ReactionTests: XCTestCase {
    private func message(_ id: String, _ text: String, fromMe: Bool = false) -> IMessage {
        IMessage(id: id, text: text, fromMe: fromMe, date: Date())
    }

    func testTapbacksParse() {
        XCTAssertEqual(Tapback(text: "Liked “Reading our retro today.”"), Tapback(emoji: "👍", quoted: "Reading our retro today.", removed: false))
        XCTAssertEqual(Tapback(text: "Laughed at “ha”")?.emoji, "😂")
        XCTAssertEqual(Tapback(text: "Reacted 🎉 to “Shipped it”"), Tapback(emoji: "🎉", quoted: "Shipped it", removed: false))
        XCTAssertEqual(Tapback(text: "Removed a heart from “ok”")?.removed, true)
        XCTAssertNil(Tapback(text: "Liked the plan, thanks"))
        XCTAssertNil(Tapback(text: "Reacted strongly to the news"))
    }

    func testTapbacksFoldIntoTheirMessage() {
        let rows = IMessage.withReactions([
            message("1", "Reading our retro today. Quill can be the default project owner for Tavern work"),
            message("2", "Sounds good", fromMe: true),
            message("3", "Liked “Reading our retro today. Quill can be the default…”", fromMe: true),
            message("4", "Loved “Sounds good”"),
            message("5", "Liked “something from last month”"),
        ])
        XCTAssertEqual(rows.map(\.id), ["1", "2", "5"], "tapbacks fold away; one with no message in view stays")
        XCTAssertEqual(rows[0].reactions, [Reaction(emoji: "👍", fromMe: true)])
        XCTAssertEqual(rows[1].reactions, [Reaction(emoji: "❤️", fromMe: false)])
        let removed = IMessage.withReactions([message("1", "ok"), message("2", "Loved “ok”"), message("3", "Removed a heart from “ok”")])
        XCTAssertEqual(removed.map(\.reactions), [[]])
    }
}

final class PiReactionNoteTests: XCTestCase {
    func testNotesGoToTheAgentButNotTheThread() {
        let pending = [PiReactions.Stored(target: "e2", emoji: "👍", on: true, delivered: false, preview: "Fixed the pricing page.\nBuild passes.",
                                          sourceID: "r1", date: Date()),
                       PiReactions.Stored(target: "e3", emoji: "🎉", on: true, delivered: true, preview: "Old", sourceID: "r2", date: Date()),
                       PiReactions.Stored(target: "e4", emoji: "👀", on: false, delivered: false, preview: "Off", sourceID: "r3", date: Date())]
        let note = PiReactions.note(for: pending)
        XCTAssertEqual(note, "[Reaction] 👍 on your reply: “Fixed the pricing page. Build passes.”", "only new, on reactions")
        XCTAssertEqual(PiReactions.withoutNotes("Ship it\n\n" + note!), "Ship it")
        XCTAssertEqual(PiReactions.withoutNotes("No notes here"), "No notes here")
    }
}

final class MailSearchTests: XCTestCase {
    func testThreadsMatchOnSubjectPeopleAndText() {
        let roster = Roster.fixture
        let member = roster.members.first!
        let thread = MailThread(threadID: "t", messages: [
            MailItem(id: "1", threadID: "t", subject: "Website: annual plan price", from: "Lark <lark@example.com>", author: nil, project: nil,
                     date: Date(), snippet: "", body: "The pricing page still says $96."),
            MailItem(id: "2", threadID: "t", subject: "Re: Website", from: "x@example.com", author: member.id, project: nil,
                     date: Date(), snippet: "", body: "On it. PR is up."),
        ])
        XCTAssertTrue(thread.matches("annual", roster: roster))
        XCTAssertTrue(thread.matches("lark pricing", roster: roster), "every word, anywhere in the thread")
        XCTAssertTrue(thread.matches(member.name.lowercased(), roster: roster), "member names count")
        XCTAssertTrue(thread.matches("  ", roster: roster))
        XCTAssertFalse(thread.matches("pricing staging", roster: roster))
    }
}
