import Foundation

/// A tool call from an assistant turn (`toolCall` content block, or a live `tool_execution_start`).
public struct PiToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One step of a turn's work, as the collapsed "Worked 48s · 9 steps" row and the Activity list
/// show it: "Ran ls -la" (Shell), "Read plan.md" (Read), "Planning the fix" (Thought), with its duration.
public struct PiStep: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case shell = "Shell"
        case read = "Read"
        case write = "Write"
        case edit = "Edit"
        case search = "Search"
        case webSearch = "Web Search"
        case fetch = "Fetch"
        case thought = "Thought"
        case other = "Tool"
    }

    public var id: String
    public var toolName: String
    public var kind: Kind
    public var title: String
    public var started: Date
    public var ended: Date?
    public var failed: Bool

    public init(id: String, toolName: String, kind: Kind, title: String, started: Date, ended: Date? = nil, failed: Bool = false) {
        self.id = id
        self.toolName = toolName
        self.kind = kind
        self.title = title
        self.started = started
        self.ended = ended
        self.failed = failed
    }

    public init(call: PiToolCall, started: Date) {
        let (kind, title) = Self.describe(toolName: call.name, arguments: call.arguments)
        self.init(id: call.id, toolName: call.name, kind: kind, title: title, started: started)
    }

    /// A thinking block the model wrote before calling tools, titled by its first line.
    public init(thoughtID id: String, thinking: String, started: Date, ended: Date? = nil) {
        self.init(id: id, toolName: "thinking", kind: .thought, title: Self.thoughtSummary(thinking), started: started, ended: ended)
    }

    public var duration: TimeInterval? { ended.map { max(0, $0.timeIntervalSince(started)) } }
    /// How long the step has run as of `now`: its duration once ended, else the time so far.
    public func elapsed(at now: Date) -> TimeInterval { duration ?? max(0, now.timeIntervalSince(started)) }
    public var isRunning: Bool { ended == nil }

    /// The first line of a thought, without Markdown emphasis or heading marks: models often open
    /// with a bolded heading ("**Planning the fix**"). "Thought" when there's nothing to show.
    public static func thoughtSummary(_ thinking: String) -> String {
        let line = thinking.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*_#> ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
        if line.isEmpty { return "Thought" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// A readable line for Pi's built-in tools; anything else is "Ran <tool>".
    public static func describe(toolName: String, arguments: JSONValue) -> (Kind, String) {
        func arg(_ key: String) -> String {
            let value = arguments[key]?.stringValue ?? ""
            let line = value.split(separator: "\n").first.map(String.init) ?? ""
            return line.count > 80 ? String(line.prefix(79)) + "…" : line
        }
        let name = toolName.lowercased()
        switch name {
        case "bash", "shell":
            return (.shell, "Ran \(arg("command"))")
        case "read":
            return (.read, "Read \(arg("path"))")
        case "write":
            return (.write, "Wrote \(arg("path"))")
        case "edit":
            return (.edit, "Edited \(arg("path"))")
        case "grep":
            return (.search, "Searched for \"\(arg("pattern"))\"")
        case "find":
            return (.search, "Found \(arg("pattern"))")
        case "ls":
            return (.search, "Listed \(arg("path").isEmpty ? "." : arg("path"))")
        default:
            if name.contains("search") && !arg("query").isEmpty {
                return (.webSearch, "Searched the web for \"\(arg("query"))\"")
            }
            if name.contains("fetch") && !arg("url").isEmpty {
                return (.fetch, "Read \(arg("url"))")
            }
            return (.other, "Ran \(toolName)")
        }
    }
}

/// A run of tool steps between messages, shown collapsed as "Worked 48s · 9 steps".
public struct PiWork: Equatable, Identifiable, Sendable {
    public var id: String
    public var steps: [PiStep]

    public init(id: String, steps: [PiStep]) {
        self.id = id
        self.steps = steps
    }

    public var started: Date? { steps.first?.started }
    public var ended: Date? { steps.last?.ended }
    public var duration: TimeInterval? {
        guard let started, let ended else { return nil }
        return max(0, ended.timeIntervalSince(started))
    }
    public var isRunning: Bool { steps.contains(where: \.isRunning) }
    /// Distinct step kinds in order, for the little icon strip.
    public var kinds: [PiStep.Kind] {
        var seen: [PiStep.Kind] = []
        for step in steps where !seen.contains(step.kind) { seen.append(step.kind) }
        return seen
    }

    public var summary: String { summary(at: nil) }

    /// "Worked 48s · 9 steps"; while running, "Working 12s · 3 steps" counted to `now`.
    public func summary(at now: Date?) -> String {
        let count = "\(steps.count) step\(steps.count == 1 ? "" : "s")"
        if isRunning || duration == nil {
            guard let now, let started else { return "Working · \(count)" }
            return "Working \(PiWork.format(now.timeIntervalSince(started))) · \(count)"
        }
        return "Worked \(PiWork.format(duration ?? 0)) · \(count)"
    }

    /// "0.4s", "12s", "1m 15s", "1h 2m".
    public static func format(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        // Rounding to a tenth can reach 10.0, which reads better as "10s".
        if (seconds * 10).rounded() < 100 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }
}

/// What a Pi thread shows, in order: messages, with tool runs folded into work rows.
public enum PiThreadRow: Equatable, Identifiable, Sendable {
    case message(TranscriptItem)
    case work(PiWork)
    /// A heartbeat and what the agent did about it, folded into one background row.
    case background(BackgroundRun)
    /// An MCP Apps card a tool result came with, shown after the work that made it.
    case card(id: String, ToolCard)

    public var id: String {
        switch self {
        case .message(let item): return item.id
        case .work(let work): return "work:\(work.id)"
        case .card(let id, _): return "card:\(id)"
        case .background(let run): return "background:\(run.id)"
        }
    }
}

/// A heartbeat turn: the host's message (what's new) and everything the agent did until the user
/// next wrote. Shown collapsed, like a tool step, not as chat.
public struct BackgroundRun: Equatable, Identifiable, Sendable {
    public var id: String
    public var date: Date
    /// The heartbeat message itself.
    public var trigger: TranscriptItem
    /// The agent's work and replies after it.
    public var items: [TranscriptItem]

    /// The new items the host listed ("- [mail] …" lines).
    public var newItems: [String] {
        trigger.text.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.map { String($0.dropFirst(2)) }
    }

    /// "2 new" for a check that found things; "Check-in" for the older every-beat prompt.
    public var title: String {
        let count = newItems.count
        return count == 0 ? "Check-in" : "\(count) new"
    }

    /// The agent's last words on it.
    public var reply: String? { items.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text }

    public var rows: [PiThreadRow] { PiActivity.rows(from: items) }
}

extension TranscriptItem {
    /// The host's heartbeat message (`[Heartbeat <time>] …`).
    public var isHeartbeat: Bool { role == .user && text.hasPrefix("[Heartbeat ") }
}

public enum PiActivity {
    /// Folds heartbeat turns into background rows, then tool runs into work rows.
    public static func rows(from items: [TranscriptItem]) -> [PiThreadRow] {
        var rows: [PiThreadRow] = []
        var plain: [TranscriptItem] = []
        var run: BackgroundRun?
        func flushPlain() {
            if !plain.isEmpty { rows += workRows(from: plain) }
            plain = []
        }
        func flushRun() {
            if let run { rows.append(.background(run)) }
            run = nil
        }
        for item in items {
            if item.isHeartbeat {
                flushPlain()
                flushRun()
                run = BackgroundRun(id: item.id, date: item.date, trigger: item, items: [])
            } else if run != nil, item.role != .user {
                run?.items.append(item)
            } else {
                flushRun()
                plain.append(item)
            }
        }
        flushPlain()
        flushRun()
        return rows
    }

    /// Folds tool results (and the call-only assistant turns that asked for them) into work rows.
    /// A step's duration runs from the assistant turn that called it to its result; a call-only
    /// turn's thinking becomes a thought step, running from the item before it to the turn.
    static func workRows(from items: [TranscriptItem]) -> [PiThreadRow] {
        var rows: [PiThreadRow] = []
        var calls: [String: (call: PiToolCall, at: Date)] = [:]
        var steps: [PiStep] = []
        var previous: Date?

        func flush() {
            guard !steps.isEmpty else { return }
            rows.append(.work(PiWork(id: steps[0].id, steps: steps)))
            steps = []
        }

        for item in items {
            defer { previous = item.date }
            for call in item.toolCalls { calls[call.id] = (call, item.date) }
            switch item.role {
            case .tool:
                var step: PiStep
                if let id = item.toolCallID, let issued = calls[id] {
                    step = PiStep(call: issued.call, started: issued.at)
                } else {
                    step = PiStep(id: item.id, toolName: item.toolName ?? "tool", kind: .other,
                                  title: item.text, started: item.date)
                }
                step.ended = item.date
                step.failed = item.failed
                steps.append(step)
                if var card = item.card {
                    if let id = item.toolCallID, let issued = calls[id] { card.arguments = issued.call.arguments }
                    flush()
                    rows.append(.card(id: item.id, card))
                }
            case .assistant where item.text.isEmpty && !item.toolCalls.isEmpty:
                // A turn that only called tools: its steps carry it, after its thinking.
                if !item.thinking.isEmpty {
                    steps.append(PiStep(thoughtID: "thought:\(item.id)", thinking: item.thinking,
                                        started: min(previous ?? item.date, item.date), ended: item.date))
                }
            default:
                flush()
                rows.append(.message(item))
            }
        }
        flush()
        return rows
    }
}
