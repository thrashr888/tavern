import XCTest
import TavernCore
@testable import TavernApp

/// Isolated transport faults exercise the real app dispatcher and Pi session together.
/// These fixtures never connect to a live agent or use the user's data store.
@MainActor
final class ProjectChatReliabilityTests: XCTestCase {
    private func fixture(path: String = ":memory:") throws -> (EventStore, ReliabilityParty, ProjectChatsModel, ProjectChat) {
        let events = try EventStore(path: path)
        let party = ReliabilityParty(events: events)
        let model = ProjectChatsModel(store: events, model: party)
        let id = try XCTUnwrap(model.create(title: "Isolated reliability test", participants: ["a", "b", "c"], lead: "a"))
        return (events, party, model, try XCTUnwrap(model.chats.first { $0.id == id }))
    }

    func testDisconnectedAgentQueuesWithoutBlockingHealthyParticipant() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect(["b", "c"])
        assertTrue(await model.sendAll(chat: chat, text: "offline-first"))
        try await eventually { party.hosts["b"]!.prompts.count == 1 && party.hosts["c"]!.prompts.count == 1 }
        XCTAssertEqual(party.hosts["a"]!.prompts.count, 0)
        XCTAssertEqual(model.messages.first { $0.recipient == "a" }?.state, .queued)
        await party.connect(["a"])
        try await eventually { party.hosts["a"]!.prompts.count == 1 }
        for host in party.hosts.values { host.complete("done") }
        try await eventually { model.messages.filter { $0.recipient != nil }.allSatisfy { $0.state == .replied } }
        await party.disconnect()
    }

    func testLostAcknowledgementReconcilesWithoutResendingAndDrainsSuccessor() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        party.hosts["a"]!.loseAcknowledgement = true
        assertTrue(await model.send(chat: chat, recipient: "a", text: "accepted-but-ack-lost"))
        try await eventually { party.hosts["a"]!.prompts.count == 1 }
        assertTrue(await model.send(chat: chat, recipient: "a", text: "successor"))
        try await eventually { model.messages.contains { $0.recipient == "a" && $0.state == .uncertain } }
        party.hosts["a"]!.complete("first reply", notify: false)
        await party.sessions["a"]!.reconnectNow()
        try await eventually { party.hosts["a"]!.prompts.count == 2 }
        XCTAssertEqual(party.hosts["a"]!.prompts.filter { $0.contains("--- Current human message ---\naccepted-but-ack-lost") }.count, 1)
        party.hosts["a"]!.complete("second reply")
        try await eventually { model.messages.filter { $0.recipient == "a" }.allSatisfy { $0.state == .replied } }
        await party.disconnect()
    }

    func testHostRestartRetainsUnknownAttemptAndDoesNotReplayIt() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        assertTrue(await model.send(chat: chat, recipient: "a", text: "old-host-turn"))
        try await eventually { party.hosts["a"]!.prompts.count == 1 }
        assertTrue(await model.send(chat: chat, recipient: "a", text: "waiting-successor"))
        party.hosts["a"]!.restartWithoutHistory()
        await party.sessions["a"]!.reconnectNow()
        try await eventually { party.sessions["a"]!.presence == .idle }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(party.hosts["a"]!.prompts.count, 1)
        XCTAssertEqual(model.messages.filter { $0.state == .queued }.count, 1)
        XCTAssertTrue(model.messages.contains { $0.text == "old-host-turn" && [.waiting, .uncertain].contains($0.state) })
        await party.disconnect()
    }

    func testPermissionDenialClosesFailedTurnAndReleasesQueue() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        assertTrue(await model.send(chat: chat, recipient: "a", text: "request-denied-tool"))
        try await eventually { party.hosts["a"]!.prompts.count == 1 }
        party.hosts["a"]!.approval()
        try await eventually { party.sessions["a"]!.dialog != nil }
        assertTrue(await model.send(chat: chat, recipient: "a", text: "after-denial"))
        await party.sessions["a"]!.answer(.confirmed(false))
        try await eventually { party.hosts["a"]!.prompts.count == 2 }
        XCTAssertEqual(party.hosts["a"]!.approvalAnswers, [false])
        XCTAssertTrue(model.messages.contains { $0.text == "request-denied-tool" && $0.state == .closed && $0.failureReason != nil })
        party.hosts["a"]!.complete("next completed")
        try await eventually { model.messages.contains { $0.text == "after-denial" && $0.state == .replied } }
        await party.disconnect()
    }

    func testExplicitPromptRejectionDoesNotRemainUncertainOrBlockQueue() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        party.hosts["a"]!.rejectNextPrompt = true
        assertTrue(await model.send(chat: chat, recipient: "a", text: "explicitly-rejected"))
        assertTrue(await model.send(chat: chat, recipient: "a", text: "after-rejection"))
        try await eventually { party.hosts["a"]!.promptAttempts == 2 }
        XCTAssertTrue(model.messages.contains { $0.text == "explicitly-rejected" && $0.state == .closed && $0.failureReason != nil && $0.prompt == nil })
        XCTAssertEqual(party.hosts["a"]!.prompts.count, 1)
        XCTAssertFalse(party.hosts["a"]!.prompts[0].contains("explicitly-rejected"))
        party.hosts["a"]!.complete("after rejection")
        try await eventually { model.messages.contains { $0.text == "after-rejection" && $0.state == .replied } }
        await party.disconnect()
    }

    func testFourHandoffBudgetIsDurableAndFifthNeverDispatches() async throws {
        let (_, party, model, original) = try fixture()
        model.setCoordination(original, true)
        let chat = try XCTUnwrap(model.chats.first { $0.id == original.id })
        await party.connect()
        assertTrue(await model.send(chat: chat, recipient: "a", text: "handoff-root"))
        let chain = ["a", "b", "c", "a", "b"]
        for (index, actor) in chain.enumerated() {
            try await eventually { party.hosts.values.reduce(0) { $0 + $1.prompts.count } == index + 1 }
            party.hosts[actor]!.complete("@ask \(index == 4 ? "c" : chain[index + 1]): hop \(index + 1)")
        }
        try await eventually { model.error?.contains("Handoff limit reached") == true }
        XCTAssertEqual(party.hosts.values.reduce(0) { $0 + $1.prompts.count }, 5)
        XCTAssertEqual(model.messages.filter { $0.parentMessageID != nil && $0.recipient != nil }.count, 4)
        for session in party.sessions.values { try await session.sync() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(party.hosts.values.reduce(0) { $0 + $1.prompts.count }, 5)
        await party.disconnect()
    }

    func testHostedParticipantIsRejectedWithoutAnyInvocation() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        assertFalse(await model.send(chat: chat, recipient: "hosted", text: "unsupported"))
        XCTAssertNil(model.create(title: "Hosted route", participants: ["a", "hosted"], lead: "a"))
        XCTAssertEqual(party.hosts.values.reduce(0) { $0 + $1.prompts.count }, 0)
        await party.disconnect()
    }

    func testRestartReopensDurableQueueWithoutReplayOrNewHistoricalHandoffs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("events.sqlite").path
        let events = try EventStore(path: path)
        let firstParty = ReliabilityParty(events: events)
        var firstModel: ProjectChatsModel? = ProjectChatsModel(store: events, model: firstParty)
        let id = try XCTUnwrap(firstModel!.create(title: "Restart", participants: ["a", "b", "c"], lead: "a"))
        firstModel!.setCoordination(try XCTUnwrap(firstModel!.chats.first { $0.id == id }), true)
        let chat = try XCTUnwrap(firstModel!.chats.first { $0.id == id })
        await firstParty.connect()
        assertTrue(await firstModel!.send(chat: chat, recipient: "a", text: "before-restart"))
        try await eventually { firstModel!.messages.contains { $0.text == "before-restart" && $0.state == .waiting } }
        assertTrue(await firstModel!.send(chat: chat, recipient: "a", text: "queued-successor"))
        await firstParty.disconnect()
        firstModel = nil
        firstParty.hosts["a"]!.complete("@ask b: old historical handoff must not run", notify: false)

        let reopened = try EventStore(path: path)
        let secondParty = ReliabilityParty(events: reopened, existingHosts: firstParty.hosts)
        let secondModel = ProjectChatsModel(store: reopened, model: secondParty)
        await secondParty.connect()
        try await eventually { secondParty.hosts["a"]!.prompts.count == 2 }
        XCTAssertEqual(secondParty.hosts["b"]!.prompts.count, 0)
        XCTAssertEqual(secondModel.messages.filter { $0.text == "before-restart" && $0.state == .replied }.count, 1)
        secondParty.hosts["a"]!.complete("successor after restart")
        try await eventually { secondModel.messages.filter { $0.recipient != nil }.allSatisfy { $0.state == .replied } }
        for session in secondParty.sessions.values { try await session.sync() }
        XCTAssertEqual(secondParty.hosts["a"]!.prompts.count, 2)
        XCTAssertEqual(secondModel.messages.filter { $0.author != nil && $0.recipient == nil }.count, 2)
        await secondParty.disconnect()
    }

    func testSustainedThreeAgentQueuesSurviveRepeatedDisconnectsWithoutDuplicates() async throws {
        let (_, party, model, chat) = try fixture()
        await party.connect()
        let soak = ProcessInfo.processInfo.environment["TAVERN_RELIABILITY_SOAK"] == "1"
        let rounds = soak ? 60 : 40
        for round in 0..<rounds { assertTrue(await model.sendAll(chat: chat, text: "stress-round-\(round)")) }
        for round in 0..<rounds {
            if soak { try await Task.sleep(for: .seconds(5)) }
            try await eventually { party.hosts.values.allSatisfy { $0.prompts.count == round + 1 } }
            if round % 10 == 0 {
                await party.sessions["a"]!.disconnect()
                party.hosts["a"]!.complete("a-\(round)", notify: false)
                await party.sessions["a"]!.connect()
            } else { party.hosts["a"]!.complete("a-\(round)") }
            party.hosts["b"]!.complete("b-\(round)")
            party.hosts["c"]!.complete("c-\(round)")
        }
        try await eventually { model.messages.filter { $0.recipient != nil }.allSatisfy { $0.state == .replied } }
        for host in party.hosts.values {
            XCTAssertEqual(host.prompts.count, rounds)
            XCTAssertEqual(Set(host.prompts).count, rounds)
            for (index, prompt) in host.prompts.enumerated() {
                XCTAssertTrue(prompt.hasSuffix("--- Current human message ---\nstress-round-\(index)"))
            }
        }
        XCTAssertEqual(model.messages.filter { $0.recipient != nil }.count, rounds * 3)
        XCTAssertEqual(model.messages.filter { $0.author != nil && $0.recipient == nil }.count, rounds * 3)
        await party.disconnect()
    }

    private func assertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for dispatcher state", file: file, line: line)
    }
}

