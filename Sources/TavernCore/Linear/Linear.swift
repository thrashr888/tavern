import Foundation

/// An open Linear issue, as the Goals page and ⌘K show it. Read-only.
public struct LinearIssue: Equatable, Identifiable, Sendable {
    public var id: String { identifier }
    public var identifier: String
    public var title: String
    public var url: URL?
    public var state: String
    public var stateType: String
    public var project: String?
    public var assignee: String?
    public var labels: [String]
    public var priority: Int
    public var updatedAt: Date?

    public init(identifier: String, title: String, url: URL? = nil, state: String, stateType: String = "started",
                project: String? = nil, assignee: String? = nil, labels: [String] = [], priority: Int = 0,
                updatedAt: Date? = nil) {
        self.identifier = identifier
        self.title = title
        self.url = url
        self.state = state
        self.stateType = stateType
        self.project = project
        self.assignee = assignee
        self.labels = labels
        self.priority = priority
        self.updatedAt = updatedAt
    }

    init?(json: JSONValue) {
        guard let identifier = json["identifier"]?.stringValue, let title = json["title"]?.stringValue else { return nil }
        self.init(
            identifier: identifier,
            title: title,
            url: json["url"]?.stringValue.flatMap(URL.init(string:)),
            state: json["state"]?["name"]?.stringValue ?? "",
            stateType: json["state"]?["type"]?.stringValue ?? "",
            project: json["project"]?["name"]?.stringValue,
            assignee: json["assignee"]?["name"]?.stringValue,
            labels: json["labels"]?["nodes"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [],
            priority: Int(json["priority"]?.doubleValue ?? 0),
            updatedAt: PiEntries.parseTimestamp(json["updatedAt"]?.stringValue)
        )
    }

    /// The owning agent, from an `agent:<name>` label or the assignee, for grouping Goals by owner.
    public var owner: String? {
        if let label = labels.first(where: { $0.lowercased().hasPrefix("agent:") }) {
            return String(label.dropFirst("agent:".count)).trimmingCharacters(in: .whitespaces)
        }
        return assignee
    }
}

public struct LinearState: Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var position: Double
}

public struct LinearProject: Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: String
}

public struct LinearComment: Equatable, Sendable {
    public var author: String
    public var body: String
    public var date: Date?
}

public struct LinearIssueDetail: Equatable, Sendable {
    public var description: String
    public var comments: [LinearComment]
}

extension LinearIssue {
    /// The message Tavern prefills when the user hands this issue to a Pi agent.
    public func agentPrompt(description: String) -> String {
        var lines = ["Please work on \(identifier): \(title)"]
        if let url { lines.append(url.absoluteString) }
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append("\n" + body) }
        lines.append("\nTell me your plan before making changes outside your workspace.")
        return lines.joined(separator: "\n")
    }
}

/// Sends one GraphQL request and returns the response body and HTTP status.
public protocol LinearHTTP: Sendable {
    func post(_ body: Data) async throws -> (Data, Int)
}

public enum LinearError: Error, Equatable, CustomStringConvertible {
    case noKey
    case notReadOnly
    case http(Int)
    case graphQL(String)

    public var description: String {
        switch self {
        case .noKey: return "No Linear key at ~/.config/linear-key"
        case .notReadOnly: return "Tavern only reads Linear, apart from agent: labels"
        case .http(let status): return "Linear answered HTTP \(status)"
        case .graphQL(let message): return "Linear: \(message)"
        }
    }
}

