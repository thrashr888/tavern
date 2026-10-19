import XCTest
@testable import TavernCore

/// A scripted Gmail API: label "Party" = L1, messages by id, history pages by start id.
final class FakeGmail: GmailHTTP, @unchecked Sendable {
    var profileHistory = "100"
    var labelIDs: [String] = []
    var messages: [String: JSONValue] = [:]
    var history: [String: (added: [String], historyID: String)] = [:]
    var expired: Set<String> = []
    var requests: [String] = []

    func get(_ path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        requests.append(path)
        let reply: JSONValue
        switch path {
        case "labels":
            reply = ["labels": .array([["id": "L1", "name": "Party"], ["id": "INBOX", "name": "INBOX"]])]
        case "profile":
            reply = ["historyId": .string(profileHistory)]
        case "messages":
            reply = ["messages": .array(labelIDs.map { JSONValue.object(["id": .string($0)]) })]
        case "history":
            let start = query.first { $0.name == "startHistoryId" }?.value ?? ""
            if expired.contains(start) { return (Data(), 404) }
            let page = history[start] ?? (added: [], historyID: start)
            reply = [
                "historyId": .string(page.historyID),
                "history": .array([["messagesAdded": .array(page.added.map { JSONValue.object(["message": ["id": .string($0)]]) })]]),
            ]
        default:
            let id = String(path.dropFirst("messages/".count))
            guard let message = messages[id] else { return (Data(), 404) }
            reply = message
        }
        return (try reply.encoded(), 200)
    }

    static func message(_ id: String, thread: String, subject: String, from: String = "Sam Rivera <sam@example.com>",
                        body: String, millis: String = "1760500000000") -> JSONValue {
        let data = Data(body.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return [
            "id": .string(id), "threadId": .string(thread), "historyId": "90", "internalDate": .string(millis),
            "snippet": .string(String(body.prefix(40)) + " &amp; more"),
            "payload": [
                "mimeType": "multipart/alternative",
                "headers": .array([
                    ["name": "Subject", "value": .string(subject)],
                    ["name": "From", "value": .string(from)],
                ]),
                "parts": .array([
                    ["mimeType": "text/plain", "body": ["data": .string(data)]],
                    ["mimeType": "text/html", "body": ["data": "PGI-aGk8L2I-"]],
                ]),
            ],
        ]
    }
}

@MainActor
final class GmailSyncTests: XCTestCase {
    func testFirstSyncReadsLabelAndStoresCursorBeforeListing() async throws {
        let store = try EventStore(path: ":memory:")
        let gmail = FakeGmail()
        gmail.labelIDs = ["m1", "m2"]
        gmail.messages["m1"] = FakeGmail.message("m1", thread: "t1", subject: "The Guild: Tavern - M1", body: "Plan is up.\n\nQuill")
        gmail.messages["m2"] = FakeGmail.message("m2", thread: "t1", subject: "Re: The Guild: Tavern - M1",
                                                 from: "Rook <rook@mail.instinct.example>", body: "Looks good.\n\nOn Wed, Sam wrote:\n> Plan is up.", millis: "1760500100000")
        let sync = GmailSync(api: GmailAPI(http: gmail), store: store, roster: .fixture)

        let firstCount = try await sync.sync()
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(try store.cursor(for: "gmail"), "100")
        // Profile is read before the label listing, so mail arriving mid-read is caught next time.
        XCTAssertLessThan(gmail.requests.firstIndex(of: "profile")!, gmail.requests.firstIndex(of: "messages")!)

        let threads = MailThread.threads(from: try store.events(source: EventSource.gmail))
        XCTAssertEqual(threads.count, 1)
        let thread = threads[0]
        XCTAssertEqual(thread.subject, "The Guild: Tavern - M1")
        XCTAssertEqual(thread.project, "tavern")
        XCTAssertEqual(thread.authors, ["quill", "rook"])
        XCTAssertEqual(thread.messages[1].body, "Looks good.")
        XCTAssertTrue(thread.messages[0].snippet.hasSuffix("& more"))
        XCTAssertEqual(try store.events(threadKey: "gmail-thread:t1").count, 2)
    }

    func testIncrementalSyncUsesHistoryAndSkipsDeletedMail() async throws {
        let store = try EventStore(path: ":memory:")
        let gmail = FakeGmail()
        gmail.labelIDs = ["m1"]
        gmail.messages["m1"] = FakeGmail.message("m1", thread: "t1", subject: "The Guild: Alchemy", body: "Hi")
        let sync = GmailSync(api: GmailAPI(http: gmail), store: store, roster: .fixture)
        try await sync.sync()

        gmail.messages["m3"] = FakeGmail.message("m3", thread: "t2", subject: "The Guild: Party night", body: "Hey\n— Wren")
        gmail.history["100"] = (["m1", "m3", "gone"], "120")
        let added = try await sync.sync()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(try store.cursor(for: "gmail"), "120")
        let party = MailThread.threads(from: try store.events(source: EventSource.gmail), project: "party")
        XCTAssertEqual(party.map(\.threadID), ["t2"])
        XCTAssertEqual(party.first?.authors, ["wren"])
    }

