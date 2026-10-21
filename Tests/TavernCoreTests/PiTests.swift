import XCTest
@testable import TavernCore

// Fixtures are hand-written from the pi.dev RPC and session-format docs. Replace or extend them
// with the redacted real session from PAUL-189 when it arrives.

final class PiProtocolTests: XCTestCase {
    func testFramerSplitsOnLFAndStripsCR() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("{\"a\":1}\r\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(framer.push(Data(":2}\n\n".utf8)), [Data("{\"b\":2}".utf8)])
    }

    func testFramerDoesNotSplitOnUnicodeLineSeparator() {
        var framer = LineFramer()
        let line = "{\"text\":\"a\u{2028}b\"}"
        XCTAssertEqual(framer.push(Data((line + "\n").utf8)), [Data(line.utf8)])
    }

    func testCommandJSON() throws {
        XCTAssertEqual(
            PiCommand.prompt("hi", streamingBehavior: .followUp).json(id: "1"),
            ["id": "1", "type": "prompt", "message": "hi", "streamingBehavior": "followUp"]
        )
        XCTAssertEqual(PiCommand.followUp("later").json(id: "2"), ["id": "2", "type": "follow_up", "message": "later"])
        XCTAssertEqual(PiCommand.prompt("look", streamingBehavior: nil, images: [PiImage(data: Data([1, 2]), mimeType: "image/png")]).json(id: "3"),
                       ["id": "3", "type": "prompt", "message": "look",
                        "images": .array([["type": "image", "data": "AQI=", "mimeType": "image/png"]])])
        XCTAssertEqual(PiCommand.steer("now").json(id: "5", requestId: "r1"),
                       ["id": "5", "type": "steer", "message": "now", "requestId": "r1"])
        XCTAssertEqual(PiCommand.getState.json(id: "6", requestId: "r2"), ["id": "6", "type": "get_state"])
        XCTAssertEqual(PiCommand.getEntries(since: "e1").json(id: "3"), ["id": "3", "type": "get_entries", "since": "e1"])
        XCTAssertEqual(PiCommand.getEntries(since: nil).json(id: "4"), ["id": "4", "type": "get_entries"])
    }

    func testParsesResponsesEventsAndDialogs() throws {
        let response = try PiRecord.parse(Data(#"{"id":"tavern-1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#.utf8))
        guard case .response(let parsed) = response else { return XCTFail("not a response") }
        XCTAssertEqual(parsed.id, "tavern-1")
        XCTAssertEqual(parsed.data?["disposition"]?.stringValue, "started")

        let failure = try PiRecord.parse(Data(#"{"type":"response","command":"parse","success":false,"error":"bad json"}"#.utf8))
        guard case .response(let parseError) = failure else { return XCTFail("not a response") }
        XCTAssertNil(parseError.id)
        XCTAssertFalse(parseError.success)

        let dialog = try PiRecord.parse(Data(#"{"type":"extension_ui_request","id":"d1","method":"select","title":"Pick","options":["a","b"],"timeout":5000}"#.utf8))
        XCTAssertEqual(dialog, .dialog(PiDialog(id: "d1", method: .select, title: "Pick", options: ["a", "b"])))

        let notice = try PiRecord.parse(Data(#"{"type":"extension_ui_request","id":"n1","method":"notify","message":"hi"}"#.utf8))
        guard case .extensionNotice(let method, _) = notice else { return XCTFail("not a notice") }
        XCTAssertEqual(method, "notify")

        let event = try PiRecord.parse(Data(#"{"type":"agent_settled"}"#.utf8))
        guard case .event(let type, _) = event else { return XCTFail("not an event") }
        XCTAssertEqual(type, "agent_settled")
    }

    func testDialogAnswers() {
        XCTAssertEqual(PiDialogAnswer.confirmed(true).json(dialogID: "d"), ["type": "extension_ui_response", "id": "d", "confirmed": true])
        XCTAssertEqual(PiDialogAnswer.value("a").json(dialogID: "d"), ["type": "extension_ui_response", "id": "d", "value": "a"])
        XCTAssertEqual(PiDialogAnswer.cancelled.json(dialogID: "d"), ["type": "extension_ui_response", "id": "d", "cancelled": true])
    }
}

final class PiEntriesTests: XCTestCase {
    func testEntriesMapToEventsAndTranscript() {
        let entries = FakePi.entries(["e1", "e2", "e3", "e4"])
        let events = PiEntries.events(from: entries, sessionID: "s1", agentID: "flint")
        XCTAssertEqual(events.map(\.sourceID), ["s1:e1", "s1:e2", "s1:e3", "s1:e4"])
        XCTAssertEqual(events.map(\.kind), ["pi.message.user", "pi.message.assistant", "pi.message.toolResult", "pi.compaction"])
        XCTAssertEqual(events.first?.authorAgent, "paul")
        XCTAssertEqual(events.first?.threadKey, "pi:flint")

        let items = events.compactMap(TranscriptItem.init(event:))
        XCTAssertEqual(items.map(\.text), ["Prompt e1", "Reply e2", "Ran bash", "Context compacted"])
        XCTAssertEqual(items.map(\.role), [.user, .assistant, .tool, .system])
    }

    func testFailedAndAbortedRepliesShowWhy() throws {
        func item(_ stopReason: String, _ error: String) throws -> TranscriptItem? {
            let entry: JSONValue = [
                "type": "message", "id": "e1", "timestamp": "2026-10-15T06:00:16.321Z",
                "message": ["role": "assistant", "content": .array([]), "stopReason": .string(stopReason), "errorMessage": .string(error)],
            ]
            let event = PiEntries.events(from: [entry], sessionID: "s1", agentID: "flint")[0]
            return TranscriptItem(event: event)
        }
        let failed = try item("error", "404: model not found")
        XCTAssertEqual(failed?.role, .system)
        XCTAssertEqual(failed?.text, "404: model not found")
        XCTAssertEqual(failed?.failed, true)
        XCTAssertEqual(try item("aborted", "Request aborted")?.text, "Aborted")
    }

    func testThinkingBlocksAreKeptApartFromReplyText() {
        let entry: JSONValue = [
            "type": "message", "id": "e1", "timestamp": "2026-10-15T06:00:16.321Z",
            "message": ["role": "assistant", "content": .array([
                ["type": "thinking", "thinking": "Check the plan first."],
                ["type": "text", "text": "Done."],
            ])],
        ]
        let item = TranscriptItem(event: PiEntries.events(from: [entry], sessionID: "s1", agentID: "flint")[0])
        XCTAssertEqual(item?.text, "Done.")
        XCTAssertEqual(item?.thinking, "Check the plan first.")

        // A turn that only thought (then called a tool) still shows.
        let thoughtOnly: JSONValue = [
            "type": "message", "id": "e2", "timestamp": "2026-10-15T06:00:17Z",
            "message": ["role": "assistant", "content": .array([["type": "thinking", "thinking": "Hmm."]])],
        ]
        let thought = TranscriptItem(event: PiEntries.events(from: [thoughtOnly], sessionID: "s1", agentID: "flint")[0])
        XCTAssertEqual(thought?.role, .assistant)
        XCTAssertEqual(thought?.thinking, "Hmm.")
    }

    func testLocalPiLaunchContinuesLatestSession() {
        XCTAssertEqual(PiProcessTransport.continuing(["/usr/bin/env", "pi", "--mode", "rpc"]),
                       ["/usr/bin/env", "pi", "--mode", "rpc", "--continue"])
        XCTAssertEqual(PiProcessTransport.continuing(["/opt/homebrew/bin/pi", "--mode", "rpc", "-c"]),
                       ["/opt/homebrew/bin/pi", "--mode", "rpc", "-c"])
        XCTAssertEqual(PiProcessTransport.continuing(["/usr/bin/env", "pi", "--mode", "rpc", "--session", "x.jsonl"]),
                       ["/usr/bin/env", "pi", "--mode", "rpc", "--session", "x.jsonl"])
        XCTAssertEqual(PiProcessTransport.continuing(["/usr/bin/env", "pi", "--mode", "rpc", "--session-id", "tavern-flint"]),
                       ["/usr/bin/env", "pi", "--mode", "rpc", "--session-id", "tavern-flint"])
        // Not a local Pi in RPC mode: left alone.
        XCTAssertEqual(PiProcessTransport.continuing(["/usr/bin/ssh", "-T", "ser8", "pi --mode rpc"]),
                       ["/usr/bin/ssh", "-T", "ser8", "pi --mode rpc"])
    }

    func testToolRunsFoldIntoWorkRows() {
        let entries: [JSONValue] = [
            ["type": "message", "id": "u1", "timestamp": "2026-10-15T06:00:00Z",
             "message": ["role": "user", "content": "find the b-sides"]],
            ["type": "message", "id": "a1", "timestamp": "2026-10-15T06:00:02Z",
             "message": ["role": "assistant", "content": .array([
                 ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "ls -la\necho hi"]],
                 ["type": "toolCall", "id": "c2", "name": "read", "arguments": ["path": "queue.txt"]],
             ])]],
            ["type": "message", "id": "r1", "timestamp": "2026-10-15T06:00:05Z",
             "message": ["role": "toolResult", "toolCallId": "c1", "toolName": "bash", "content": .array([])]],
            ["type": "message", "id": "r2", "timestamp": "2026-10-15T06:00:14Z",
             "message": ["role": "toolResult", "toolCallId": "c2", "toolName": "read", "isError": true, "content": .array([])]],
            ["type": "message", "id": "a2", "timestamp": "2026-10-15T06:00:20Z",
             "message": ["role": "assistant", "content": .array([["type": "text", "text": "Here they are."]])]],
        ]
        let items = PiEntries.events(from: entries, sessionID: "s1", agentID: "flint").compactMap(TranscriptItem.init(event:))
        let rows = PiActivity.rows(from: items)
        XCTAssertEqual(rows.count, 3)
        guard case .work(let work) = rows[1] else { return XCTFail("expected a work row") }
        XCTAssertEqual(work.steps.map(\.title), ["Ran ls -la", "Read queue.txt"])
        XCTAssertEqual(work.steps.map(\.kind), [.shell, .read])
        XCTAssertEqual(work.steps[0].duration, 3)
        XCTAssertTrue(work.steps[1].failed)
        XCTAssertEqual(work.summary, "Worked 12s · 2 steps")
        guard case .message(let reply) = rows[2] else { return XCTFail("expected the reply") }
        XCTAssertEqual(reply.text, "Here they are.")
    }

    func testStepDescriptions() {
        XCTAssertEqual(PiStep.describe(toolName: "web_search", arguments: ["query": "oasis b-sides"]).1,
                       "Searched the web for \"oasis b-sides\"")
        XCTAssertEqual(PiStep.describe(toolName: "custom", arguments: .null).0, .other)
        XCTAssertEqual(PiWork.format(0.42), "0.4s")
        XCTAssertEqual(PiWork.format(75), "1m 15s")
    }

    func testDurationFormatting() {
        XCTAssertEqual(PiWork.format(0), "0.0s")
        XCTAssertEqual(PiWork.format(-2), "0.0s")
        XCTAssertEqual(PiWork.format(0.7), "0.7s")
        XCTAssertEqual(PiWork.format(4.34), "4.3s")
        XCTAssertEqual(PiWork.format(9.94), "9.9s")
        XCTAssertEqual(PiWork.format(9.96), "10s")
        XCTAssertEqual(PiWork.format(12.4), "12s")
        XCTAssertEqual(PiWork.format(59.6), "1m 0s")
        XCTAssertEqual(PiWork.format(3599), "59m 59s")
        XCTAssertEqual(PiWork.format(3725), "1h 2m")
    }

    func testRunningStepsCountUpAndFailedStepsKeepTheirDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        var step = PiStep(id: "c1", toolName: "bash", kind: .shell, title: "Ran make", started: start)
        XCTAssertNil(step.duration)
        XCTAssertEqual(step.elapsed(at: start.addingTimeInterval(4.3)), 4.3, accuracy: 0.001)
        step.ended = start.addingTimeInterval(0.7)
        step.failed = true
        XCTAssertEqual(step.elapsed(at: start.addingTimeInterval(60)), 0.7, accuracy: 0.001)
        let running = PiWork(id: "w", steps: [PiStep(id: "c2", toolName: "read", kind: .read, title: "Read a", started: start)])
        XCTAssertEqual(running.summary, "Working · 1 step")
        XCTAssertEqual(running.summary(at: start.addingTimeInterval(12)), "Working 12s · 1 step")
    }

    func testThoughtSummaries() {
        XCTAssertEqual(PiStep.thoughtSummary("**Planning the fix**\n\nFirst I'll read the file."), "Planning the fix")
        XCTAssertEqual(PiStep.thoughtSummary("\n\n  ## Checking tests\nmore"), "Checking tests")
        XCTAssertEqual(PiStep.thoughtSummary("   \n "), "Thought")
        XCTAssertEqual(PiStep.thoughtSummary(String(repeating: "x", count: 100)).count, 80)
    }

    func testCallOnlyTurnThinkingBecomesATimedThoughtStep() {
        let entries: [JSONValue] = [
            ["type": "message", "id": "u1", "timestamp": "2026-10-15T06:00:00Z",
             "message": ["role": "user", "content": "fix the build"]],
            ["type": "message", "id": "a1", "timestamp": "2026-10-15T06:00:04Z",
             "message": ["role": "assistant", "content": .array([
                 ["type": "thinking", "thinking": "**Reading the error**\nIt fails in Package.swift."],
                 ["type": "toolCall", "id": "c1", "name": "read", "arguments": ["path": "Package.swift"]],
             ])]],
            ["type": "message", "id": "r1", "timestamp": "2026-10-15T06:00:05Z",
             "message": ["role": "toolResult", "toolCallId": "c1", "toolName": "read", "content": .array([])]],
            ["type": "message", "id": "a2", "timestamp": "2026-10-15T06:00:09Z",
             "message": ["role": "assistant", "content": .array([["type": "text", "text": "Fixed."]])]],
        ]
        let items = PiEntries.events(from: entries, sessionID: "s1", agentID: "flint").compactMap(TranscriptItem.init(event:))
        let rows = PiActivity.rows(from: items)
        XCTAssertEqual(rows.count, 3)
        guard case .work(let work) = rows[1] else { return XCTFail("expected a work row") }
        XCTAssertEqual(work.steps.map(\.kind), [.thought, .read])
        XCTAssertEqual(work.steps.map(\.title), ["Reading the error", "Read Package.swift"])
        XCTAssertEqual(work.steps[0].duration, 4)
        XCTAssertEqual(work.steps[1].duration, 1)
        XCTAssertEqual(work.summary, "Worked 5.0s · 2 steps")
    }

    func testTimestampsParseWithAndWithoutFraction() {
        XCTAssertNotNil(PiEntries.parseTimestamp("2026-10-15T05:00:00.123Z"))
        XCTAssertNotNil(PiEntries.parseTimestamp("2026-10-15T05:00:00Z"))
        XCTAssertNil(PiEntries.parseTimestamp("yesterday"))
    }

    func testCursorRoundTrip() {
        let cursor = PiEntries.Cursor(sessionID: "s1", entryID: "e9")
        XCTAssertEqual(PiEntries.Cursor(stored: cursor.stored), cursor)
        XCTAssertNil(PiEntries.Cursor(stored: nil))
    }
}

@MainActor
final class PiAgentSessionTests: XCTestCase {
    func testConnectStoresHistoryOnce() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1", "e2"])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }

        await session.connect()
        XCTAssertEqual(session.presence, .idle)
        XCTAssertEqual(session.transcript.map(\.text), ["Prompt e1", "Reply e2"])

        // Reconnect asks only for entries after the cursor and adds nothing twice.
        await session.disconnect()
        pi.entryIDs.append("e3")
        await session.connect()
        XCTAssertEqual(pi.lastSince, "e2")
        XCTAssertEqual(try store.eventCount(), 3)
        XCTAssertEqual(try store.cursor(for: "pi:flint"), "s1|e3")
    }

    func testUnknownCursorFallsBackToFullResyncWithoutDuplicates() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1", "e2"])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()
        await session.disconnect()

        // Pi no longer knows e2 (for example the session file was rewritten).
        pi.unknownSince = ["e2"]
        pi.entryIDs.append("e3")
        await session.connect()
        XCTAssertEqual(try store.eventCount(), 3)
        XCTAssertEqual(session.transcript.count, 3)
    }

    func testNewPiSessionKeepsOneTavernThread() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1"])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()
        await session.disconnect()

        pi.sessionID = "s2"
        pi.entryIDs = ["e1"]
        await session.connect()
        XCTAssertEqual(try store.eventCount(), 2)
        XCTAssertEqual(session.transcript.count, 2)
    }

    func testSentMessageShowsUntilStored() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: try EventStore(path: ":memory:")) { pi }
        await session.connect()

        await session.send("Prompt e1")
        XCTAssertEqual(session.pendingMessages.map(\.text), ["Prompt e1"])
        XCTAssertEqual(session.presence, .working)

        pi.entryIDs = ["e1", "e2"]
        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertEqual(session.transcript.map(\.text), ["Prompt e1", "Reply e2"])
        XCTAssertTrue(session.pendingMessages.isEmpty)

        // The same text sent again stays pending: the earlier row doesn't count.
        await session.send("Prompt e1")
        XCTAssertEqual(session.pendingMessages.count, 1)

        // A send that fails isn't left pending.
        await session.disconnect()
        await session.send("lost")
        XCTAssertFalse(session.pendingMessages.contains { $0.text == "lost" })
    }

    func testAbortReturnsQueuedMessagesToTheComposer() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: try EventStore(path: ":memory:")) { pi }
        await session.connect()
        await session.send("Prompt e1")
        pi.entryIDs = ["e1"]
        try await session.sync()  // the prompt is stored; it is not handed back
        await session.steer("go left")
        await session.followUp("then right")
        await session.abort()
        XCTAssertTrue(session.pendingMessages.isEmpty)
        XCTAssertEqual(session.returnedDraft, "go left\nthen right")
    }

    func testStreamingDeltasSettleIntoTranscript() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()

        await session.handle(.event(type: "agent_start", raw: ["type": "agent_start"]))
        XCTAssertEqual(session.presence, .working)
        await session.handle(.event(type: "message_update", raw: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "delta": "Hel"],
        ]))
        await session.handle(.event(type: "message_update", raw: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "delta": "lo"],
        ]))
        XCTAssertEqual(session.streamingText, "Hello")
        await session.handle(.event(type: "tool_execution_start", raw: ["type": "tool_execution_start", "toolName": "bash"]))
        XCTAssertEqual(session.currentTool, "bash")

        // agent_end alone does not finish the turn.
        await session.handle(.event(type: "agent_end", raw: ["type": "agent_end"]))
        XCTAssertEqual(session.presence, .working)

        pi.entryIDs = ["e1", "e2"]
        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertEqual(session.presence, .idle)
        XCTAssertEqual(session.streamingText, "")
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(session.transcript.count, 2)
    }

    func testThinkingStreamsSoATurnDoesNotLookIdle() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()

        await session.handle(.event(type: "agent_start", raw: ["type": "agent_start"]))
        XCTAssertFalse(session.isThinking)
        await session.handle(.event(type: "message_update", raw: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "thinking_delta", "delta": "Let me look"],
        ]))
        XCTAssertEqual(session.streamingThinking, "Let me look")
        XCTAssertTrue(session.isThinking)
        await session.handle(.event(type: "message_update", raw: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "thinking_delta", "delta": " at the logs\nThen fix it"],
        ]))
        // The live step list shows the thought running, titled by its first line.
        XCTAssertEqual(session.liveSteps.map(\.kind), [.thought])
        XCTAssertEqual(session.liveSteps.first?.title, "Let me look at the logs")
        XCTAssertEqual(session.liveSteps.first?.isRunning, true)

        await session.handle(.event(type: "message_update", raw: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "delta": "Found it"],
        ]))
        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.liveSteps.first?.isRunning, false)

        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertEqual(session.streamingThinking, "")
    }

    func testLiveToolStepsTrackTheTurn() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()

        await session.handle(.event(type: "agent_start", raw: ["type": "agent_start"]))
        await session.handle(.event(type: "tool_execution_start", raw: [
            "type": "tool_execution_start", "toolCallId": "c1", "toolName": "bash", "args": ["command": "make test"],
        ]))
        XCTAssertEqual(session.liveWork?.steps.first?.title, "Ran make test")
        XCTAssertEqual(session.liveWork?.isRunning, true)
        await session.handle(.event(type: "tool_execution_end", raw: [
            "type": "tool_execution_end", "toolCallId": "c1", "toolName": "bash", "isError": false,
        ]))
        XCTAssertEqual(session.liveWork?.isRunning, false)

        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertNil(session.liveWork)
    }

    func testDialogWaitsOnYouUntilAnswered() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()

        let dialog = PiDialog(id: "d1", method: .confirm, title: "Run it?")
        await session.handle(.dialog(dialog))
        XCTAssertEqual(session.dialog, dialog)

        await session.answer(.confirmed(true))
        XCTAssertNil(session.dialog)
        XCTAssertEqual(pi.sent.last, ["type": "extension_ui_response", "id": "d1", "confirmed": true])
    }

    func testPromptWhileBusyIsNotSentWithoutBehavior() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let session = PiAgentSession(agentID: "flint", store: store) { pi }
        await session.connect()

        pi.streaming = true
        await session.send("hi")
        XCTAssertNotNil(session.lastError)

        await session.followUp("later")
        XCTAssertNil(session.lastError)
        XCTAssertEqual(pi.sent.last?["type"], "follow_up")
    }
}

