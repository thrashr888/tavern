import XCTest
@testable import TavernCore

/// A scripted Personal Agent Proxy MCP server: answers initialize and tools/call, and hands every
/// `read`/`run` to `tool(connection, name, params)`.
final class FakePAP: PAPHTTP, @unchecked Sendable {
    var status = 200
    var calls: [(tool: String, params: JSONValue)] = []
    var connections: JSONValue = .array([
        ["connection": "c-mail", "integration": "Google", "account": "paul@example.com", "can": "Read emails, Archive"],
        ["connection": "c-linear", "integration": "Linear", "account": "Paul", "can": "Read issues, Edit issues"],
    ])
    var tool: (String, JSONValue) throws -> JSONValue = { _, _ in .null }

    func post(_ body: Data, token: String) async throws -> (Data, Int) {
        guard status == 200 else { return (Data(), status) }
        let message = try JSONValue.decode(body)
        guard let id = message["id"] else { return (Data(), 202) }
        let method = message["method"]?.stringValue
        var result: JSONValue = ["protocolVersion": "2025-06-18", "capabilities": .object([:])]
        if method == "tools/call" {
            let name = message["params"]?["name"]?.stringValue ?? ""
            let args = message["params"]?["arguments"] ?? .null
            do {
                let structured: JSONValue
                if name == "list_connections" {
                    structured = ["connections": connections]
                } else {
                    let tool = args["tool"]?.stringValue ?? ""
                    calls.append((tool, args["params"] ?? .null))
                    structured = try self.tool(tool, args["params"] ?? .null)
                }
                result = ["content": .array([["type": "text", "text": "{}"]]), "structuredContent": structured]
            } catch let PAPError.tool(text) {
                result = ["content": .array([["type": "text", "text": .string(text)]]), "isError": true]
            }
        }
        return (try JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).encoded(), 200)
    }

    static func email(_ id: String, subject: String, from: String = "Sam Rivera <sam@example.com>", date: String,
                      folder: String = "Inbox", body: String? = nil) -> JSONValue {
        var values: [String: JSONValue] = ["subject": .string(subject), "from": .string(from), "date": .string(date), "folder": .string(folder)]
        if let body { values["body"] = .string(body) }
        return ["id": .string(id), "values": .object(values), "url": .string("https://mail.google.com/mail/#all/\(id)")]
    }
}

@MainActor
final class PAPMailSyncTests: XCTestCase {
    /// Mail by id, and which ids each search finds.
    var mail: [String: JSONValue] = [:]
    var searches: [String: [String]] = [:]
    var inbox: [String] = []
    let pap = FakePAP()

    override func setUp() async throws {
        pap.tool = { [unowned self] tool, params in
            switch tool {
            case "emails_list":
                let ids = params["folder"]?.stringValue == "Inbox" ? inbox : searches[params["search"]?.stringValue ?? ""] ?? []
                return ["records": .array(ids.compactMap { mail[$0] }), "nextPage": .null]
            case "emails_get":
                guard let record = mail[params["id"]?.stringValue ?? ""] else { throw PAPError.tool("There is no record.") }
                return ["record": record]
            case "emails_archive":
                if params["id"]?.stringValue == "locked" { throw PAPError.tool("This login may not run emails_archive with this connection.") }
                return ["record": .null]
            default:
                return .null
            }
        }
    }

