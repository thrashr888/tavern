import Foundation
import XCTest
@testable import TavernCore

final class PiCapabilitiesTests: XCTestCase {
    func testReadsWhatTheHostReports() throws {
        let state = try JSONValue.decode(Data("""
        {"durable": true, "capabilities": {"mcp": [{"name": "cider", "tools": 29}, {"name": "pap"}],
         "docker": ["immich", "postgres"], "clis": ["gh", "git"]}}
        """.utf8))
        let caps = try XCTUnwrap(PiAgentConfig(state: state).capabilities)
        XCTAssertEqual(caps.mcp, [.init(name: "cider", tools: 29), .init(name: "pap", tools: 0)])
        XCTAssertEqual(caps.docker, ["immich", "postgres"])
        XCTAssertEqual(caps.clis, ["gh", "git"])
    }

    func testNoDockerAndOlderHosts() throws {
        let noDocker = try JSONValue.decode(Data(#"{"capabilities": {"mcp": [], "docker": null, "clis": ["git"]}}"#.utf8))
        XCTAssertNil(PiAgentConfig(state: noDocker).capabilities?.docker)
        XCTAssertNil(PiAgentConfig(state: try JSONValue.decode(Data(#"{"durable": true}"#.utf8))).capabilities)
    }
}