    func testExpiredHistoryFallsBackToFullReadWithoutDuplicates() async throws {
        let store = try EventStore(path: ":memory:")
        let gmail = FakeGmail()
        gmail.labelIDs = ["m1"]
        gmail.messages["m1"] = FakeGmail.message("m1", thread: "t1", subject: "Hello", body: "Hi")
        let sync = GmailSync(api: GmailAPI(http: gmail), store: store, roster: .fixture)
        try await sync.sync()

        gmail.expired = ["100"]
        gmail.profileHistory = "500"
        gmail.labelIDs = ["m1", "m2"]
        gmail.messages["m2"] = FakeGmail.message("m2", thread: "t1", subject: "Re: Hello", body: "Again")
        let resynced = try await sync.sync()
        XCTAssertEqual(resynced, 1)
        XCTAssertEqual(try store.eventCount(source: EventSource.gmail), 2)
        XCTAssertEqual(try store.cursor(for: "gmail"), "500")
    }

    func testMissingLabelIsReported() async throws {
        let store = try EventStore(path: ":memory:")
        let sync = GmailSync(api: GmailAPI(http: FakeGmail()), store: store, roster: .fixture, labelName: "Nope")
        do {
            try await sync.sync()
            XCTFail("expected labelNotFound")
        } catch {
            XCTAssertEqual(error as? GmailError, .labelNotFound("Nope"))
        }
    }

    func testFeedListsStoredThreadsAndFiltersByProject() async throws {
        let store = try EventStore(path: ":memory:")
        let gmail = FakeGmail()
        gmail.labelIDs = ["a", "b"]
        gmail.messages["a"] = FakeGmail.message("a", thread: "ta", subject: "The Guild: Tavern", body: "x", millis: "1760500000000")
        gmail.messages["b"] = FakeGmail.message("b", thread: "tb", subject: "The Guild: Habitable", body: "y", millis: "1760600000000")
        let feed = MailFeed(store: store, oauth: nil, signedIn: true) {
            GmailSync(api: GmailAPI(http: gmail), store: store, roster: .fixture)
        }
        XCTAssertEqual(feed.state, .notConfigured)
        await feed.refresh()
        XCTAssertEqual(feed.state, .ready)
        XCTAssertEqual(feed.threads.map(\.threadID), ["tb", "ta"])
        XCTAssertEqual(feed.threads(project: "tavern").map(\.threadID), ["ta"])
    }
}

final class GmailParsingTests: XCTestCase {
    func testProjectDetectionMatchesWholeWordsEarliestFirst() {
        let projects = Roster.fixture.mailProjects
        XCTAssertEqual(MailItem.detectProject(subject: "Re: The Guild: Tavern - Alchemy notes", projects: projects), "tavern")
        XCTAssertNil(MailItem.detectProject(subject: "Partying", projects: projects))
        XCTAssertNil(MailItem.detectProject(subject: "Lunch", projects: projects))
    }

    func testCleanSubjectDropsReplyPrefixes() {
        XCTAssertEqual(MailThread.cleanSubject("RE: Fwd: re: Plan"), "Plan")
        XCTAssertEqual(MailThread.cleanSubject("  "), "(no subject)")
    }

    func testOAuthClientFileAndPKCE() throws {
        let client = try GmailOAuth.Client.parse(Data("""
        {"installed":{"client_id":"abc.apps.googleusercontent.com","client_secret":"s","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}
        """.utf8))
        XCTAssertEqual(client.clientID, "abc.apps.googleusercontent.com")
        XCTAssertEqual(client.tokenURI.absoluteString, "https://oauth2.googleapis.com/token")
        // RFC 7636 appendix B test vector.
        XCTAssertEqual(GmailOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(GmailOAuth.formEncode(["b": "x y", "a": "1/2"]), "a=1%2F2&b=x%20y")
    }

    func testLoopbackRequestParsing() {
        XCTAssertEqual(LoopbackReceiver.query(fromRequest: "GET /?code=4%2Fabc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
                       ["code": "4/abc", "state": "xyz"])
        XCTAssertNil(LoopbackReceiver.query(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n"))
        XCTAssertNil(LoopbackReceiver.query(fromRequest: "POST /?code=1 HTTP/1.1\r\n\r\n"))
    }
}
