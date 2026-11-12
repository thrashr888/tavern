import Combine
import XCTest
@testable import TavernCore

final class LivePinnedCardTests: XCTestCase {
    func testNewerRevisionReplacesWholeWidgetWithoutChangingSnapshot() throws {
        let first = widget(revision: 1, status: "doing")
        let latest = widget(revision: 3, status: "done", title: "Renamed plan")
        let live = try XCTUnwrap(PinnedCard(following: first, agentID: "ember", rowID: "card:first"))
        let snapshot = PinnedCard(agentID: "ember", rowID: "card:first")
        let rows: [PiThreadRow] = [.card(id: "first", first), .card(id: "third", latest),
                                   .card(id: "late-second", widget(revision: 2))]
        XCTAssertEqual(live.resolve(in: rows, agentID: "ember"), latest)
        XCTAssertEqual(snapshot.resolve(in: rows, agentID: "ember"), first)
        XCTAssertNotEqual(live.id, snapshot.id)
    }

    func testSameTitleAndSameTypeDoNotEstablishIdentity() throws {
        let one = widget(id: "plan:one")
        let two = widget(id: "plan:two", revision: 99)
        let pin = try XCTUnwrap(PinnedCard(following: one, agentID: "ember", rowID: "card:one"))
        XCTAssertEqual(pin.resolve(in: [.card(id: "one", one), .card(id: "two", two)], agentID: "ember"), one)
        XCTAssertNil(pin.resolve(in: [.card(id: "two", two)], agentID: "ember"))
        XCTAssertNotEqual(pin.id, PinnedCard(following: two, agentID: "ember", rowID: "card:two")?.id)
        var unidentified = one
        unidentified.structuredContent = ["kind": "checklist", "checklist": ["title": "Plan"]]
        XCTAssertNil(PinnedCard(following: unidentified, agentID: "ember", rowID: "card:old"))
    }

    func testLivePinsRequireMatchingAgentServerResourceAndIdentity() throws {
        let first = widget()
        let pin = try XCTUnwrap(PinnedCard(following: first, agentID: "ember", rowID: "card:one"))
        let rows: [PiThreadRow] = [.card(id: "one", first)]
        XCTAssertNil(pin.resolve(in: rows, agentID: "tally"))
        XCTAssertNotEqual(pin.id, PinnedCard(following: first, agentID: "tally", rowID: "card:one")?.id)
        var otherServer = widget(revision: 2)
        otherServer.server = "other"
        let chart = widget(revision: 3, kind: "chart")
        XCTAssertNil(pin.resolve(in: [.card(id: "other", otherServer), .card(id: "chart", chart)], agentID: "ember"))
        XCTAssertNotEqual(pin.id, PinnedCard(following: chart, agentID: "ember", rowID: "card:chart")?.id)
        XCTAssertNil(PinnedCard(agentID: "ember", rowID: "card:one").resolve(in: rows, agentID: "tally"))
    }

    func testMissingOriginalCanFollowExplicitReplacementButNotOlderRevision() throws {
        let pin = try XCTUnwrap(PinnedCard(following: widget(revision: 2), agentID: "ember", rowID: "card:missing"))
        XCTAssertEqual(pin.resolution(in: [], agentID: "ember"), .missingSource)
        XCTAssertNil(pin.resolve(in: [.card(id: "older", widget(revision: 1))], agentID: "ember"))
        let latest = widget(revision: 4)
        XCTAssertEqual(pin.resolve(in: [.card(id: "replacement", latest)], agentID: "ember"), latest)
    }

    func testConflictingRevisionFailsClosedAndNewerRevisionRecovers() throws {
        let first = widget()
        let pin = try XCTUnwrap(PinnedCard(following: first, agentID: "ember", rowID: "card:one"))
        let conflicting: [PiThreadRow] = [.card(id: "one", first), .card(id: "two", widget(revision: 2, status: "done")),
                                         .card(id: "duplicate-two", widget(revision: 2, status: "blocked"))]
        XCTAssertEqual(pin.resolution(in: conflicting, agentID: "ember"), .conflictingRevision(2))
        XCTAssertNil(pin.resolve(in: conflicting.reversed(), agentID: "ember"))
        let latest = widget(revision: 3)
        XCTAssertEqual(pin.resolve(in: conflicting + [.card(id: "three", latest)], agentID: "ember"), latest)
    }