@MainActor
final class ModelLockTests: XCTestCase {
    private func makeSession(_ pi: FakePi) throws -> (PiAgentSession, ModelLockStore, EventStore) {
        let defaults = UserDefaults(suiteName: "tavern-tests-\(UUID().uuidString)")!
        let locks = ModelLockStore(defaults: defaults)
        let store = try EventStore(path: ":memory:")
        return (PiAgentSession(agentID: "flint", store: store, modelLocks: locks) { pi }, locks, store)
    }

    func testCommandJSON() {
        XCTAssertEqual(PiCommand.setModel(PiModel(provider: "ollama", id: "gemma4")).json(id: "1"),
                       ["id": "1", "type": "set_model", "provider": "ollama", "modelId": "gemma4"])
        XCTAssertEqual(PiCommand.getAvailableModels.json(id: "2"), ["id": "2", "type": "get_available_models"])
    }

    func testLockedByDefaultAndNeverSendsSetModel() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let (session, _, _) = try makeSession(pi)
        await session.connect()
        XCTAssertTrue(session.modelLocked)
        XCTAssertEqual(session.config.model?.label, "ollama/qwen3.5")

        do {
            try await session.switchModel(to: PiModel(provider: "ollama", id: "gemma4"))
            XCTFail("switch went through while locked")
        } catch let error as ModelSwitchError {
            XCTAssertEqual(error, .locked)
        }
        XCTAssertFalse(pi.sent.contains { $0["type"] == "set_model" })
    }

    func testUnlockedSwitchLogsAndShowsATranscriptLine() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let (session, locks, store) = try makeSession(pi)
        await session.connect()
        session.setModelLocked(false)
        await session.loadAvailableModels()
        XCTAssertEqual(session.availableModels.map(\.id), ["qwen3.5", "gemma4"])

        try await session.switchModel(to: PiModel(provider: "ollama", id: "gemma4"))
        XCTAssertEqual(pi.sent.last?["type"], "set_model")
        XCTAssertEqual(session.config.model?.id, "gemma4")
        XCTAssertEqual(session.transcript.last?.text, "Tavern switched the model from ollama/qwen3.5 to ollama/gemma4")
        let log = ModelChangeLog.entries(agentID: "flint", store: store)
        XCTAssertEqual(log.first?.to.id, "gemma4")
        XCTAssertEqual(log.first?.from, "ollama/qwen3.5")

        locks.setLocked(true, for: "flint")
        do {
            try await session.switchModel(to: PiModel(provider: "ollama", id: "qwen3.5"))
            XCTFail("switch went through after relocking")
        } catch {}
    }

    func testSwitchMidTurnWaitsForSettleAndRevertUsesLastGood() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1", "e2"])
        let (session, _, _) = try makeSession(pi)
        await session.connect()
        session.setModelLocked(false)

        // A clean turn on qwen3.5 makes it the last known good model.
        await session.handle(.event(type: "agent_start", raw: ["type": "agent_start"]))
        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertEqual(session.lastKnownGoodModel?.id, "qwen3.5")

        await session.handle(.event(type: "agent_start", raw: ["type": "agent_start"]))
        try await session.switchModel(to: PiModel(provider: "ollama", id: "gemma4"))
        XCTAssertEqual(session.pendingModel?.id, "gemma4")
        XCTAssertFalse(pi.sent.contains { $0["type"] == "set_model" })

        await session.handle(.event(type: "agent_settled", raw: ["type": "agent_settled"]))
        XCTAssertNil(session.pendingModel)
        XCTAssertEqual(session.config.model?.id, "gemma4")

        try await session.revertToLastKnownGood()
        XCTAssertEqual(session.config.model?.id, "qwen3.5")
    }

    func testAnsweredDialogsAreLoggedForApprovals() async throws {
        let pi = FakePi(sessionID: "s1", entryIDs: [])
        let (session, _, store) = try makeSession(pi)
        await session.connect()
        await session.handle(.dialog(PiDialog(id: "d1", method: .confirm, title: "Run rm?")))
        await session.answer(.confirmed(false))
        let entries = ApprovalLog.entries(agentID: "flint", store: store)
        XCTAssertEqual(entries.map(\.title), ["Run rm?"])
        XCTAssertEqual(entries.map(\.answer), ["Declined"])
        XCTAssertFalse(session.transcript.contains { $0.text.contains("Run rm?") })
    }
}