    func testFirstSyncThreadsBySubjectAndVerifiesOnlySentMail() async throws {
        let store = try EventStore(path: ":memory:")
        let client = PAPClient(http: pap) { "token" }
        mail["m1"] = FakePAP.email("m1", subject: "The Guild: Tavern - M1", from: "Paul <paul@example.com>", date: "2026-10-20T10:00:00.000Z",
                                   body: "Quill, plan is up.\n\nPaul")
        mail["m2"] = FakePAP.email("m2", subject: "Re: The Guild: Tavern - M1", from: "Rook <rook@mail.instinct.example>",
                                   date: "2026-10-20T11:00:00.000Z", body: "Looks good.\n\nOn Wed, Sam wrote:\n> Plan is up.")
        let label = PAPMailSync.labelQuery(Roster.fixture.mailLabelName)
        searches[label] = ["m2", "m1"]
        searches["\(label) in:sent"] = ["m1"]
        let sync = PAPMailSync(client: client, store: store, roster: .fixture)

        let added = try await sync.sync()
        XCTAssertEqual(added, 2)
        let threads = MailThread.threads(from: try store.events(source: EventSource.gmail))
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].threadID, "subject:the guild: tavern - m1")
        XCTAssertEqual(threads[0].messages.map(\.verifiedSender), [true, false])
        XCTAssertEqual(threads[0].messages[1].body, "Looks good.")
        XCTAssertEqual(threads[0].gmailURL?.absoluteString, "https://mail.google.com/mail/u/0/#all/m2")
        XCTAssertEqual(try store.cursor(for: PAPMailSync.cursorSource), String(Int(PAPMailSync.parseDate("2026-10-20T11:00:00.000Z")!.timeIntervalSince1970)))

        // Next time: only mail after the newest (less a day), already-stored mail skipped.
        let cursor = Int(try store.cursor(for: PAPMailSync.cursorSource)!)!
        mail["m3"] = FakePAP.email("m3", subject: "RE: The Guild: Tavern - M1", date: "2026-10-20T12:00:00.000Z", body: "Merged.")
        searches["\(label) after:\(cursor - 86_400)"] = ["m3", "m2"]
        pap.calls.removeAll()
        let added2 = try await sync.sync()
        XCTAssertEqual(added2, 1)
        XCTAssertEqual(pap.calls.filter { $0.tool == "emails_get" }.map { $0.params["id"]?.stringValue }, ["m3"])
        XCTAssertEqual(MailThread.threads(from: try store.events(source: EventSource.gmail))[0].messages.count, 3)
    }

    func testReplyJoinsAThreadStoredWithItsGmailThreadID() async throws {
        let store = try EventStore(path: ":memory:")
        let old = GmailMessage(id: "g1", threadID: "t-real", internalDate: Date(timeIntervalSince1970: 1_760_500_000),
                               subject: "The Guild: Alchemy", from: "Sam <sam@example.com>", snippet: "Hi", body: "Hi")
        try store.append([MailItem.event(for: old, roster: .fixture)])

        mail["g1"] = FakePAP.email("g1", subject: "The Guild: Alchemy", date: "2025-10-15T03:46:40.000Z")
        mail["p2"] = FakePAP.email("p2", subject: "Re: The Guild: Alchemy", date: "2026-10-20T12:00:00.000Z", body: "Reply")
        searches[PAPMailSync.labelQuery(Roster.fixture.mailLabelName)] = ["p2", "g1"]
        let added = try await PAPMailSync(client: PAPClient(http: pap) { "t" }, store: store, roster: .fixture).sync()
        XCTAssertEqual(added, 1)
        let threads = MailThread.threads(from: try store.events(source: EventSource.gmail))
        XCTAssertEqual(threads.map(\.threadID), ["t-real"])
        XCTAssertEqual(threads[0].messages.map(\.id), ["g1", "p2"])
    }

    func testArchiveRunsPAPArchiveOnInboxMessagesAndInboxThreads() async throws {
        let store = try EventStore(path: ":memory:")
        mail["a1"] = FakePAP.email("a1", subject: "The Guild: Habitable", date: "2026-10-20T10:00:00.000Z", body: "x")
        mail["a2"] = FakePAP.email("a2", subject: "Re: The Guild: Habitable", date: "2026-10-20T11:00:00.000Z", body: "y")
        searches[PAPMailSync.labelQuery(Roster.fixture.mailLabelName)] = ["a2", "a1"]
        inbox = ["a2"]
        let sync = PAPMailSync(client: PAPClient(http: pap) { "t" }, store: store, roster: .fixture)
        try await sync.sync()

        let threadID = "subject:the guild: habitable"
        let inboxThreads = try await sync.inboxThreads()
        XCTAssertEqual(inboxThreads, [threadID])
        try await sync.archive(threadID: threadID)
        XCTAssertEqual(pap.calls.filter { $0.tool == "emails_archive" }.map { $0.params["id"]?.stringValue }, ["a2"])
    }

    func testArchiveRefusedByPAPSaysSo() async throws {
        let store = try EventStore(path: ":memory:")
        mail["locked"] = FakePAP.email("locked", subject: "Locked", date: "2026-10-20T10:00:00.000Z", body: "x")
        searches[PAPMailSync.labelQuery(Roster.fixture.mailLabelName)] = ["locked"]
        inbox = ["locked"]
        let sync = PAPMailSync(client: PAPClient(http: pap) { "t" }, store: store, roster: .fixture)
        try await sync.sync()
        do {
            try await sync.archive(threadID: "subject:locked")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? PAPError)?.isForbidden, true)
        }
        let feed = MailFeed(store: store, oauth: nil, signedIn: true) { sync }
        await feed.archive(MailThread(threadID: "subject:locked", messages: []))
        XCTAssertEqual(feed.archiveError, "Personal Agent Proxy doesn't let Tavern archive. Allow Archive for Tavern's Gmail there.")
    }

    func testNoGmailConnectionSaysSo() async throws {
        pap.connections = .array([])
        let sync = PAPMailSync(client: PAPClient(http: pap) { "t" }, store: try EventStore(path: ":memory:"), roster: .fixture)
        do {
            try await sync.sync()
            XCTFail("expected noConnection")
        } catch {
            XCTAssertEqual(error as? PAPError, .noConnection("Gmail connection"))
        }
    }

    func testSignedOutProxyFeedSignsOut() async throws {
        pap.status = 401
        let store = try EventStore(path: ":memory:")
        let feed = MailFeed(store: store, oauth: nil, signedIn: true) {
            PAPMailSync(client: PAPClient(http: self.pap) { "t" }, store: store, roster: .fixture)
        }
        await feed.refresh()
        XCTAssertEqual(feed.state, .signedOut)
    }
}