@MainActor
private final class ReliabilityParty: ProjectChatSessionProvider {
    let roster: Roster
    let hosts: [String: ReliabilityHost]
    let sessions: [String: PiAgentSession]
    init(events: EventStore, existingHosts: [String: ReliabilityHost] = [:]) {
        var hosts: [String: ReliabilityHost] = [:]
        var sessions: [String: PiAgentSession] = [:]
        for id in ["a", "b", "c"] {
            let host = existingHosts[id] ?? ReliabilityHost(id: id)
            hosts[id] = host
            let session = PiAgentSession(agentID: id, store: events) { host.transport() }
            session.autoReconnect = false
            sessions[id] = session
        }
        self.hosts = hosts; self.sessions = sessions
        roster = Roster(members: ["a", "b", "c"].map {
            RosterMember(id: $0, name: $0, kind: .pi, avatarColor: "#777777", piEndpoint: .tcp(host: "127.0.0.1", port: 1))
        } + [RosterMember(id: "hosted", name: "Hosted", kind: .hosted, avatarColor: "#777777")], mailProjects: [])
    }
    func session(for agentID: String) -> PiAgentSession? { sessions[agentID] }
    func connect(_ ids: [String] = ["a", "b", "c"]) async { for id in ids { await sessions[id]!.connect() } }
    func disconnect() async { for session in sessions.values { await session.disconnect() } }
}