/// Scripted in-memory Pi. Answers commands the way the RPC docs describe.
final class FakePi: PiTransport, @unchecked Sendable {
    var sessionID: String
    var entryIDs: [String]
    var unknownSince: Set<String> = []
    var streaming = false
    var model: PiModel? = PiModel(provider: "ollama", id: "qwen3.5")
    private(set) var lastSince: String?
    private(set) var sent: [JSONValue] = []
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?

    init(sessionID: String, entryIDs: [String]) {
        self.sessionID = sessionID
        self.entryIDs = entryIDs
    }

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        self.onLine = onLine
        self.onClose = onClose
    }

    func send(_ line: Data) throws {
        let command = try JSONValue.decode(line)
        sent.append(command)
        guard let id = command["id"]?.stringValue, let type = command["type"]?.stringValue else { return }
        var reply: [String: JSONValue] = ["id": .string(id), "type": "response", "command": .string(type), "success": true]
        switch type {
        case "get_state":
            var data: [String: JSONValue] = ["sessionId": .string(sessionID), "isStreaming": .bool(streaming)]
            if let model { data["model"] = ["provider": .string(model.provider), "id": .string(model.id)] }
            reply["data"] = .object(data)
        case "get_available_models":
            reply["data"] = ["models": .array([["provider": "ollama", "id": "qwen3.5"], ["provider": "ollama", "id": "gemma4"]])]
        case "set_model":
            model = PiModel(provider: command["provider"]?.stringValue ?? "", id: command["modelId"]?.stringValue ?? "")
            reply["data"] = ["provider": .string(model!.provider), "id": .string(model!.id)]
        case "get_entries":
            let since = command["since"]?.stringValue
            lastSince = since
            if let since, unknownSince.contains(since) || !entryIDs.contains(since) {
                reply["success"] = false
                reply["error"] = "unknown entry"
            } else {
                let start = since.flatMap { entryIDs.firstIndex(of: $0).map { $0 + 1 } } ?? 0
                reply["data"] = ["entries": .array(Self.entries(Array(entryIDs[start...])))]
            }
        case "prompt":
            if streaming && command["streamingBehavior"] == nil {
                reply["success"] = false
                reply["error"] = "agent is streaming"
            } else {
                reply["data"] = ["disposition": "started"]
            }
        case "steer", "follow_up":
            reply["data"] = ["disposition": "queued"]
        default:
            break
        }
        onLine?(try JSONValue.object(reply).encoded())
    }

    func close() {
        onClose?(nil)
    }

    /// Simulates the remote end going away (host sleep, tunnel drop).
    func drop() {
        onClose?(nil)
    }

    /// e1 user, e2 assistant, e3 tool result, e4 compaction, then repeating.
    static func entries(_ ids: [String]) -> [JSONValue] {
        ids.enumerated().map { index, id in
            let timestamp = JSONValue.string(String(format: "2026-10-15T05:%02d:00.000Z", index % 60))
            switch index % 4 {
            case 0:
                return ["type": "message", "id": .string(id), "timestamp": timestamp,
                        "message": ["role": "user", "content": .string("Prompt \(id)")]]
            case 1:
                return ["type": "message", "id": .string(id), "timestamp": timestamp,
                        "message": ["role": "assistant", "content": .array([["type": "text", "text": .string("Reply \(id)")]])]]
            case 2:
                return ["type": "message", "id": .string(id), "timestamp": timestamp,
                        "message": ["role": "toolResult", "toolName": "bash", "isError": false, "content": .array([])]]
            default:
                return ["type": "compaction", "id": .string(id), "timestamp": timestamp,
                        "summary": "summary", "firstKeptEntryId": "e1", "tokensBefore": .number(1000)]
            }
        }
    }
}

