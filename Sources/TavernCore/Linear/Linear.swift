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

/// Linear for Goals and search, through Personal Agent Proxy's Linear connection, with the
/// permissions set there. Writes stay limited to agent labels, new issues and edits to an issue's
/// own fields (2026-10-18); nothing deletes, archives or comments.
public actor LinearSource {
    public let teamKey: String
    private let proxy: PAPLinear
    private var cachedGoals: (date: Date, issues: [LinearIssue])?
    public var cacheLifetime: TimeInterval = 120

    public init(proxy client: PAPClient, teamKey: String) {
        self.teamKey = teamKey
        proxy = PAPLinear(client: client, teamKey: teamKey)
    }

    /// Open issues for the team (not completed or canceled), recently updated first. Cached briefly.
    public func openIssues(refresh: Bool = false) async throws -> [LinearIssue] {
        if !refresh, let cached = cachedGoals, Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.issues
        }
        let issues = try await proxy.openIssues()
        cachedGoals = (Date(), issues)
        return issues
    }

    /// Issues whose identifier, title or description matches `text`, open or not.
    public func search(_ text: String) async throws -> [LinearIssue] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await proxy.search(term)
    }

    /// One issue's description, for the Goals detail pane.
    public func detail(_ identifier: String) async throws -> LinearIssueDetail {
        try await proxy.detail(identifier)
    }

    /// A page of an issue's comments, newest first, and the cursor for the next (older) page.
    public func comments(_ identifier: String, after cursor: String? = nil, pageSize: Int = 20) async throws -> (comments: [LinearComment], next: String?) {
        try await proxy.comments(identifier, after: cursor, pageSize: pageSize)
    }

    /// Labels an issue `agent:<id>` (2026-10-18) and takes any other `agent:` label off. Other
    /// labels are left alone. The label must already exist in Linear.
    public func assignAgentLabel(issue identifier: String, agentID: String) async throws {
        try await proxy.assignAgentLabel(issue: identifier, agentID: agentID)
        cachedGoals = nil
    }

    public static func agentLabelName(_ agentID: String) -> String { "agent:\(agentID.lowercased())" }

    /// The team's statuses (Backlog, Todo, In Progress…), in board order. Ids are names.
    public func workflowStates() async throws -> [LinearState] {
        try await proxy.workflowStates()
    }

    /// Edits an issue's own fields (2026-10-18: edit tickets from Tavern). Only the fields
    /// given change; comments, assignees and other labels are never touched.
    public func updateIssue(_ identifier: String, title: String? = nil, description: String? = nil,
                            stateID: String? = nil, priority: Int? = nil, projectID: String?? = nil) async throws {
        try await proxy.updateIssue(identifier, title: title, description: description, stateID: stateID, priority: priority, projectID: projectID)
        cachedGoals = nil
    }

    /// The team's projects, for the New Ticket sheet. Ids are names.
    public func projects() async throws -> [LinearProject] {
        try await proxy.projects()
    }

    /// Files a new issue in the team (2026-10-18: Tavern may create tickets), optionally in a
    /// project and labelled for an agent. Returns its identifier and URL.
    public func createIssue(title: String, description: String, projectID: String?, agentID: String?) async throws -> (identifier: String, url: URL?) {
        cachedGoals = nil
        return try await proxy.createIssue(title: title, description: description, projectID: projectID, agentID: agentID)
    }
}
