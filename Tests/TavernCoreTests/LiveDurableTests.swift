import Foundation
import XCTest
@testable import TavernCore

/// Drives a real durable host through Tavern's own session code. Skipped unless
/// `TAVERN_LIVE_DURABLE=1`; run it on a machine with `bridge/tavern-durable/run.sh flint` up.
@MainActor
final class LiveDurableTests: XCTestCase {
    func testToolTurnStreamsSettlesAndStores() async throws {
        guard ProcessInfo.processInfo.environment["TAVERN_LIVE_DURABLE"] == "1" else {
            throw XCTSkip("set TAVERN_LIVE_DURABLE=1 with a durable host running")
        }
        // The roster Tavern itself reads, so this also checks Flint's endpoint decodes.
        let roster = Roster.load(from: Roster.defaultURL())
        let endpoint = try XCTUnwrap(roster.member(id: "flint")?.endpoint)
        guard case .tcp = endpoint else { return XCTFail("Flint is not on a tcp endpoint: \(endpoint)") }

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).sqlite").path
        let session = PiAgentSession(agentID: "flint", store: try EventStore(path: path)) { try endpoint.makeTransport() }
        session.autoReconnect = false
        await session.connect()
        for _ in 0..<2400 where session.presence == .working { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.presence, .idle, "connect: \(session.lastConnectError ?? "")")
        let before = session.transcript.count

        var sawStreaming = false, sawTool = false, sawWorking = false
        // The token is only in a file, so the reply can contain it only if the tool really ran.
        let token = "tavern-live-\(UUID().uuidString.prefix(8).lowercased())"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-live-\(UUID()).txt")
        try token.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        await session.send("Use the bash tool to run 'cat \(file.path)' and reply with exactly what it printed.")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            sawWorking = sawWorking || session.isWorking
            sawStreaming = sawStreaming || !session.streamingText.isEmpty
            sawTool = sawTool || session.currentTool != nil || !session.liveSteps.isEmpty
            if sawWorking && session.presence == .idle { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let added = session.transcript.dropFirst(before)
        print("live durable: streaming=\(sawStreaming) tool=\(sawTool) added=\(added.map { "\($0.role):\($0.text.prefix(60))" })")
        XCTAssertTrue(sawWorking)
        XCTAssertEqual(session.presence, .idle)
        XCTAssertTrue(sawStreaming)
        XCTAssertTrue(sawTool)
        XCTAssertTrue(added.contains { $0.role == .assistant && $0.text.contains(token) })
        XCTAssertEqual(Set(session.transcript.map(\.id)).count, session.transcript.count, "duplicate rows")
        await session.disconnect()
    }

    func testSteerFollowUpAbortCompact() async throws {
        guard ProcessInfo.processInfo.environment["TAVERN_LIVE_DURABLE"] == "1" else {
            throw XCTSkip("set TAVERN_LIVE_DURABLE=1 with a durable host running")
        }
        let endpoint = try XCTUnwrap(Roster.load(from: Roster.defaultURL()).member(id: "flint")?.endpoint)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).sqlite").path
        let session = PiAgentSession(agentID: "flint", store: try EventStore(path: path)) { try endpoint.makeTransport() }
        session.autoReconnect = false
        await session.connect()
        // A previous run's background compaction may still be finishing.
        for _ in 0..<2400 where session.presence != .idle { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.presence, .idle)

        func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }

        // A long turn to steer, queue behind and abort.
        await session.send("Use the bash tool to run 'sleep 20; echo slow-done', then reply with what it printed.")
        let started = try await waitFor(120) { session.currentTool != nil || !session.liveSteps.isEmpty }
        XCTAssertTrue(started, "tool never started")
        await session.steer("When you answer, also say the word steered.")
        XCTAssertNil(session.lastError, "steer: \(session.lastError ?? "")")
        await session.followUp("Then say the word followed.")
        XCTAssertNil(session.lastError, "follow-up: \(session.lastError ?? "")")
        XCTAssertGreaterThanOrEqual(session.pendingMessages.count, 2)

        let abortAt = Date()
        await session.abort()
        XCTAssertNil(session.lastError, "abort: \(session.lastError ?? "")")
        // Abort stops the run; a queued follow-up may then start its own run, so abort until idle.
        var idle = try await waitFor(20) { session.presence == .idle }
        if !idle { await session.abort(); idle = try await waitFor(20) { session.presence == .idle } }
        XCTAssertTrue(idle, "still \(session.presence) after abort")
        print("live durable: abort settled in \(Date().timeIntervalSince(abortAt))s, pending=\(session.pendingMessages.map(\.text))")
        XCTAssertFalse(session.transcript.contains { $0.role == .tool && $0.text.contains("slow-done") })
        XCTAssertTrue(session.pendingMessages.isEmpty, "left pending: \(session.pendingMessages.map(\.text))")
        XCTAssertNotNil(session.returnedDraft)

        await session.compact()
        // Compaction runs in the background; success or "nothing to compact" are both fine, a transport error is not.
        print("live durable: compact -> \(session.lastError ?? "ok")")
        XCTAssertFalse((session.lastError ?? "").contains("disconnected"))
        _ = try await waitFor(120) { session.presence == .idle }
        XCTAssertEqual(Set(session.transcript.map(\.id)).count, session.transcript.count, "duplicate rows")
        await session.disconnect()
    }

    /// Plan step 5a: restart the host mid-turn; the turn resumes and nothing is duplicated.
    /// Needs Flint's LaunchAgent (`dev.thrasher.tavern-durable.flint`), which this restarts.
    func testHostRestartMidTurnResumesWithoutDuplicates() async throws {
        guard ProcessInfo.processInfo.environment["TAVERN_LIVE_DURABLE"] == "1" else {
            throw XCTSkip("set TAVERN_LIVE_DURABLE=1 with a durable host running")
        }
        let endpoint = try XCTUnwrap(Roster.load(from: Roster.defaultURL()).member(id: "flint")?.endpoint)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).sqlite").path
        let session = PiAgentSession(agentID: "flint", store: try EventStore(path: path)) { try endpoint.makeTransport() }
        await session.connect()
        func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
        _ = try await waitFor(120) { session.presence == .idle }
        XCTAssertEqual(session.presence, .idle)

        let token = "restart-\(UUID().uuidString.prefix(8).lowercased())"
        let prompt = "Use the bash tool to run 'sleep 15; echo \(token)', then reply with exactly what it printed."
        await session.send(prompt)
        let started = try await waitFor(120) { session.currentTool != nil || !session.liveSteps.isEmpty }
        XCTAssertTrue(started, "tool never started")

        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "-k", "gui/\(getuid())/dev.thrasher.tavern-durable.flint"]
        try kick.run()
        kick.waitUntilExit()
        XCTAssertEqual(kick.terminationStatus, 0)

        // autoReconnect brings the session back; the resumed turn must finish with the token.
        let done = try await waitFor(300) {
            session.presence == .idle && session.transcript.contains { $0.role == .assistant && $0.text.contains(token) }
        }
        print("live durable restart: presence=\(session.presence) error=\(session.lastConnectError ?? "-") tail=\(session.transcript.suffix(4).map { "\($0.role):\($0.text.prefix(60))" })")
        XCTAssertTrue(done, "turn did not resume to completion")
        XCTAssertEqual(session.transcript.filter { $0.role == .user && $0.text == prompt }.count, 1, "prompt stored or run twice")
        XCTAssertEqual(Set(session.transcript.map(\.id)).count, session.transcript.count, "duplicate rows")
        await session.disconnect()
    }
}
