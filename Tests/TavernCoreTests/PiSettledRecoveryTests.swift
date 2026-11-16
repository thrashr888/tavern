import XCTest
@testable import TavernCore

@MainActor
final class PiSettledRecoveryTests: XCTestCase {
    func testNewStartIsConsumedWhileSettledSyncWaitsAndCannotBeOverwritten() async throws {
        let transport = DelayedEntriesPi()
        let session = PiAgentSession(agentID: "qa", store: try EventStore(path: ":memory:")) { transport }
        await session.connect()
        XCTAssertEqual(session.presence, .idle)
        transport.emit(["type": "agent_start"])
        await eventually { session.presence == .working }
        transport.delayNextEntries()
        transport.emit(["type": "agent_settled"])
        await eventually { transport.hasHeldReply }
        transport.emit(["type": "agent_start"])
        transport.emit(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": "new turn"]])
        // Must be consumed now, not left behind the awaited settled read.
        await eventually { session.streamingText == "new turn" }
        transport.releaseEntries()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.presence, .working)
        XCTAssertEqual(session.streamingText, "new turn")
        transport.emit(["type": "agent_settled"])
        await eventually { session.presence == .idle }
        XCTAssertEqual(session.streamingText, "")
        await session.disconnect()
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for fixture state", file: file, line: line)
    }
}

private final class DelayedEntriesPi: PiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (Data) -> Void)?
    private var closed: (@Sendable (Error?) -> Void)?
    private var shouldDelay = false
    private var held: JSONValue?
    var hasHeldReply: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    func delayNextEntries() { lock.lock(); shouldDelay = true; lock.unlock() }
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        lock.lock(); receive = onLine; closed = onClose; lock.unlock()
    }
    func emit(_ value: JSONValue) {
        lock.lock(); let callback = receive; lock.unlock()
        if let data = try? value.encoded() { callback?(data) }
    }
    func send(_ line: Data) throws {
        let request = try JSONValue.decode(line)
        let type = request["type"]?.stringValue ?? ""
        let data: JSONValue = type == "get_state" ? ["sessionId": "qa", "isStreaming": false] : ["entries": .array([])]
        let response: JSONValue = ["type": "response", "id": request["id"] ?? .null, "command": .string(type), "success": true, "data": data]
        lock.lock()
        if type == "get_entries", shouldDelay { held = response; shouldDelay = false; lock.unlock(); return }
        lock.unlock()
        emit(response)
    }
    func releaseEntries() {
        lock.lock(); let response = held; held = nil; lock.unlock()
        if let response { emit(response) }
    }
    func close() { lock.lock(); let callback = closed; lock.unlock(); callback?(nil) }
}
