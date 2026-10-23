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

final class AlwaysAllowTests: XCTestCase {
    func testDialogOffersAlwaysAndTheAnswerSaysSo() throws {
        let line = Data(#"{"type":"extension_ui_request","id":"approval-7","method":"confirm","title":"Allow bash?","always":"Always allow npm commands"}"#.utf8)
        guard case .dialog(let dialog) = try PiRecord.parse(line) else { return XCTFail("not a dialog") }
        XCTAssertEqual(dialog.alwaysLabel, "Always allow npm commands")
        XCTAssertEqual(PiDialogAnswer.alwaysAllow.json(dialogID: "approval-7"),
                       ["type": "extension_ui_response", "id": "approval-7", "confirmed": true, "always": true])
        let state = try JSONValue.decode(Data(#"{"alwaysAllow": ["bash:npm", "phone_location"]}"#.utf8))
        XCTAssertEqual(PiAgentConfig(state: state).alwaysAllow, ["bash:npm", "phone_location"])
    }
}
