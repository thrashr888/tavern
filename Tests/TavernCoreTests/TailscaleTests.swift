import XCTest
@testable import TavernCore

final class TailscaleTests: XCTestCase {
    // Trimmed `tailscale status --json` shape; names and IPs are made up.
    private let sample = Data("""
    {
      "Version": "1.90.0",
      "BackendState": "Running",
      "MagicDNSSuffix": "tail0000.ts.net",
      "CurrentTailnet": {"Name": "example.github", "MagicDNSSuffix": "tail0000.ts.net"},
      "Self": {
        "HostName": "Pauls-MacBook-Pro", "DNSName": "m5.tail0000.ts.net.", "OS": "macOS",
        "TailscaleIPs": ["100.64.0.5", "fd7a::5"], "Online": true, "LastSeen": "0001-01-01T00:00:00Z"
      },
      "Peer": {
        "nodekey:aa": {
          "HostName": "server-a", "DNSName": "server-a.tail0000.ts.net.", "OS": "linux",
          "TailscaleIPs": ["100.64.0.8"], "Online": true, "LastSeen": "2026-10-15T05:59:00Z"
        },
        "nodekey:bb": {
          "HostName": "Pauls-Own-Mac", "DNSName": "laptop-b.tail0000.ts.net.", "OS": "macOS",
          "TailscaleIPs": ["100.64.0.3"], "Online": false, "LastSeen": "2026-10-15T01:00:00Z"
        }
      }
    }
    """.utf8)

    func testParsesSelfAndPeers() throws {
        let status = try TailscaleStatus.parse(sample)
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.tailnetName, "example.github")
        XCTAssertEqual(status.nodes.count, 3)
        let me = try XCTUnwrap(status.nodes.first)
        XCTAssertTrue(me.isSelf)
        XCTAssertEqual(me.dnsName, "m5.tail0000.ts.net")
        XCTAssertEqual(me.ips.first, "100.64.0.5")
    }

    func testMatchesRosterMembersToMachines() throws {
        let status = try TailscaleStatus.parse(sample)
        let roster = Roster.fixture

        let tally = try XCTUnwrap(status.node(for: try XCTUnwrap(roster.member(id: "tally"))))
        XCTAssertEqual(tally.hostName, "server-a")
        XCTAssertTrue(tally.online)
        XCTAssertEqual(tally.url?.absoluteString, "http://server-a.tail0000.ts.net")

        // Machine names match case-insensitively.
        let ember = try XCTUnwrap(status.node(for: try XCTUnwrap(roster.member(id: "ember"))))
        XCTAssertFalse(ember.online)
        XCTAssertNotNil(ember.lastSeen)

        // "self" is the Mac Tavern runs on.
        let flint = try XCTUnwrap(status.node(for: try XCTUnwrap(roster.member(id: "flint"))))
        XCTAssertTrue(flint.isSelf)

        XCTAssertNil(status.node(named: "nowhere"))
        XCTAssertNil(status.node(named: nil))
    }

    func testStoppedClient() throws {
        let status = try TailscaleStatus.parse(Data(#"{"BackendState":"Stopped","Peer":null}"#.utf8))
        XCTAssertFalse(status.isRunning)
        XCTAssertTrue(status.nodes.isEmpty)
    }

    func testMissingCLIReportsNotInstalled() async {
        do {
            _ = try await TailscaleReader.read(paths: ["/nonexistent/tailscale"])
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? TailscaleReader.ReadError, .notInstalled)
        }
    }
}
