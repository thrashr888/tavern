import Foundation

/// Linear through Personal Agent Proxy's Linear connection, behind `LinearSource`. PAP's issue tools write teams, statuses, projects and labels by name, so here
/// a `LinearState` or `LinearProject` id is its name.
///
/// A list gives an issue's summary only (no labels or priority), so open issues are opened one by
/// one and kept until their `updated` time changes. PAP can't create a label: `agent:<id>` must
/// exist in Linear before Tavern can put it on an issue.
actor PAPLinear {
    let client: PAPClient
    let teamKey: String
    /// Opened issues by identifier, with the `updated` time they were opened at.
    private var opened: [String: (updated: String, issue: LinearIssue, description: String, comments: [LinearComment])] = [:]
    /// Statuses and projects seen on the team's issues, for the edit menus.
    private var seenStates: [String: String] = [:]
    private var seenProjects: Set<String> = []

    static let openTypes = ["Triage", "Backlog", "Unstarted", "Started"]
    static let typeOrder = ["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate"]
    static let priorities = ["No priority", "Urgent", "High", "Medium", "Low"]

    init(client: PAPClient, teamKey: String) {
        self.client = client
        self.teamKey = teamKey
    }

    private func linear() async throws -> String {
        try await client.connection("Linear", describedAs: "Linear connection").id
    }

    private func onTeam(_ identifier: String) -> Bool {
        identifier.uppercased().hasPrefix(teamKey.uppercased() + "-")
    }

    /// One page after another of `issues_list`, the team's issues only, up to `limit`.
    private func list(search: String? = nil, statusType: String? = nil, limit: Int) async throws -> [JSONValue] {
        let connection = try await linear()
        var records: [JSONValue] = []
        var page: String?
        var pages = 0
        repeat {
            var params: [String: JSONValue] = [:]
            if let search { params["search"] = .string(search) }
            if let statusType { params["statusType"] = .string(statusType) }
            if let page { params["page"] = .string(page) }
            let result = try await client.read(connection, "issues_list", params)
            records += (result["records"]?.arrayValue ?? []).filter { onTeam($0["id"]?.stringValue ?? "") }
            page = result["nextPage"]?.stringValue
            pages += 1
        } while page != nil && records.count < limit && pages < 6
        return Array(records.prefix(limit))
    }

    /// An issue from a record, summary or full.
    func issue(from record: JSONValue) -> LinearIssue? {
        guard let id = record["id"]?.stringValue, let values = record["values"] else { return nil }
        let labels = (values["labels"]?.stringValue ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let status = values["status"]?.stringValue ?? ""
        let type = (values["statusType"]?.stringValue ?? "").lowercased()
        if !status.isEmpty { seenStates[status] = type }
        let project = values["project"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let project { seenProjects.insert(project) }
        return LinearIssue(
            identifier: id,
            title: values["title"]?.stringValue ?? "",
            url: record["url"]?.stringValue.flatMap(URL.init(string:)),
            state: status,
            stateType: type,
            project: project,
            assignee: values["assignee"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            labels: labels,
            priority: Self.priorities.firstIndex(of: values["priority"]?.stringValue ?? "") ?? 0,
            updatedAt: PiEntries.parseTimestamp(values["updated"]?.stringValue ?? record["updatedAt"]?.stringValue)
        )
    }

    /// Opens an issue unless it's already open at this `updated` time.
    private func open(_ identifier: String, updated: String?) async throws -> (issue: LinearIssue, description: String, comments: [LinearComment]) {
        if let updated, let kept = opened[identifier], kept.updated == updated { return (kept.issue, kept.description, kept.comments) }
        let record = try await client.read(try await linear(), "issues_get", ["id": .string(identifier)])["record"] ?? .null
        guard let issue = issue(from: record) else { throw PAPError.tool("No issue \(identifier)") }
        let values = record["values"]
        let found = (issue, values?["description"]?.stringValue ?? "", Self.comments(values?["comments"]?.stringValue ?? ""))
        opened[identifier] = (values?["updated"]?.stringValue ?? updated ?? "", found.0, found.1, found.2)
        return found
    }

    func openIssues() async throws -> [LinearIssue] {
        var summaries: [JSONValue] = []
        for type in Self.openTypes {
            summaries += try await list(statusType: type, limit: 250)
        }
        var issues: [LinearIssue] = []
        for record in summaries {
            guard let id = record["id"]?.stringValue else { continue }
            issues.append(try await open(id, updated: record["values"]?["updated"]?.stringValue).issue)
        }
        return issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func search(_ text: String) async throws -> [LinearIssue] {
        let records = try await list(search: text, limit: 20)
        var issues = records.compactMap { issue(from: $0) }
        // "PAUL-185" is found by its identifier, which a search of titles can't see.
        if onTeam(text), !issues.contains(where: { $0.identifier.caseInsensitiveCompare(text) == .orderedSame }),
           let exact = try? await open(text.uppercased(), updated: nil).issue {
            issues.insert(exact, at: 0)
        }
        return issues
    }

    func detail(_ identifier: String) async throws -> LinearIssueDetail {
        let found = try await open(identifier, updated: nil)
        return LinearIssueDetail(description: found.description, comments: [])
    }

    /// PAP opens an issue with its latest 250 comments; pages are cut from those, newest first.
    func comments(_ identifier: String, after cursor: String?, pageSize: Int) async throws -> (comments: [LinearComment], next: String?) {
        let all = try await open(identifier, updated: opened[identifier]?.updated).comments.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let start = cursor.flatMap(Int.init) ?? 0
        let page = Array(all.dropFirst(start).prefix(pageSize))
        let next = start + pageSize < all.count ? String(start + pageSize) : nil
        return (page, next)
    }

    /// "Sam Lee · 2026-10-08 08:16 UTC\nWhat they wrote", blocks split by "---" lines, as PAP
    /// writes an issue's comments.
    static func comments(_ text: String) -> [LinearComment] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return text.components(separatedBy: "\n\n---\n\n").compactMap { block in
            let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let heading = lines.first, let dot = heading.range(of: " · ", options: .backwards) else { return nil }
            var author = String(heading[..<dot.lowerBound])
            if author.hasPrefix("Reply from ") { author.removeFirst("Reply from ".count) }
            let when = heading[dot.upperBound...].replacingOccurrences(of: " UTC", with: "")
            let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return LinearComment(author: author, body: body, date: formatter.date(from: when))
        }
    }

    /// Puts `agent:<id>` on an issue and takes other `agent:` labels off, writing the issue's
    /// whole label list (PAP replaces every label). Other labels are kept as they were.
    func assignAgentLabel(issue identifier: String, agentID: String) async throws {
        let name = LinearSource.agentLabelName(agentID)
        let current = try await open(identifier, updated: nil).issue.labels
        var labels = current.filter { !$0.lowercased().hasPrefix("agent:") }
        labels.append(name)
        guard Set(labels.map { $0.lowercased() }) != Set(current.map { $0.lowercased() }) else { return }
        try await update(identifier, ["labels": .string(labels.joined(separator: ", "))])
    }

    func workflowStates() async throws -> [LinearState] {
        if seenStates.isEmpty { _ = try await list(limit: 100) }
        return seenStates.map { name, type in
            LinearState(id: name, name: name, type: type, position: Double(Self.typeOrder.firstIndex(of: type) ?? Self.typeOrder.count))
        }
        .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    func projects() async throws -> [LinearProject] {
        if seenProjects.isEmpty { _ = try await openIssues() }
        return seenProjects.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { LinearProject(id: $0, name: $0, state: "started") }
    }

    /// Edits only the fields given. `stateID` and `projectID` are names here.
    func updateIssue(_ identifier: String, title: String?, description: String?, stateID: String?, priority: Int?, projectID: String??) async throws {
        var fields: [String: JSONValue] = [:]
        if let title { fields["title"] = .string(title) }
        if let description { fields["description"] = .string(description) }
        if let stateID { fields["status"] = .string(stateID) }
        if let priority, Self.priorities.indices.contains(priority) { fields["priority"] = .string(Self.priorities[priority]) }
        if let projectID { fields["project"] = .string(projectID ?? "") }
        guard !fields.isEmpty else { return }
        try await update(identifier, fields)
    }

    private func update(_ identifier: String, _ fields: [String: JSONValue]) async throws {
        var params = fields
        params["id"] = .string(identifier)
        _ = try await client.run(try await linear(), "issues_update", params)
        opened[identifier] = nil
    }

    func createIssue(title: String, description: String, projectID: String?, agentID: String?) async throws -> (identifier: String, url: URL?) {
        var params: [String: JSONValue] = ["title": .string(title), "team": .string(teamKey), "description": .string(description)]
        if let projectID { params["project"] = .string(projectID) }
        if let agentID { params["labels"] = .string(LinearSource.agentLabelName(agentID)) }
        let record = try await client.run(try await linear(), "issues_create", params)["record"] ?? .null
        guard let identifier = record["id"]?.stringValue else { throw PAPError.tool("Linear didn't return the new issue") }
        return (identifier, record["url"]?.stringValue.flatMap(URL.init(string:)))
    }
}
