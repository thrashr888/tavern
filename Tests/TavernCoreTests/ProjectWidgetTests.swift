import XCTest
@testable import TavernCore

final class ProjectWidgetTests: XCTestCase {
    private func request(_ prompt: String, agent: String = "ember") -> ProjectChatMessage {
        ProjectChatMessage(id: "r:\(prompt)", chatID: "project-one", author: nil, recipient: agent,
                           text: "Question", date: Date(), state: .waiting, prompt: prompt)
    }
    private func item(_ id: String, _ role: TranscriptItem.Role, _ text: String = "", card: Bool = false) -> TranscriptItem {
        var item = TranscriptItem(id: id, role: role, text: text, date: Date())
        if card { item.card = ToolCard(server: "cards", resourceUri: "ui://cards/checklist", toolName: "checklist") }
        return item
    }
    func testCardsAreScopedToExactRequestAndAgent() {
        let rows = ProjectChatStore.cardRows(for: [request("exact prompt")], agentID: "ember", transcript: [
            item("u0", .user, "private question"), item("private", .tool, card: true),
            item("u1", .user, "exact prompt"), item("one", .tool, card: true),
            item("u2", .user, "another project"), item("other", .tool, card: true)
        ])
        XCTAssertEqual(rows.map(\.id), ["card:one"])
        XCTAssertTrue(ProjectChatStore.cardRows(for: [request("exact prompt")], agentID: "tally",
                       transcript: [item("u", .user, "exact prompt"), item("one", .tool, card: true)]).isEmpty)
    }
    func testSystemBoundaryAndFailedToolNeverLeakCards() {
        var failed = item("failed", .tool, card: true); failed.failed = true
        let rows = ProjectChatStore.cardRows(for: [request("p")], agentID: "ember", transcript: [
            item("u", .user, "p"), failed, item("ok", .tool, card: true),
            item("system", .system, "background"), item("background", .tool, card: true)
        ])
        XCTAssertEqual(rows.map(\.id), ["card:ok"])
    }
    func testRepeatedCardsDeduplicateAndMultipleProjectRequestsAreIncluded() {
        let rows = ProjectChatStore.cardRows(for: [request("one"), request("two")], agentID: "ember", transcript: [
            item("u", .user, "one"), item("a", .tool, card: true), item("a", .tool, card: true),
            item("v", .user, "two"), item("b", .tool, card: true)
        ])
        XCTAssertEqual(rows.map(\.id), ["card:a", "card:b"])
    }
    func testCardArgumentsComeOnlyFromScopedToolCalls() throws {
        var call = item("assistant", .assistant)
        call.toolCalls = [PiToolCall(id: "call", name: "checklist", arguments: ["title": "Project plan"])]
        var card = item("card", .tool, card: true); card.toolCallID = "call"
        let rows = ProjectChatStore.cardRows(for: [request("p")], agentID: "ember", transcript: [
            item("u", .user, "p"), call, card
        ])
        guard case .card(_, let resolved) = try XCTUnwrap(rows.first) else { return XCTFail("Missing card") }
        XCTAssertEqual(resolved.arguments, ["title": "Project plan"])
        let outside = ProjectChatStore.cardRows(for: [request("p")], agentID: "ember", transcript: [
            call, item("u", .user, "p"), card
        ])
        guard case .card(_, let unrelated) = try XCTUnwrap(outside.first) else { return XCTFail("Missing card") }
        XCTAssertEqual(unrelated.arguments, .object([:]))
    }

    func testProjectPinNamespacesAndLegacyPersistence() throws {
        let agentPin = PinnedCard(agentID: "ember", rowID: "card:a")
        let one = PinnedCard(agentID: "ember", rowID: "card:a", projectID: "one")
        let two = PinnedCard(agentID: "ember", rowID: "card:a", projectID: "two")
        XCTAssertEqual(Set([agentPin.id, one.id, two.id]).count, 3)
        let old = try JSONDecoder().decode(PinnedCard.self, from: Data(#"{"agentID":"ember","rowID":"card:a"}"#.utf8))
        XCTAssertEqual(old, agentPin)
        XCTAssertEqual(try JSONDecoder().decode(PinnedCard.self, from: JSONEncoder().encode(one)), one)
    }
}
