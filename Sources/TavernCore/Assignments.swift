import Foundation

/// An issue the user handed to a Pi agent from Tavern. Kept on this Mac only: Linear stays
/// read-only, so "assigned" means "Tavern sent it", plus any `agent:<name>` label in Linear.
public struct TaskAssignment: Codable, Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var url: URL?
    public var agentID: String
    public var sentAt: Date
    /// the user cleared the "finished" notice for this task.
    public var acknowledged: Bool?

    public init(identifier: String, title: String, url: URL?, agentID: String, sentAt: Date = Date()) {
        self.identifier = identifier
        self.title = title
        self.url = url
        self.agentID = agentID
        self.sentAt = sentAt
    }
}

/// One row in an agent's task list.
public struct AgentTask: Equatable, Identifiable, Sendable {
    public var id: String { identifier }
    public var identifier: String
    public var title: String
    public var url: URL?
    /// Linear's state name, or nil when the issue is no longer open (done or canceled).
    public var state: String?
    public var sentAt: Date?
    public var fromLabel: Bool
    public var acknowledged = false

    /// Sent from Tavern, closed in Linear since, and not yet cleared: worth telling the user.
    public var isNewlyFinished: Bool { !fromLabel && state == nil && !acknowledged }
}

public struct AssignmentStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL? {
        TavernPaths.file("assignments.json")
    }

    public func load() -> [TaskAssignment] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaskAssignment].self, from: data)) ?? []
    }

    /// Adds or moves an issue to `agentID`; an issue has one agent at a time.
    public func record(_ assignment: TaskAssignment) throws -> [TaskAssignment] {
        var all = load().filter { $0.identifier != assignment.identifier }
        all.append(assignment)
        try save(all)
        return all
    }

    /// Marks a finished task as seen, so it leaves Needs you.
    public func acknowledge(_ identifier: String) throws -> [TaskAssignment] {
        var all = load()
        for index in all.indices where all[index].identifier == identifier { all[index].acknowledged = true }
        try save(all)
        return all
    }

    private func save(_ all: [TaskAssignment]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    /// The agent's tasks: what Tavern sent (newest first), then open issues labelled `agent:<name>`.
    public static func tasks(for agent: RosterMember, assignments: [TaskAssignment], openIssues: [LinearIssue]) -> [AgentTask] {
        let open = Dictionary(openIssues.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        var tasks = assignments.filter { $0.agentID == agent.id }
            .sorted { $0.sentAt > $1.sentAt }
            .map { AgentTask(identifier: $0.identifier, title: $0.title, url: $0.url,
                             state: openIssues.isEmpty ? "Open" : open[$0.identifier]?.state, sentAt: $0.sentAt, fromLabel: false,
                             acknowledged: $0.acknowledged ?? false) }
        let names = [agent.id.lowercased(), agent.name.lowercased()]
        for issue in openIssues where names.contains(issue.owner?.lowercased() ?? "") && !tasks.contains(where: { $0.identifier == issue.identifier }) {
            tasks.append(AgentTask(identifier: issue.identifier, title: issue.title, url: issue.url,
                                   state: issue.state, sentAt: nil, fromLabel: true))
        }
        return tasks
    }
}