    func testIdenticalReplayIsHarmlessAndLivePinIdentitySurvivesNewRows() throws {
        let first = widget()
        let second = widget(revision: 2)
        let pin = try XCTUnwrap(PinnedCard(following: first, agentID: "ember", rowID: "card:one"))
        let laterPin = try XCTUnwrap(PinnedCard(following: second, agentID: "ember", rowID: "card:two"))
        XCTAssertEqual(pin.id, laterPin.id, "Unpin from any revision must target the same saved live pin")
        XCTAssertEqual(pin.resolve(in: [.card(id: "two", second), .card(id: "replay", second)], agentID: "ember"), second)
    }

    func testBackgroundUpdatesCanReplaceAVisibleWidget() throws {
        let first = widget()
        let pin = try XCTUnwrap(PinnedCard(following: first, agentID: "ember", rowID: "card:one"))
        let trigger = TranscriptItem(id: "heartbeat", role: .user, text: "[Heartbeat today]", date: Date())
        var item = TranscriptItem(id: "result", role: .tool, text: "Ran checklist", date: Date())
        item.card = widget(revision: 2)
        let run = BackgroundRun(id: "heartbeat", date: Date(), trigger: trigger, items: [item])
        let rows: [PiThreadRow] = [.card(id: "one", first), .background(run)]
        XCTAssertEqual(pin.resolve(in: rows, agentID: "ember"), item.card)
        XCTAssertEqual(PinnedCard(agentID: "ember", rowID: "card:result").resolve(in: rows, agentID: "ember"), item.card)
    }

    func testOldJSONLoadsAsSnapshotAndMixedPinsRoundTripWithoutConversion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pins.json")
        try Data(#"[{"agentID":"ember","rowID":"card:one"}]"#.utf8).write(to: url)
        let snapshot = try XCTUnwrap(PinnedCardFile.load(from: url).first)
        XCTAssertNil(snapshot.live)
        let live = try XCTUnwrap(PinnedCard(following: widget(), agentID: "ember", rowID: "card:one"))
        let newerPin = try XCTUnwrap(PinnedCard(following: widget(revision: 2), agentID: "ember", rowID: "card:two"))
        try PinnedCardFile.save([snapshot, live, newerPin], to: url)
        XCTAssertEqual(try PinnedCardFile.load(from: url), [snapshot, live])
        try PinnedCardFile.save([snapshot], to: url)
        XCTAssertEqual(try PinnedCardFile.load(from: url), [snapshot], "Unpin live leaves the snapshot intact")
    }

    func testIdentityAndRevisionValidationIsExactAndRejectsMalformedValues() {
        for id in ["", " leading", "trailing ", "line\n", "bad/id", "ümlaut", "-start", String(repeating: "a", count: 129)] {
            XCTAssertNil(widget(id: id).widgetRevision, id)
        }
        for revision: JSONValue in [.null, true, "2", .number(0), .number(-1), .number(1.5), .number(.infinity), .number(.nan), .number(9_007_199_254_740_992)] {
            var card = widget()
            card.structuredContent = ["kind": "checklist", "widget": ["id": "plan", "revision": revision]]
            XCTAssertNil(card.widgetRevision)
        }
        for id in ["A", "release:plan_1.2-3", String(repeating: "a", count: 128)] {
            XCTAssertEqual(widget(id: id).widgetRevision?.id, id)
        }
        XCTAssertEqual(widget(revision: 9_007_199_254_740_991).widgetRevision?.revision, 9_007_199_254_740_991)
    }

    func testOnlySupportedSuccessfulCardsCanOptIn() {
        for kind in ["chart", "checklist", "timeline", "calendar", "compose"] {
            XCTAssertNotNil(widget(kind: kind).widgetRevision)
        }
        XCTAssertNil(widget(kind: "mail").widgetRevision)
        var card = widget()
        card.resourceUri = "ui://cards/chart"
        XCTAssertNil(card.widgetRevision)
        card = widget()
        card.structuredContent = ["ok": false, "kind": "checklist", "widget": ["id": "plan", "revision": .number(1)]]
        XCTAssertNil(card.widgetRevision)
        card.structuredContent = ["kind": "checklist", "widget": ["id": "plan"]]
        XCTAssertNil(card.widgetRevision)
    }

