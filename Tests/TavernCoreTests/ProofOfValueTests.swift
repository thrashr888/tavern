import Foundation
import XCTest
@testable import TavernCore

final class ProofOfValueTests: XCTestCase {
    private func pi(_ id: String, agent: String = "flint", kind: String, at date: Date, _ message: JSONValue) -> TavernEvent {
        TavernEvent(source: EventSource.pi, sourceID: id, threadKey: "pi:\(agent)", authorAgent: agent, sourceTS: date,
                    receivedTS: date, kind: kind, payload: (try? JSONValue.object(["id": .string(id), "message": message]).encoded()) ?? Data())
    }

    func testCountsTurnsSpendToolsShippedAndApprovals() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pov-\(UUID()).sqlite").path
        let store = try EventStore(path: path)
        // Midday, so "today" holds every event below whatever time the test runs.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let call: JSONValue = ["role": "assistant", "stopReason": "toolUse", "usage": ["cost": ["total": .number(0.25)]], "content": .array([
            ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "gh pr create --title \"Fix pricing\" --fill"]],
            ["type": "toolCall", "id": "c2", "name": "edit", "arguments": ["path": "src/plans.ts"]],
            ["type": "toolCall", "id": "c3", "name": "pap__run", "arguments": ["tool": "emails_create", "params": ["subject": "Re: Deploy"]]],
            ["type": "toolCall", "id": "c4", "name": "cider__weather_current", "arguments": .object([:])],
            ["type": "toolCall", "id": "c5", "name": "spellbook__spellbook_get", "arguments": ["id": "SB-21"]],
        ])]
        let reply: JSONValue = ["role": "assistant", "stopReason": "stop", "usage": ["cost": ["total": .number(0.5)]], "content": .array([["type": "text", "text": "Done."]])]
        let beat: JSONValue = ["role": "user", "content": .array([["type": "text", "text": "[Heartbeat 2026-10-21] New since the last check."]])]
        _ = try store.append([
            pi("1", kind: "pi.message.user", at: now.addingTimeInterval(-60), beat),
            pi("2", kind: "pi.message.assistant", at: now.addingTimeInterval(-50), call),
            pi("3", kind: "pi.message.assistant", at: now.addingTimeInterval(-40), reply),
            pi("4", kind: "pi.message.assistant", at: now.addingTimeInterval(-30 * 86_400), reply), // too old
            ApprovalLog.event(agentID: "flint", dialog: PiDialog(id: "approval-1", method: .confirm, title: "Allow bash?"), answer: .confirmed(true), date: now),
            ApprovalLog.event(agentID: "flint", dialog: PiDialog(id: "approval-2", method: .confirm, title: "Allow rm?"), answer: .confirmed(false), date: now),
        ])
        let pov = ProofOfValue(store: store, now: now)
        XCTAssertEqual(pov.turnsThisWeek, 1)
        XCTAssertEqual(pov.heartbeatWakes, 1)
        XCTAssertEqual(pov.spend(on: now), 0.75, accuracy: 0.0001)
        XCTAssertEqual(pov.spend(agent: "flint", on: now), 0.75, accuracy: 0.0001)
        XCTAssertEqual([pov.approved, pov.declined], [1, 1])
        XCTAssertEqual(Set(pov.shipped.map(\.kind)), [.pullRequest, .edit, .draft])
        XCTAssertEqual(pov.shipped.first { $0.kind == .pullRequest }?.title, "Fix pricing")
        XCTAssertEqual(pov.shipped.first { $0.kind == .draft }?.title, "Re: Deploy")
        XCTAssertEqual(pov.tools.map(\.name).sorted(), ["bash", "cider", "edit", "pap", "spellbook"])
        XCTAssertEqual(pov.spells, [ProofOfValue.ToolUse(name: "SB-21", count: 1)])
        XCTAssertEqual(pov.spellCasts, 1)
    }
}

final class HomeAgentTests: XCTestCase {
    func testTheLoopbackAgentIsHome() {
        let remote = RosterMember(id: "ember", name: "Ember", kind: .pi, avatarColor: "#f00", piEndpoint: .tcp(host: "100.1.2.3", port: 19011))
        let local = RosterMember(id: "flint", name: "Flint", kind: .pi, avatarColor: "#0f0", piEndpoint: .tcp(host: "127.0.0.1", port: 19011))
        XCTAssertEqual(Roster(members: [remote, local], mailProjects: []).homeAgentID, "flint")
        XCTAssertNil(Roster(members: [remote], mailProjects: []).homeAgentID)
    }
}
