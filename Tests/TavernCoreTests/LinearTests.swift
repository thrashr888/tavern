import XCTest
@testable import TavernCore

final class FakeLinear: LinearHTTP, @unchecked Sendable {
    var bodies: [JSONValue] = []
    var reply: JSONValue = ["data": ["issues": ["nodes": .array([
        ["identifier": "PAUL-185", "title": "Tavern plan", "url": "https://linear.app/x/issue/PAUL-185", "priority": .number(4),
         "updatedAt": "2026-10-15T06:00:00.000Z", "state": ["name": "In Progress", "type": "started"],
         "project": ["name": "Tavern"], "assignee": .null, "labels": ["nodes": .array([["name": "agent:Quill"]])]],
        ["identifier": "PAUL-150", "title": "Alchemy release", "state": ["name": "Todo", "type": "unstarted"],
         "project": ["name": "Alchemy"], "assignee": ["name": "Paul"], "labels": ["nodes": .array([])]],
    ])]]]

    func post(_ body: Data) async throws -> (Data, Int) {
        bodies.append(try JSONValue.decode(body))
        return (try reply.encoded(), 200)
    }
}

final class LinearTests: XCTestCase {
    func testOpenIssuesParseAndCache() async throws {
        let http = FakeLinear()
        let linear = LinearSource(http: http)
        let issues = try await linear.openIssues()
        XCTAssertEqual(issues.map(\.identifier), ["PAUL-185", "PAUL-150"])
        XCTAssertEqual(issues.first?.project, "Tavern")
        XCTAssertEqual(issues.first?.owner, "Quill")
        XCTAssertEqual(issues.last?.owner, "Paul")
        XCTAssertEqual(issues.first?.state, "In Progress")

        _ = try await linear.openIssues()
        XCTAssertEqual(http.bodies.count, 1, "second call is served from cache")
        XCTAssertEqual(http.bodies.first?["variables"]?["team"], "TEAM")
    }

    func testOnlyQueriesAreSent() async throws {
        let http = FakeLinear()
        let linear = LinearSource(http: http)
        _ = try await linear.search("plan")
        for body in http.bodies {
            XCTAssertTrue(body["query"]?.stringValue?.hasPrefix("query") == true)
            XCTAssertFalse(body["query"]?.stringValue?.contains("mutation") == true)
        }
        do {
            _ = try await linear.run("mutation { issueDelete(id: \"x\") { success } }", variables: [:])
            XCTFail("a mutation was sent")
        } catch let error as LinearError {
            XCTAssertEqual(error, .notReadOnly)
        }
    }

    func testGraphQLErrorsSurface() async throws {
        let http = FakeLinear()
        http.reply = ["errors": .array([["message": "Authentication required"]])]
        do {
            _ = try await LinearSource(http: http).openIssues()
            XCTFail("expected an error")
        } catch let error as LinearError {
            XCTAssertEqual(error, .graphQL("Authentication required"))
        }
    }

    func testMissingKeyFileMeansNoSource() {
        XCTAssertNil(LinearSource.live(teamKey: "TEAM", keyURL: URL(fileURLWithPath: "/nonexistent/linear-key")))
    }
}

/// Replies by GraphQL operation: the assign lookup, then each allowed mutation.
final class ScriptedLinear: LinearHTTP, @unchecked Sendable {
    var sent: [String] = []
    func post(_ body: Data) async throws -> (Data, Int) {
        let json = try JSONValue.decode(body)
        let query = json["query"]?.stringValue ?? ""
        sent.append(query.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "(").first ?? "")
        let reply: JSONValue
        if query.contains("query Assign") {
            reply = ["data": ["issue": ["id": "uuid-1", "team": ["id": "team-1"],
                                         "labels": ["nodes": .array([["id": "L-old", "name": "agent:quill"], ["id": "L-bug", "name": "bug"]])]],
                              "issueLabels": ["nodes": .array([])]]]
        } else if query.contains("query Team") {
            reply = ["data": ["teams": ["nodes": .array([["id": "team-1"]])]]]
        } else if query.contains("issueCreate(") {
            reply = ["data": ["issueCreate": ["success": true, "issue": ["identifier": "PAUL-1", "url": "https://linear.app/x/issue/PAUL-1"]]]]
        } else if query.contains("issueLabelCreate") {
            reply = ["data": ["issueLabelCreate": ["success": true, "issueLabel": ["id": "L-new"]]]]
        } else {
            reply = ["data": [:]]
        }
        return (try reply.encoded(), 200)
    }
}

final class LinearAssignTests: XCTestCase {
    func testAssignCreatesSwapsAndTouchesNothingElse() async throws {
        let http = ScriptedLinear()
        try await LinearSource(http: http).assignAgentLabel(issue: "PAUL-1", agentID: "Ember")
        XCTAssertEqual(http.sent, ["query Assign", "mutation issueLabelCreate", "mutation issueRemoveLabel", "mutation issueAddLabel"])
    }

    func testCreateIssueThenLabels() async throws {
        let http = ScriptedLinear()
        let created = try await LinearSource(http: http).createIssue(title: "T", description: "D", projectID: "p1", agentID: "ember")
        XCTAssertEqual(created.identifier, "PAUL-1")
        XCTAssertEqual(http.sent.prefix(2), ["query Team", "mutation issueCreate"])
        XCTAssertTrue(http.sent.contains("mutation issueAddLabel"))
    }

    func testUpdateSendsOnlyGivenFields() async throws {
        let http = ScriptedLinear()
        try await LinearSource(http: http).updateIssue("PAUL-1", priority: 2)
        XCTAssertEqual(http.sent, ["mutation issueUpdate"])
    }

    func testOtherMutationsAreRefused() async throws {
        do {
            _ = try await LinearSource(http: ScriptedLinear()).mutate("issueDelete", "mutation issueDelete($id: String!) { issueDelete(id: $id) { success } }", variables: [:])
            XCTFail("sent a disallowed mutation")
        } catch let error as LinearError {
            XCTAssertEqual(error, .notReadOnly)
        }
    }
}