final class ToolCardTests: XCTestCase {
    func testToolResultWithUIDetailsBecomesACardRow() throws {
        let call: JSONValue = ["type": "message", "id": "a1", "timestamp": "2026-10-19T10:00:00Z",
                               "message": ["role": "assistant", "content": .array([["type": "toolCall", "id": "c1", "name": "cider__weather_forecast", "arguments": ["days": .number(3)]]])]]
        let result: JSONValue = ["type": "message", "id": "r1", "timestamp": "2026-10-19T10:00:02Z",
                                 "message": ["role": "toolResult", "toolCallId": "c1", "toolName": "cider__weather_forecast", "isError": false,
                                             "content": .array([]),
                                             "details": ["ui": ["server": "cider", "resourceUri": "ui://cider/weather", "structuredContent": ["ok": true]]]]]
        let items = PiEntries.events(from: [call, result], sessionID: "s", agentID: "ember").compactMap(TranscriptItem.init(event:))
        let rows = PiActivity.rows(from: items)
        guard case .card(_, let card) = rows.last else { return XCTFail("no card row: \(rows)") }
        XCTAssertEqual(card.server, "cider")
        XCTAssertEqual(card.resourceUri, "ui://cider/weather")
        XCTAssertEqual(card.arguments["days"]?.doubleValue, 3)
        XCTAssertEqual(card.structuredContent["ok"]?.boolValue, true)
        if case .work = rows.first {} else { XCTFail("the step still shows") }
    }

