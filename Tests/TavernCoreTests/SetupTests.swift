import XCTest
@testable import TavernCore

/// Settings' roster saving and pi-bundle agent discovery. Names and hosts are made up.
final class SetupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveKeepsKeysTavernDoesNotModel() throws {
        let url = dir.appendingPathComponent("roster.json")
        try Data("""
        {"partyName": "Guild", "theme": "night", "mailProjects": [],
         "members": [{"id": "scout", "name": "Scout", "kind": "pi", "avatarColor": "#3d7a5a", "skills": [],
                      "summary": "old", "pet": "owl"}]}
        """.utf8).write(to: url)
        var roster = Roster.load(from: url)
        roster.partyName = "Smithery"
        roster.members[0].name = "Scout II"
        roster.members[0].summary = nil
        roster.members.append(RosterMember(id: "sage", name: "Sage", kind: .hosted, avatarColor: "#4b4b8f"))
        try RosterFile.save(roster, to: url)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "night")
        XCTAssertEqual(json["partyName"] as? String, "Smithery")
        let members = try XCTUnwrap(json["members"] as? [[String: Any]])
        XCTAssertEqual(members.map { $0["id"] as? String }, ["scout", "sage"])
        XCTAssertEqual(members[0]["pet"] as? String, "owl")
        XCTAssertEqual(members[0]["name"] as? String, "Scout II")
        XCTAssertNil(members[0]["summary"], "a cleared field leaves the file")
        XCTAssertEqual(Roster.load(from: url), roster)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".before-settings"))
    }

    func testSaveCreatesTheFileOnFirstLaunch() throws {
        let url = dir.appendingPathComponent("Tavern/roster.json")
        try RosterFile.save(Roster(members: [], mailProjects: [], partyName: "Guild"), to: url)
        XCTAssertEqual(Roster.load(from: url).partyName, "Guild")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".before-settings"))
    }

    func testSaveRefusesAFileItCannotRead() throws {
        let url = dir.appendingPathComponent("roster.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try RosterFile.save(Roster.fallback, to: url))
        XCTAssertEqual(try String(contentsOf: url), "{ not json")
        XCTAssertThrowsError(try Roster.loadFile(from: url))
        XCTAssertNil(try Roster.loadFile(from: dir.appendingPathComponent("missing.json")))
    }

    func testNewMemberIDsAreUnique() {
        let roster = Roster(members: [RosterMember(id: "newagent", name: "New Agent", kind: .pi, avatarColor: "#000000")], mailProjects: [])
        XCTAssertEqual(roster.newMemberID(for: "New Agent"), "newagent2")
        XCTAssertEqual(roster.newMemberID(for: "Émber!"), "mber")
        XCTAssertEqual(roster.newMemberID(for: "🔥"), "member")
    }

    func testReadsCardsOnThisMac() async throws {
        let config = dir.appendingPathComponent(".config/pi-bundle")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("second"), withIntermediateDirectories: true)
        try Data("""
        {"id": "ember", "name": "Ember", "host": "M3", "port": 19011, "model": "anthropic/claude-sonnet-4-6",
         "avatar": "ember.png", "avatarColor": "#b4532a"}
        """.utf8).write(to: config.appendingPathComponent("agents/ember.json"))
        // An older install's roster entry for the same agent: the card wins.
        try Data(##"{"id": "ember", "name": "Old Ember", "kind": "pi", "avatarColor": "#000000", "piEndpoint": {"kind": "tcp", "host": "127.0.0.1", "port": 1}}"##.utf8)
            .write(to: config.appendingPathComponent("roster-member.json"))
        try Data(##"{"id": "cipher", "name": "Cipher", "kind": "pi", "host": "Work Mac", "avatarColor": "#191970", "piEndpoint": {"kind": "tcp", "host": "127.0.0.1", "port": 19012}}"##.utf8)
            .write(to: config.appendingPathComponent("second/roster-member.json"))

        let found = await AgentDiscovery.local(home: dir)
        XCTAssertEqual(found.map(\.id), ["ember", "cipher"])
        XCTAssertEqual(found[0].card.name, "Ember")
        XCTAssertEqual(found[0].avatarPath, config.appendingPathComponent("agents/ember.png").path)
        XCTAssertEqual(found[1].card.loopbackPort, 19012)
        XCTAssertEqual(found[0].machine, "This Mac")

        let member = found[1].member()
        XCTAssertEqual(member.piEndpoint, .tcp(host: "127.0.0.1", port: 19012))
        XCTAssertEqual(member.tailscaleName, "self")
        XCTAssertEqual(member.avatarColor, "#191970")
        XCTAssertEqual(member.host, "Work Mac")
    }

    func testParsesRemoteCardsAndBuildsAnSSHEndpoint() throws {
        let output = """
        --- /home/me/.config/pi-bundle/agents/tally.json
        {"id": "tally", "name": "Tally", "host": "server-a", "port": 19011, "socat": "socat"}

        --- /home/me/.config/pi-bundle/roster-member.json
        {"id": "tally", "name": "Tally", "kind": "pi", "avatarColor": "#000"}

        """
        let parsed = AgentDiscovery.parse(output)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(AgentDiscovery.parse("--- /x\n{\"id\": \"../evil\", \"name\": \"E\"}\n").isEmpty)
        let agent = DiscoveredAgent(card: parsed[0].card, place: .ssh(host: "server-a"), cardPath: parsed[0].path)
        XCTAssertEqual(agent.machine, "server-a")
        let member = agent.member()
        XCTAssertEqual(member.piEndpoint, .ssh(host: "server-a", port: 19011, socat: "socat"))
        XCTAssertEqual(member.piEndpoint?.summary, "SSH to server-a, port 19011")
        XCTAssertEqual(member.tailscaleName, "server-a")
        XCTAssertTrue(AgentDiscovery.remoteScript.contains("$HOME/.config/pi-bundle/agents/*.json"))
    }

    func testSSHCandidatesAreOnlineMacsAndLinuxBoxes() throws {
        let status = TailscaleStatus(backendState: "Running", nodes: [
            TailscaleNode(hostName: "m5", dnsName: "m5.tail0.ts.net", os: "macOS", online: true, isSelf: true),
            TailscaleNode(hostName: "server-a", dnsName: "server-a.tail0.ts.net", os: "linux", online: true),
            TailscaleNode(hostName: "Pauls-Own-Mac", dnsName: "laptop-b.tail0.ts.net", os: "macOS", online: true),
            TailscaleNode(hostName: "phone", dnsName: "phone.tail0.ts.net", os: "iOS", online: true),
            TailscaleNode(hostName: "old", dnsName: "old.tail0.ts.net", os: "linux", online: false),
            TailscaleNode(hostName: "-oProxyCommand=touch x", os: "linux", online: true),
        ])
        XCTAssertEqual(AgentDiscovery.sshCandidates(in: status), ["server-a", "laptop-b"])
        XCTAssertEqual(AgentDiscovery.sshCandidates(in: TailscaleStatus(backendState: "Stopped", nodes: status.nodes)), [])
        XCTAssertEqual(AgentDiscovery.sshCandidates(in: nil), [])
    }

    func testEndpointHelpersRoundTrip() {
        let ssh = PiEndpoint.ssh(host: "box", port: 19012)
        XCTAssertEqual(ssh.sshTarget?.host, "box")
        XCTAssertEqual(ssh.sshTarget?.port, 19012)
        XCTAssertEqual(ssh.sshTarget?.socat, PiEndpoint.defaultSocat)
        XCTAssertNil(ssh.localPort)
        XCTAssertEqual(PiEndpoint.tcp(host: "127.0.0.1", port: 19011).localPort, 19011)
        XCTAssertNil(PiEndpoint.tcp(host: "box", port: 19011).localPort)
        // pi-bundle's older roster-member-ssh.json shape still reads as SSH.
        let older = PiEndpoint.command(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "m3",
                                        "/opt/homebrew/bin/socat - TCP:127.0.0.1:19011"])
        XCTAssertEqual(older.sshTarget?.host, "m3")
        XCTAssertEqual(older.sshTarget?.socat, "/opt/homebrew/bin/socat")
        XCTAssertNil(PiEndpoint.command(["/usr/bin/env", "pi", "--mode", "rpc"]).sshTarget)
        // Options Settings can't rebuild keep the command Custom.
        XCTAssertNil(PiEndpoint.command(["/usr/bin/ssh", "-p", "2222", "-T", "-o", "BatchMode=yes", "box", "socat - TCP:127.0.0.1:19011"]).sshTarget)
        XCTAssertNil(PiEndpoint.command(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-i", "key", "box",
                                         "socat - TCP:127.0.0.1:19011"]).sshTarget)
    }
}
