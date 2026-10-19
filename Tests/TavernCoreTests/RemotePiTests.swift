import Network
import XCTest
@testable import TavernCore

final class PiEndpointTests: XCTestCase {
    func testEndpointsRoundTripThroughRosterJSON() throws {
        let json = Data("""
        {
          "members": [
            {"id": "tally", "name": "Tally", "kind": "pi", "host": "SER8", "skills": [], "avatarColor": "#2f7d4f",
             "tailscaleName": "ser8",
             "piEndpoint": {"kind": "command", "argv": ["/usr/bin/ssh", "-T", "ser8", "socat - UNIX-CONNECT:/run/pi.sock"]}},
            {"id": "ember", "name": "Ember", "kind": "pi", "host": "M3", "skills": [], "avatarColor": "#b4532a",
             "piEndpoint": {"kind": "tcp", "host": "laptop-b", "port": 19002}},
            {"id": "flint", "name": "Flint", "kind": "pi", "host": "M5", "skills": [], "avatarColor": "#5b6470",
             "piLaunch": ["/usr/bin/env", "pi", "--mode", "rpc"]}
          ],
          "mailProjects": []
        }
        """.utf8)
        let roster = try JSONDecoder().decode(Roster.self, from: json)

        let tally = try XCTUnwrap(roster.member(id: "tally")?.endpoint)
        XCTAssertEqual(tally, .command(["/usr/bin/ssh", "-T", "ser8", "socat - UNIX-CONNECT:/run/pi.sock"]))
        XCTAssertTrue(tally.isRemote)
        XCTAssertEqual(tally.summary, "SSH to ser8")
        XCTAssertEqual(PiEndpoint.command(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "server-a", "socat - TCP:127.0.0.1:19011"]).summary,
                       "SSH to server-a, port 19011")

        let ember = try XCTUnwrap(roster.member(id: "ember")?.endpoint)
        XCTAssertEqual(ember, .tcp(host: "laptop-b", port: 19002))
        XCTAssertEqual(ember.summary, "tcp laptop-b:19002")

        // Older rosters with only piLaunch still work.
        let flint = try XCTUnwrap(roster.member(id: "flint")?.endpoint)
        XCTAssertEqual(flint, .command(["/usr/bin/env", "pi", "--mode", "rpc"]))
        XCTAssertFalse(flint.isRemote)

        let reencoded = try JSONDecoder().decode(Roster.self, from: JSONEncoder().encode(roster))
        XCTAssertEqual(reencoded, roster)
    }

    func testRemoteAgentsHaveNoEndpointUntilConfigured() {
        XCTAssertNil(Roster.fixture.member(id: "tally")?.endpoint)
        XCTAssertNil(Roster.fixture.member(id: "ember")?.endpoint)
    }
}

@MainActor
final class PiReconnectTests: XCTestCase {
    func testReconnectsAfterStreamDropsWithoutDuplicates() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1", "e2"])
        let session = PiAgentSession(agentID: "tally", store: store) { pi }
        session.backoff = { _ in .milliseconds(10) }
        await session.connect()
        XCTAssertEqual(session.presence, .idle)

        pi.entryIDs.append("e3")
        pi.drop()
        try await waitUntil { session.presence == .idle && session.transcript.count == 3 }
        XCTAssertEqual(try store.eventCount(), 3)
        XCTAssertEqual(pi.lastSince, "e2")
    }

    func testFailedConnectBacksOffThenSucceeds() async throws {
        let store = try EventStore(path: ":memory:")
        let pi = FakePi(sessionID: "s1", entryIDs: ["e1"])
        var failuresLeft = 2
        let session = PiAgentSession(agentID: "tally", store: store) {
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw PiTransportError.notRunning
            }
            return pi
        }
        var delays: [Int] = []
        session.backoff = { attempt in
            delays.append(attempt)
            return .milliseconds(10)
        }
        await session.connect()
        XCTAssertEqual(session.presence, .reconnecting)
        XCTAssertNotNil(session.lastConnectError)
        try await waitUntil { session.presence == .idle }
        XCTAssertEqual(delays, [1, 2])
        XCTAssertNil(session.lastConnectError)
    }

    func testUserDisconnectStopsReconnecting() async throws {
        let store = try EventStore(path: ":memory:")
        let session = PiAgentSession(agentID: "tally", store: store) { throw PiTransportError.notRunning }
        session.backoff = { _ in .milliseconds(10) }
        await session.connect()
        await session.disconnect()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(session.presence, .disconnected)
    }

    func testNoAutoReconnectReportsFailure() async throws {
        let store = try EventStore(path: ":memory:")
        let session = PiAgentSession(agentID: "tally", store: store) { throw PiTransportError.notRunning }
        session.autoReconnect = false
        await session.connect()
        guard case .failed = session.presence else { return XCTFail("expected failed, got \(session.presence)") }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class PiTCPTransportTests: XCTestCase {
    /// A one-connection RPC server on localhost that answers get_state.
    func testRoundTripOverTCP() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.listener")
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data, let command = try? JSONValue.decode(data.prefix { $0 != 0x0A }) else { return }
                let reply: JSONValue = [
                    "id": command["id"] ?? .null, "type": "response", "command": "get_state", "success": true,
                    "data": ["sessionId": "tcp-session", "isStreaming": false],
                ]
                let bytes = (try? reply.encoded()) ?? Data()
                // Split the record across two writes to exercise framing.
                connection.send(content: bytes.prefix(10), completion: .idempotent)
                connection.send(content: bytes.dropFirst(10) + Data([0x0A]), completion: .idempotent)
            }
        }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        defer { listener.cancel() }

        let client = PiClient(transport: PiTCPTransport(host: "127.0.0.1", port: port))
        try await client.start()
        let response = try await client.send(.getState)
        XCTAssertEqual(response.data?["sessionId"]?.stringValue, "tcp-session")
        await client.close()
    }

    func testRefusedPortCloses() async throws {
        // Grab a free port, then close it so nothing is listening there.
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "test.refused")
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { _ in }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        listener.cancel()

        let closed = expectation(description: "closed")
        let transport = PiTCPTransport(host: "127.0.0.1", port: port)
        try transport.start(onLine: { _ in }, onClose: { _ in closed.fulfill() })
        await fulfillment(of: [closed], timeout: 10)
    }
}
