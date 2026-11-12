import XCTest
@testable import TavernCore

@MainActor
final class MessageDraftTests: XCTestCase {
    func testDraftsSurviveStoreRecreationAndRemainInputScoped() {
        let name = "draft-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MessageDraftStore(defaults: defaults)
        store.set("home", for: "project:home:composer")
        store.set("agent", for: "agent:tally:composer")
        let reopened = MessageDraftStore(defaults: defaults)
        XCTAssertEqual(reopened.text(for: "project:home:composer"), "home")
        XCTAssertEqual(reopened.text(for: "agent:tally:composer"), "agent")
        reopened.clear("project:home:composer", ifMatching: "old")
        XCTAssertEqual(reopened.text(for: "project:home:composer"), "home")
        reopened.clear("project:home:composer", ifMatching: "home")
        XCTAssertEqual(MessageDraftStore(defaults: defaults).text(for: "project:home:composer"), "")
        XCTAssertEqual(reopened.text(for: "agent:tally:composer"), "agent")
    }
}