final class PAPClientTests: XCTestCase {
    func testLabelQueryUsesGmailHyphens() {
        XCTAssertEqual(PAPMailSync.labelQuery("The Party"), "label:the-party")
        XCTAssertEqual(PAPMailSync.labelQuery("Work/Agents"), "label:work-agents")
    }

    func testReadsAnSSEReply() throws {
        let data = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)
        XCTAssertEqual(try PAPClient.message(in: data)["id"], .number(1))
    }

    func testToolErrorsCarryPAPsWords() async throws {
        let pap = FakePAP()
        pap.tool = { _, _ in throw PAPError.tool("This login may not run emails_archive with this connection.") }
        let client = PAPClient(http: pap) { "t" }
        do {
            _ = try await client.run("c-mail", "emails_archive", ["id": "x"])
            XCTFail("expected a tool error")
        } catch let error as PAPError {
            XCTAssertTrue(error.isForbidden)
        }
    }
}

final class PAPLinearTests: XCTestCase {
    static func issue(_ id: String, title: String, status: String = "In Progress", type: String = "Started",
                      labels: String? = nil, priority: String? = nil, updated: String = "2026-10-20T10:00:00.000Z") -> JSONValue {
        var values: [String: JSONValue] = ["title": .string(title), "team": "Paul", "status": .string(status), "statusType": .string(type),
                                           "updated": .string(updated)]
        if let labels { values["labels"] = .string(labels) }
        if let priority { values["priority"] = .string(priority) }
        return ["id": .string(id), "values": .object(values), "url": .string("https://linear.app/x/issue/\(id)")]
    }

    func testOpenIssuesAreTheTeamsWithLabelsAndAreOpenedOnce() async throws {
        let pap = FakePAP()
        pap.tool = { tool, params in
            if tool == "issues_list" {
                guard params["statusType"]?.stringValue == "Started" else { return ["records": .array([])] }
                return ["records": .array([Self.issue("PAUL-1", title: "Ship"), Self.issue("ENG-9", title: "Other team")])]
            }
            return ["record": Self.issue("PAUL-1", title: "Ship", labels: "agent:quill, Bug", priority: "High")]
        }
        let linear = LinearSource(proxy: PAPClient(http: pap) { "t" }, teamKey: "PAUL")
        let issues = try await linear.openIssues()
        XCTAssertEqual(issues.map(\.identifier), ["PAUL-1"])
        XCTAssertEqual(issues[0].owner, "quill")
        XCTAssertEqual(issues[0].priority, 2)
        XCTAssertEqual(issues[0].stateType, "started")
        _ = try await linear.openIssues(refresh: true)
        XCTAssertEqual(pap.calls.filter { $0.tool == "issues_get" }.count, 1)
    }

    func testAgentLabelReplacesOtherAgentLabelsAndKeepsTheRest() async throws {
        let pap = FakePAP()
        pap.tool = { tool, _ in
            tool == "issues_get" ? ["record": Self.issue("PAUL-2", title: "Fix", labels: "agent:ember, Bug")] : ["record": .null]
        }
        let linear = LinearSource(proxy: PAPClient(http: pap) { "t" }, teamKey: "PAUL")
        try await linear.assignAgentLabel(issue: "PAUL-2", agentID: "Quill")
        let update = pap.calls.first { $0.tool == "issues_update" }
        XCTAssertEqual(update?.params["labels"], "Bug, agent:quill")
        XCTAssertEqual(update?.params["id"], "PAUL-2")
    }

    func testCreateAndEditWriteNamesThroughRun() async throws {
        let pap = FakePAP()
        pap.tool = { tool, _ in
            tool == "issues_create" ? ["record": Self.issue("PAUL-7", title: "New")] : ["record": .null]
        }
        let linear = LinearSource(proxy: PAPClient(http: pap) { "t" }, teamKey: "PAUL")
        let created = try await linear.createIssue(title: "New", description: "Why", projectID: "Tavern", agentID: "Quill")
        XCTAssertEqual(created.identifier, "PAUL-7")
        try await linear.updateIssue("PAUL-7", stateID: "In Review", priority: 2)
        XCTAssertEqual(pap.calls.map(\.tool), ["issues_create", "issues_update"])
        XCTAssertEqual(pap.calls[0].params["team"], "PAUL")
        XCTAssertEqual(pap.calls[0].params["project"], "Tavern")
        XCTAssertEqual(pap.calls[0].params["labels"], "agent:quill")
        XCTAssertEqual(pap.calls[1].params, ["id": "PAUL-7", "status": "In Review", "priority": "High"])
    }

    func testCommentsParseFromPAPsText() {
        let comments = PAPLinear.comments("Sam Lee · 2026-10-08 08:16 UTC\nFirst\n\n---\n\nReply from Quill · 2026-10-09 09:00 UTC\nOn it")
        XCTAssertEqual(comments.map(\.author), ["Sam Lee", "Quill"])
        XCTAssertEqual(comments.map(\.body), ["First", "On it"])
        XCTAssertNotNil(comments[1].date)
    }
}
