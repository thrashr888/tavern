import Foundation

/// "Proof of value" for the Dashboard: what the party got done and what it cost, counted from
/// the agents' stored history (Pi entries) and Tavern's approval log. Nothing is estimated.
public struct ProofOfValue: Equatable, Sendable {
    /// Something an agent shipped: a PR, an email draft, or a file it edited or wrote.
    public struct Shipped: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable { case pullRequest = "PR", draft = "Draft", edit = "Edit", file = "New file" }
        public var id: String
        public var agentID: String
        public var kind: Kind
        public var title: String
        public var date: Date
    }

    public struct ToolUse: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var count: Int
    }

    /// Finished replies (assistant turns that ended rather than called tools), this week.
    public var turnsThisWeek = 0
    /// Per local day and agent, for the 14-day charts.
    public var turnsDaily: [DailyCount] = []
    /// Model spend (USD) per local day and agent, from each reply's usage.
    public var spendDaily: [DailySpend] = []
    public var approved = 0
    public var declined = 0
    /// Heartbeats that woke an agent (the host found something new), this week.
    public var heartbeatWakes = 0
    public var shipped: [Shipped] = []
    /// Tools by calls this week, most used first, by server (`cider`, `pap`) or Pi's own tool.
    public var tools: [ToolUse] = []
    /// Spells cast this week: agents' `spellbook_get` calls and runs started in Tavern, by spell id
    /// or name, most used first.
    public var spells: [ToolUse] = []
    public var spellCasts: Int { spells.reduce(0) { $0 + $1.count } }

    public init() {}

    public struct DailySpend: Equatable, Identifiable, Sendable {
        public var id: String { "\(day.timeIntervalSince1970)-\(key)" }
        public var day: Date
        public var key: String
        public var dollars: Double
    }

    public func spend(on day: Date, calendar: Calendar = .current) -> Double {
        spendDaily.filter { calendar.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + $1.dollars }
    }

    public func spend(agent: String, on day: Date, calendar: Calendar = .current) -> Double {
        spendDaily.filter { $0.key == agent && calendar.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + $1.dollars }
    }

    /// From the last 14 days of stored events.
    public init(store: EventStore, now: Date = Date(), calendar: Calendar = .current) {
        let fortnight = calendar.startOfDay(for: now.addingTimeInterval(-13 * 86_400))
        let week = now.addingTimeInterval(-7 * 86_400)
        var turns: [String: Int] = [:]   // "day|agent"
        var spend: [String: Double] = [:]
        var tools: [String: Int] = [:]
        var spells: [String: Int] = [:]
        var shipped: [Shipped] = []

        for event in (try? store.events(source: EventSource.pi, since: fortnight)) ?? [] {
            guard event.kind == "pi.message.assistant" || event.kind == "pi.message.user",
                  let json = try? JSONValue.decode(event.payload), let message = json["message"] else { continue }
            let agent = String(event.threadKey.dropFirst("pi:".count))
            let day = calendar.startOfDay(for: event.sourceTS)
            let bucket = "\(day.timeIntervalSince1970)|\(agent)"
            let recent = event.sourceTS >= week
            if event.kind == "pi.message.user" {
                let text = Self.text(message)
                if recent, text.hasPrefix("[Heartbeat ") { heartbeatWakes += 1 }
                continue
            }
            if let cost = message["usage"]?["cost"]?["total"]?.doubleValue { spend[bucket, default: 0] += cost }
            let calls = (message["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "toolCall" }
            let stop = message["stopReason"]?.stringValue
            if calls.isEmpty, stop != "error", stop != "aborted", !Self.text(message).isEmpty {
                turns[bucket, default: 0] += 1
                if recent { turnsThisWeek += 1 }
            }
            guard recent else { continue }
            for call in calls {
                let name = call["name"]?.stringValue ?? "tool"
                tools[Self.toolGroup(name), default: 0] += 1
                let arguments = call["arguments"] ?? .object([:])
                if let spell = Self.spellOpened(name: name, arguments: arguments) { spells[spell, default: 0] += 1 }
                let id = call["id"]?.stringValue ?? UUID().uuidString
                if let kind = Self.shippedKind(name: name, arguments: arguments) {
                    shipped.append(Shipped(id: id, agentID: agent, kind: kind.0, title: kind.1, date: event.sourceTS))
                }
            }
        }
        for event in (try? store.events(source: EventSource.tavern, since: week)) ?? [] {
            let json = try? JSONValue.decode(event.payload)
            if event.kind == ApprovalLog.kind {
                let answer = json?["answer"]?.stringValue
                if answer == "Approved" || answer == "Always allowed" { approved += 1 } else if answer == "Declined" { declined += 1 }
            } else if event.kind == SpellRun.eventKind, let spell = json?["spellId"]?.stringValue {
                // A run started from Tavern's Spellbook counts as a cast too.
                spells[spell, default: 0] += 1
            }
        }

        func split(_ key: String) -> (Date, String) {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return (Date(timeIntervalSince1970: Double(parts[0]) ?? 0), parts.count > 1 ? parts[1] : "")
        }
        turnsDaily = turns.map { let (day, agent) = split($0.key); return DailyCount(day: day, key: agent, count: $0.value) }
            .sorted { $0.day < $1.day }
        spendDaily = spend.map { let (day, agent) = split($0.key); return DailySpend(day: day, key: agent, dollars: $0.value) }
            .sorted { $0.day < $1.day }
        self.tools = tools.map { ToolUse(name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        self.spells = spells.map { ToolUse(name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        self.shipped = shipped.sorted { $0.date > $1.date }
    }

    private static func text(_ message: JSONValue) -> String {
        if let text = message["content"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    /// An MCP tool counts under its server ("cider", "pap"); Pi's own tools by name.
    static func toolGroup(_ name: String) -> String {
        if let range = name.range(of: "__") { return String(name[..<range.lowerBound]) }
        return name
    }

    /// The spell a `spellbook_get` call opened (pi-bundle's spellbook server), by id or name.
    static func spellOpened(name: String, arguments: JSONValue) -> String? {
        guard name == "spellbook_get" || name.hasSuffix("__spellbook_get") else { return nil }
        return arguments["id"]?.stringValue ?? arguments["name"]?.stringValue ?? "spell"
    }

    /// PRs opened with gh, drafts saved through PAP, and files edited or written.
    static func shippedKind(name: String, arguments: JSONValue) -> (Shipped.Kind, String)? {
        switch name {
        case "bash":
            let command = arguments["command"]?.stringValue ?? ""
            guard command.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil else { return nil }
            let title = command.range(of: #"--title\s+(["'])(.*?)\1"#, options: .regularExpression).map { range -> String in
                let quoted = String(command[range]).replacingOccurrences(of: #"^--title\s+"#, with: "", options: .regularExpression)
                return String(quoted.dropFirst().dropLast())
            }
            return (.pullRequest, title ?? "Pull request")
        case "pap__run":
            let tool = arguments["tool"]?.stringValue ?? ""
            guard tool == "emails_create" || tool.contains("draft") else { return nil }
            let subject = arguments["params"]?["subject"]?.stringValue
            return (.draft, subject ?? "Email draft")
        case "edit":
            return (.edit, arguments["path"]?.stringValue ?? "a file")
        case "write":
            return (.file, arguments["path"]?.stringValue ?? "a file")
        default:
            return nil
        }
    }
}