    @MainActor
    func testSessionSyncPersistenceRelaunchAndMissingAgentDoNotRunTools() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("events.sqlite").path
        let pinURL = dir.appendingPathComponent("pins.json")
        let transport = WidgetFixturePi(entries: [entry(id: "one", revision: 1)])
        let session = PiAgentSession(agentID: "ember", store: try EventStore(path: path)) { transport }
        await session.connect()
        let pin = try XCTUnwrap(PinnedCard(following: widget(), agentID: "ember", rowID: "card:fixture:one"))
        let snapshot = PinnedCard(agentID: "ember", rowID: "card:fixture:one")
        try PinnedCardFile.save([pin, snapshot], to: pinURL)
        XCTAssertEqual(pin.resolve(in: session.rows, agentID: "ember")?.widgetRevision?.revision, 1)
        var changes = 0
        let observer = session.objectWillChange.sink { changes += 1 }
        transport.entries = [entry(id: "two", revision: 2)]
        try await session.sync()
        XCTAssertGreaterThan(changes, 0, "Observed sidebar refreshes when transcript updates")
        XCTAssertEqual(pin.resolve(in: session.rows, agentID: "ember")?.widgetRevision?.revision, 2)
        XCTAssertEqual(snapshot.resolve(in: session.rows, agentID: "ember")?.widgetRevision?.revision, 1)
        observer.cancel()
        await session.disconnect()
        let restoredPins = try PinnedCardFile.load(from: pinURL)
        let offline = PiAgentSession(agentID: "ember", store: try EventStore(path: path)) { transport }
        XCTAssertEqual(offline.presence, .disconnected)
        XCTAssertEqual(restoredPins.first?.resolve(in: offline.rows, agentID: "ember")?.widgetRevision?.revision, 2)
        let other = PiAgentSession(agentID: "tally", store: try EventStore(path: path)) { transport }
        XCTAssertNil(restoredPins.first?.resolve(in: other.rows, agentID: "tally"))
        XCTAssertEqual(try PinnedCardFile.load(from: pinURL), restoredPins, "Missing source does not discard saved pins")
        XCTAssertTrue(transport.commands.allSatisfy { ["get_state", "get_entries"].contains($0) }, "Resolving pins never calls a tool")
    }

    private func widget(id: String = "release:plan", revision: Int = 1, status: String = "doing",
                        title: String = "Plan", kind: String = "checklist") -> ToolCard {
        ToolCard(server: "cards", resourceUri: "ui://cards/\(kind)", toolName: "cards__\(kind)",
                 structuredContent: ["ok": true, "kind": .string(kind),
                                     "widget": ["id": .string(id), "revision": .number(Double(revision))],
                                     kind: ["title": .string(title), "items": .array([["text": "Test", "status": .string(status)]])]])
    }

    private func entry(id: String, revision: Int) -> JSONValue {
        ["type": "message", "id": .string(id), "timestamp": .string("2026-11-10T10:00:0\(revision)Z"),
         "message": ["role": "toolResult", "toolName": "cards__checklist", "toolCallId": .string(id), "content": .array([]),
                     "details": ["ui": ["server": "cards", "resourceUri": "ui://cards/checklist",
                                          "structuredContent": widget(revision: revision).structuredContent]]]]
    }
}

private final class WidgetFixturePi: PiTransport, @unchecked Sendable {
    var entries: [JSONValue]
    private(set) var commands: [String] = []
    private var receive: (@Sendable (Data) -> Void)?
    init(entries: [JSONValue]) { self.entries = entries }
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        receive = onLine
    }
    func send(_ line: Data) throws {
        let request = try JSONValue.decode(line)
        let type = request["type"]?.stringValue ?? ""
        commands.append(type)
        let data: JSONValue = type == "get_state" ? ["sessionId": "fixture", "isStreaming": false] : ["entries": .array(entries)]
        let reply: JSONValue = ["type": "response", "id": request["id"] ?? .null, "command": .string(type), "success": true, "data": data]
        receive?(try reply.encoded())
    }
    func close() {}
}
