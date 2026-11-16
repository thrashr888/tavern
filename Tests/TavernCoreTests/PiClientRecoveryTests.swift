import XCTest
@testable import TavernCore

final class PiClientRecoveryTests: XCTestCase {
    func testSilentConnectionTimesOutWithoutResendingAndAcceptsNextRead() async throws {
        let transport = SilentPiTransport()
        let client = PiClient(transport: transport, requestTimeout: .milliseconds(20))
        try await client.start()
        do { _ = try await client.send(.prompt("once", streamingBehavior: nil)); XCTFail("Should time out") }
        catch { XCTAssertEqual(error as? PiClientError, .timedOut(command: "prompt")) }
        XCTAssertEqual(transport.count, 1)
        // Late acknowledgement of the attempted prompt must not satisfy the next read.
        await client.receive(Data(#"{"id":"tavern-1","type":"response","command":"prompt","success":true}"#.utf8))
        do { _ = try await client.send(.getState); XCTFail("Should still wait for its own reply") }
        catch { XCTAssertEqual(error as? PiClientError, .timedOut(command: "get_state")) }
        XCTAssertEqual(transport.count, 2)
        await client.close()
    }

    func testCancellationReleasesPendingRequestWithoutWaitingForTimeout() async throws {
        let transport = SilentPiTransport()
        let client = PiClient(transport: transport, requestTimeout: .seconds(5))
        try await client.start()
        let completed = expectation(description: "Cancellation finishes")
        let pending = Task {
            do { _ = try await client.send(.getState); XCTFail("Should cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        while transport.count == 0 { await Task.yield() }
        pending.cancel()
        await fulfillment(of: [completed], timeout: 1)
        await client.close()
    }

    func testExplicitCloseReleasesPendingEvenWithoutTransportCloseCallback() async throws {
        let transport = SilentPiTransport()
        let client = PiClient(transport: transport, requestTimeout: .seconds(5))
        try await client.start()
        let completed = expectation(description: "Close finishes")
        let pending = Task {
            do { _ = try await client.send(.getState); XCTFail("Should close") }
            catch { XCTAssertEqual(error as? PiClientError, .disconnected) }
            completed.fulfill()
        }
        while transport.count == 0 { await Task.yield() }
        await client.close()
        await fulfillment(of: [completed], timeout: 1)
        await pending.value
    }
}

private final class SilentPiTransport: PiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return sent }
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {}
    func send(_ line: Data) throws { lock.lock(); defer { lock.unlock() }; sent += 1 }
    func close() {}
}