@MainActor
private final class ReliabilityHost {
    let id: String
    var sessionID: String
    var entries: [JSONValue] = []
    var prompts: [String] = []
    var promptAttempts = 0
    var approvalAnswers: [Bool] = []
    var streaming = false
    var loseAcknowledgement = false
    var rejectNextPrompt = false
    private var active: ReliabilityTransport?
    init(id: String) { self.id = id; sessionID = "isolated-\(id)-\(UUID().uuidString)" }
    func transport() -> ReliabilityTransport { let value = ReliabilityTransport(host: self); active = value; return value }
    func append(role: String, text: String, failed: Bool = false) {
        var message: [String: JSONValue] = ["role": .string(role), "content": .string(text)]
        if role == "toolResult" { message["isError"] = .bool(failed); message["toolName"] = "isolated_permission_probe" }
        entries.append(["type": "message", "id": .string(UUID().uuidString), "message": .object(message)])
    }
    func complete(_ text: String, notify: Bool = true) {
        append(role: "assistant", text: text); streaming = false
        if notify { active?.emit(["type": "agent_settled"]) }
    }
    func approval() { active?.emit(["type": "extension_ui_request", "method": "confirm", "id": "approval-isolated", "title": "Deny test operation?"]) }
    func restartWithoutHistory() { active?.close(); entries = []; streaming = false; sessionID = "isolated-restarted-\(UUID().uuidString)" }
    func receive(_ command: JSONValue, via transport: ReliabilityTransport) {
        let type = command["type"]?.stringValue ?? ""
        var reply: [String: JSONValue] = ["type": "response", "id": command["id"] ?? .null, "command": .string(type), "success": true]
        switch type {
        case "get_state": reply["data"] = ["sessionId": .string(sessionID), "isStreaming": .bool(streaming)]
        case "get_entries":
            let since = command["since"]?.stringValue
            let start = since.flatMap { cursor in entries.firstIndex { $0["id"]?.stringValue == cursor }.map { $0 + 1 } } ?? 0
            reply["data"] = ["entries": .array(Array(entries.dropFirst(start)))]
        case "prompt":
            promptAttempts += 1
            if rejectNextPrompt {
                rejectNextPrompt = false; reply["success"] = false; reply["error"] = "Permission denied before accepting prompt"; break
            }
            let prompt = command["message"]?.stringValue ?? ""
            prompts.append(prompt); append(role: "user", text: prompt); streaming = true
            if loseAcknowledgement { loseAcknowledgement = false; transport.close(); return }
            reply["data"] = ["disposition": "started"]
        case "extension_ui_response":
            approvalAnswers.append(command["confirmed"]?.boolValue ?? false)
            append(role: "toolResult", text: "Permission denied", failed: true); streaming = false
            transport.emit(["type": "agent_settled"]); return
        default: break
        }
        transport.emit(.object(reply))
    }
}

private final class ReliabilityTransport: PiTransport, @unchecked Sendable {
    let host: ReliabilityHost
    private let lock = NSLock()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    init(host: ReliabilityHost) { self.host = host }
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws { lock.lock(); self.onLine = onLine; self.onClose = onClose; lock.unlock() }
    func send(_ line: Data) throws {
        let command = try JSONValue.decode(line)
        Task { @MainActor in host.receive(command, via: self) }
    }
    func emit(_ value: JSONValue) {
        lock.lock(); let callback = onLine; lock.unlock()
        if let data = try? value.encoded() { callback?(data) }
    }
    func close() {
        lock.lock(); let callback = onClose; onLine = nil; onClose = nil; lock.unlock()
        callback?(nil)
    }
}
