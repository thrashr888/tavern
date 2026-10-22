import XCTest
@testable import TavernCore

final class PageTests: XCTestCase {
    func testStorageKeysRoundTrip() {
        let pages: [Page] = [.dashboard, .settings, .goals, .agent(id: "tally"), .mail(project: nil), .mail(project: "tavern"),
                             .spellbook(spell: nil), .spellbook(spell: "SB-20")]
        for page in pages {
            XCTAssertEqual(Page(storageKey: page.storageKey), page)
        }
    }

    func testFirstLaunchOpensDashboard() {
        XCTAssertEqual(Page.restore(nil, roster: .fixture), .dashboard)
    }

    func testRestoresLastPage() {
        XCTAssertEqual(Page.restore("agent:tally", roster: .fixture), .agent(id: "tally"))
        XCTAssertEqual(Page.restore("mail:alchemy", roster: .fixture), .mail(project: "alchemy"))
        XCTAssertEqual(Page.restore("mail:all", roster: .fixture), .mail(project: nil))
    }

    func testUnknownOrStalePagesFallBackToDashboard() {
        XCTAssertEqual(Page.restore("garbage", roster: .fixture), .dashboard)
        XCTAssertEqual(Page.restore("agent:gone", roster: .fixture), .dashboard)
        // Hosted agents have no thread page.
        XCTAssertEqual(Page.restore("agent:rook", roster: .fixture), .dashboard)
        XCTAssertEqual(Page.restore("mail:gone", roster: .fixture), .dashboard)
    }

    func testRosterIDsAreUnique() {
        let ids = Roster.fixture.members.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testMissingRosterFileUsesFallback() {
        let url = URL(fileURLWithPath: "/nonexistent/roster.json")
        XCTAssertEqual(Roster.load(from: url), .fallback)
    }
}

final class RosterExampleTests: XCTestCase {
    func testExampleRosterDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/roster.example.json")
        let roster = try JSONDecoder().decode(Roster.self, from: Data(contentsOf: url))
        XCTAssertEqual(roster.members.count, 4)
        XCTAssertEqual(roster.owner(ofProject: "Infra")?.id, "forge")
        XCTAssertEqual(roster.mailLabelName, "Guild")
    }
}
