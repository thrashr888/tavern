import XCTest
@testable import TavernCore

final class MailParsingTests: XCTestCase {
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

    func testPKCEAndFormEncoding() {
        // RFC 7636 appendix B test vector.
        XCTAssertEqual(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(OAuthPKCE.formEncode(["b": "x y", "a": "1/2"]), "a=1%2F2&b=x%20y")
    }

    func testLoopbackRequestParsing() {
        XCTAssertEqual(LoopbackReceiver.query(fromRequest: "GET /?code=4%2Fabc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
                       ["code": "4/abc", "state": "xyz"])
        XCTAssertNil(LoopbackReceiver.query(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n"))
        XCTAssertNil(LoopbackReceiver.query(fromRequest: "POST /?code=1 HTTP/1.1\r\n\r\n"))
    }
}