/// Read-only Linear for Goals and search (2026-10-15 05:12): uses the existing key at
/// `~/.config/linear-key`, sends queries only, never mutations. Agents do their own Linear writes.
public actor LinearSource {
    public let teamKey: String
    private let http: LinearHTTP
    private var cachedGoals: (date: Date, issues: [LinearIssue])?
    public var cacheLifetime: TimeInterval = 120

    public init(http: LinearHTTP, teamKey: String = "TEAM") {
        self.http = http
        self.teamKey = teamKey
    }

    /// The live source, or nil when this Mac has no key file.
    public static func live(teamKey: String, keyURL: URL = LinearSource.defaultKeyURL) -> LinearSource? {
        guard let key = try? String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return LinearSource(http: LinearURLSessionHTTP(key: key), teamKey: teamKey)
    }

    public static var defaultKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/linear-key")
    }

    static let fields = "identifier title url priority updatedAt state { name type } project { name } assignee { name } labels { nodes { name } }"

    /// Open issues for the team (not completed or canceled), recently updated first. Cached briefly.
    public func openIssues(refresh: Bool = false) async throws -> [LinearIssue] {
        if !refresh, let cached = cachedGoals, Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.issues
        }
        let query = """
            query Goals($team: String!) {
              issues(first: 250, orderBy: updatedAt,
                     filter: { team: { key: { eq: $team } }, state: { type: { nin: ["completed", "canceled"] } } }) {
                nodes { \(Self.fields) }
              }
            }
            """
        let issues = try await run(query, variables: ["team": .string(teamKey)])
        cachedGoals = (Date(), issues)
        return issues
    }

    /// Issues whose identifier, title or description matches `text`, open or not.
    public func search(_ text: String) async throws -> [LinearIssue] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let query = """
            query Search($team: String!, $term: String!) {
              issues(first: 20, orderBy: updatedAt,
                     filter: { team: { key: { eq: $team } },
                               or: [{ title: { containsIgnoreCase: $term } }, { description: { containsIgnoreCase: $term } }] }) {
                nodes { \(Self.fields) }
              }
            }
            """
        var issues = try await run(query, variables: ["team": .string(teamKey), "term": .string(term)])
        // "PAUL-185" matches by identifier, which the title filter can't see.
        if let exact = (try? await openIssues())?.first(where: { $0.identifier.caseInsensitiveCompare(term) == .orderedSame }),
           !issues.contains(exact) {
            issues.insert(exact, at: 0)
        }
        return issues
    }

    /// One issue's description, for the Goals detail pane.
    public func detail(_ identifier: String) async throws -> LinearIssueDetail {
        let json = try await runRaw("""
            query Issue($id: String!) { issue(id: $id) { description } }
            """, variables: ["id": .string(identifier)])
        return LinearIssueDetail(description: json["data"]?["issue"]?["description"]?.stringValue ?? "", comments: [])
    }

    /// A page of an issue's comments, newest first, and the cursor for the next (older) page.
    public func comments(_ identifier: String, after cursor: String? = nil, pageSize: Int = 20) async throws -> (comments: [LinearComment], next: String?) {
        var variables: [String: JSONValue] = ["id": .string(identifier), "first": .number(Double(pageSize))]
        if let cursor { variables["after"] = .string(cursor) }
        let json = try await runRaw("""
            query Comments($id: String!, $first: Int!, $after: String) {
              issue(id: $id) {
                comments(first: $first, after: $after, orderBy: createdAt) {
                  nodes { body createdAt user { name } botActor { name } }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
            """, variables: variables)
        let page = json["data"]?["issue"]?["comments"]
        let comments = (page?["nodes"]?.arrayValue ?? []).compactMap { node -> LinearComment? in
            guard let body = node["body"]?.stringValue else { return nil }
            return LinearComment(author: node["user"]?["name"]?.stringValue ?? node["botActor"]?["name"]?.stringValue ?? "Someone",
                                 body: body, date: PiEntries.parseTimestamp(node["createdAt"]?.stringValue))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let more = page?["pageInfo"]?["hasNextPage"]?.boolValue == true
        return (comments, more ? page?["pageInfo"]?["endCursor"]?.stringValue : nil)
    }

    /// Labels an issue `agent:<id>` (2026-10-18) and takes any other `agent:` label off,
    /// creating the label the first time an agent gets one. Other labels are left alone.
    public func assignAgentLabel(issue identifier: String, agentID: String) async throws {
        let name = Self.agentLabelName(agentID)
        let lookup = try await runRaw("""
            query Assign($id: String!, $name: String!) {
              issue(id: $id) { id team { id } labels { nodes { id name } } }
              issueLabels(filter: { name: { eqIgnoreCase: $name } }) { nodes { id name team { id } } }
            }
            """, variables: ["id": .string(identifier), "name": .string(name)])
        guard let issueID = lookup["data"]?["issue"]?["id"]?.stringValue,
              let teamID = lookup["data"]?["issue"]?["team"]?["id"]?.stringValue else { throw LinearError.graphQL("No issue \(identifier)") }
        let candidates = lookup["data"]?["issueLabels"]?["nodes"]?.arrayValue ?? []
        // A team label wins over a workspace one with the same name.
        let existing = candidates.first { $0["team"]?["id"]?.stringValue == teamID } ?? candidates.first { $0["team"] == nil || $0["team"] == .null }
        var labelID = existing?["id"]?.stringValue
        if labelID == nil {
            let created = try await mutate("issueLabelCreate", """
                mutation issueLabelCreate($name: String!, $team: String!) {
                  issueLabelCreate(input: { name: $name, teamId: $team, color: "#8a5a9e" }) { success issueLabel { id } }
                }
                """, variables: ["name": .string(name), "team": .string(teamID)])
            labelID = created["data"]?["issueLabelCreate"]?["issueLabel"]?["id"]?.stringValue
        }
        guard let labelID else { throw LinearError.graphQL("Couldn't find or create \(name)") }
        let current = lookup["data"]?["issue"]?["labels"]?["nodes"]?.arrayValue ?? []
        for label in current {
            guard let id = label["id"]?.stringValue, id != labelID,
                  label["name"]?.stringValue?.lowercased().hasPrefix("agent:") == true else { continue }
            _ = try await mutate("issueRemoveLabel", """
                mutation issueRemoveLabel($id: String!, $label: String!) { issueRemoveLabel(id: $id, labelId: $label) { success } }
                """, variables: ["id": .string(issueID), "label": .string(id)])
        }
        if !current.contains(where: { $0["id"]?.stringValue == labelID }) {
            _ = try await mutate("issueAddLabel", """
                mutation issueAddLabel($id: String!, $label: String!) { issueAddLabel(id: $id, labelId: $label) { success } }
                """, variables: ["id": .string(issueID), "label": .string(labelID)])
        }
        cachedGoals = nil
    }

    public static func agentLabelName(_ agentID: String) -> String { "agent:\(agentID.lowercased())" }

    /// The team's workflow states (Backlog, Todo, In Progress…), in board order.
    public func workflowStates() async throws -> [LinearState] {
        let json = try await runRaw("""
            query States($team: String!) {
              workflowStates(filter: { team: { key: { eq: $team } } }) { nodes { id name type position } }
            }
            """, variables: ["team": .string(teamKey)])
        return (json["data"]?["workflowStates"]?["nodes"]?.arrayValue ?? []).compactMap { node in
            guard let id = node["id"]?.stringValue, let name = node["name"]?.stringValue else { return nil }
            return LinearState(id: id, name: name, type: node["type"]?.stringValue ?? "", position: node["position"]?.doubleValue ?? 0)
        }
        .sorted { $0.position < $1.position }
    }

    /// Edits an issue's own fields (2026-10-18: edit tickets from Tavern). Only the fields
    /// given change; comments, assignees and other labels are never touched.
    public func updateIssue(_ identifier: String, title: String? = nil, description: String? = nil,
                            stateID: String? = nil, priority: Int? = nil, projectID: String?? = nil) async throws {
        var input: [String: JSONValue] = [:]
        if let title { input["title"] = .string(title) }
        if let description { input["description"] = .string(description) }
        if let stateID { input["stateId"] = .string(stateID) }
        if let priority { input["priority"] = .number(Double(priority)) }
        if let projectID { input["projectId"] = projectID.map(JSONValue.string) ?? .null }
        guard !input.isEmpty else { return }
        _ = try await mutate("issueUpdate", """
            mutation issueUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }
            """, variables: ["id": .string(identifier), "input": .object(input)])
        cachedGoals = nil
    }

    /// The team's projects, for the New Ticket sheet.
    public func projects() async throws -> [LinearProject] {
        let json = try await runRaw("""
            query Projects($team: String!) {
              teams(filter: { key: { eq: $team } }) { nodes { id projects(first: 100) { nodes { id name state } } } }
            }
            """, variables: ["team": .string(teamKey)])
        let nodes = json["data"]?["teams"]?["nodes"]?.arrayValue?.first?["projects"]?["nodes"]?.arrayValue ?? []
        return nodes.compactMap { node in
            guard let id = node["id"]?.stringValue, let name = node["name"]?.stringValue else { return nil }
            return LinearProject(id: id, name: name, state: node["state"]?.stringValue ?? "")
        }
        .filter { !["completed", "canceled"].contains($0.state) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Files a new issue in the team (2026-10-18: Tavern may create tickets), optionally in a
    /// project and labelled for an agent. Returns its identifier and URL.
    public func createIssue(title: String, description: String, projectID: String?, agentID: String?) async throws -> (identifier: String, url: URL?) {
        let team = try await runRaw("""
            query Team($team: String!) { teams(filter: { key: { eq: $team } }) { nodes { id } } }
            """, variables: ["team": .string(teamKey)])
        guard let teamID = team["data"]?["teams"]?["nodes"]?.arrayValue?.first?["id"]?.stringValue else {
            throw LinearError.graphQL("No team \(teamKey)")
        }
        var input: [String: JSONValue] = ["teamId": .string(teamID), "title": .string(title), "description": .string(description)]
        if let projectID { input["projectId"] = .string(projectID) }
        let created = try await mutate("issueCreate", """
            mutation issueCreate($input: IssueCreateInput!) {
              issueCreate(input: $input) { success issue { identifier url } }
            }
            """, variables: ["input": .object(input)])
        guard let identifier = created["data"]?["issueCreate"]?["issue"]?["identifier"]?.stringValue else {
            throw LinearError.graphQL("Linear didn't return the new issue")
        }
        if let agentID { try await assignAgentLabel(issue: identifier, agentID: agentID) }
        cachedGoals = nil
        return (identifier, created["data"]?["issueCreate"]?["issue"]?["url"]?.stringValue.flatMap(URL.init(string:)))
    }

    /// Only these mutations may be sent: agent labels, new issues and edits to an issue's fields.
    /// Nothing deletes, archives or comments.
    static let allowedMutations: Set<String> = ["issueLabelCreate", "issueAddLabel", "issueRemoveLabel", "issueCreate", "issueUpdate"]

    func mutate(_ operation: String, _ mutation: String, variables: [String: JSONValue]) async throws -> JSONValue {
        guard Self.allowedMutations.contains(operation),
              mutation.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation \(operation)(") else { throw LinearError.notReadOnly }
        return try await send(mutation, variables: variables)
    }

    func run(_ query: String, variables: [String: JSONValue]) async throws -> [LinearIssue] {
        let json = try await runRaw(query, variables: variables)
        return (json["data"]?["issues"]?["nodes"]?.arrayValue ?? []).compactMap(LinearIssue.init(json:))
    }

    func runRaw(_ query: String, variables: [String: JSONValue]) async throws -> JSONValue {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("query") else { throw LinearError.notReadOnly }
        return try await send(query, variables: variables)
    }

    private func send(_ query: String, variables: [String: JSONValue]) async throws -> JSONValue {
        let body = try JSONValue.object(["query": .string(query), "variables": .object(variables)]).encoded()
        let (data, status) = try await http.post(body)
        guard status == 200 else { throw LinearError.http(status) }
        let json = try JSONValue.decode(data)
        if let message = json["errors"]?.arrayValue?.first?["message"]?.stringValue { throw LinearError.graphQL(message) }
        return json
    }
}

/// HTTPS to api.linear.app with the personal key. The key never leaves this Mac otherwise.
public struct LinearURLSessionHTTP: LinearHTTP {
    let key: String

    public func post(_ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