    func testCardPagesKeepOnlyHTTPSImageHosts() {
        let page = ToolCardPage(json: ["html": "<p>x</p>", "meta": ["csp": ["resourceDomains": .array(["https://weatherkit.apple.com", "http://evil.example", "https://a.example; script-src *", "*"])]]])
        XCTAssertEqual(page?.imageDomains, ["https://weatherkit.apple.com"])
        XCTAssertNil(ToolCard(details: ["ui": ["server": "x", "resourceUri": "https://x.example"]], toolName: "t"), "only ui:// resources")
    }
}

final class HeartbeatRowTests: XCTestCase {
    func testHeartbeatTurnsFoldIntoOneBackgroundRow() {
        let t = Date()
        let items = [
            TranscriptItem(id: "1", role: .user, text: "Fix the build", date: t),
            TranscriptItem(id: "2", role: .assistant, text: "Fixed.", date: t),
            TranscriptItem(id: "3", role: .user, text: "[Heartbeat 2026-10-21T01:00:00Z] New since the last check:\n- [mail] m2 (subject: Deploy is done)\n- [linear] PAUL-9 (title: Tavern)\n\nHandle what's yours.", date: t),
            TranscriptItem(id: "4", role: .assistant, text: "Drafted a reply to Rook.", date: t),
            TranscriptItem(id: "5", role: .user, text: "Thanks", date: t),
        ]
        let rows = PiActivity.rows(from: items)
        XCTAssertEqual(rows.map(\.id), ["1", "2", "background:3", "5"])
        guard case .background(let run) = rows[2] else { return XCTFail() }
        XCTAssertEqual(run.title, "2 new")
        XCTAssertEqual(run.newItems.first, "[mail] m2 (subject: Deploy is done)")
        XCTAssertEqual(run.reply, "Drafted a reply to Rook.")
    }
}
