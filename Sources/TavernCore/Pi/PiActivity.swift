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
/// show it: "Ran ls -la" (Shell), "Read plan.md" (Read), with its duration.
public struct PiStep: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case shell = "Shell"
        case read = "Read"
        case write = "Write"
        case edit = "Edit"
        case search = "Search"
        case webSearch = "Web Search"
        case fetch = "Fetch"
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

    public var duration: TimeInterval? { ended.map { max(0, $0.timeIntervalSince(started)) } }
    public var isRunning: Bool { ended == nil }

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

    public var summary: String {
        let count = "\(steps.count) step\(steps.count == 1 ? "" : "s")"
        guard let duration else { return "Working · \(count)" }
        return "Worked \(PiWork.format(duration)) · \(count)"
    }

    /// "0.4s", "12s", "1m 15s".
    public static func format(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}

/// What a Pi thread shows, in order: messages, with tool runs folded into work rows.
public enum PiThreadRow: Equatable, Identifiable, Sendable {
    case message(TranscriptItem)
    case work(PiWork)
    /// An MCP Apps card a tool result came with, shown after the work that made it.
    case card(id: String, ToolCard)

    public var id: String {
        switch self {
        case .message(let item): return item.id
        case .work(let work): return "work:\(work.id)"
        case .card(let id, _): return "card:\(id)"
        }
    }
}

public enum PiActivity {
    /// Folds tool results (and the call-only assistant turns that asked for them) into work rows.
    /// A step's duration runs from the assistant turn that called it to its result.
    public static func rows(from items: [TranscriptItem]) -> [PiThreadRow] {
        var rows: [PiThreadRow] = []
        var calls: [String: (call: PiToolCall, at: Date)] = [:]
        var steps: [PiStep] = []

        func flush() {
            guard !steps.isEmpty else { return }
            rows.append(.work(PiWork(id: steps[0].id, steps: steps)))
            steps = []
        }

        for item in items {
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
                // A turn that only called tools: its steps carry it.
                continue
            default:
                flush()
                rows.append(.message(item))
            }
        }
        flush()
        return rows
    }
}
