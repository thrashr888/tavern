import Foundation

/// One spell from the party's spellbook repo (private-agent-skills), as its generated index.json
/// lists it. Tavern only reads spells; changes go through the repo. Kind, lifecycle and gate stay
/// strings so a value a newer repo adds doesn't hide the whole list.
public struct Spell: Codable, Equatable, Identifiable, Sendable {
    /// "SB-nn", never reused.
    public var id: String
    /// The spell's folder, skills/<name> (from index.json).
    public var name: String
    public var title: String
    /// "<Title>. Use when: <trigger>."
    public var description: String
    /// "spell" or "ritual".
    public var kind: String
    public var owner: String?
    public var reviewOwner: String?
    /// Agent names, or "all".
    public var appliesTo: [String]
    /// "live", "proposal" or "retired".
    public var lifecycle: String
    /// "none", "needs-review", "needs-paul" or "blocked".
    public var gate: String
    public var version: Int
    /// SKILL.md, relative to the repo root.
    public var path: String

    enum CodingKeys: String, CodingKey {
        case id, name, title, description, kind, owner
        case reviewOwner = "review_owner"
        case appliesTo = "applies_to"
        case lifecycle, gate, version, path
    }

    public init(id: String, name: String, title: String, description: String, kind: String = "spell", owner: String? = nil,
                reviewOwner: String? = nil, appliesTo: [String] = ["all"], lifecycle: String = "live", gate: String = "none",
                version: Int = 1, path: String) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.kind = kind
        self.owner = owner
        self.reviewOwner = reviewOwner
        self.appliesTo = appliesTo
        self.lifecycle = lifecycle
        self.gate = gate
        self.version = version
        self.path = path
    }

    /// Every key but id, name, title and path is optional, so an index that drops one (lifecycle and
    /// gate went 2026-10-22) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? title
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "spell"
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        reviewOwner = try c.decodeIfPresent(String.self, forKey: .reviewOwner)
        appliesTo = try c.decodeIfPresent([String].self, forKey: .appliesTo) ?? ["all"]
        lifecycle = try c.decodeIfPresent(String.self, forKey: .lifecycle) ?? "live"
        gate = try c.decodeIfPresent(String.self, forKey: .gate) ?? "none"
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        path = try c.decode(String.self, forKey: .path)
    }

    /// The number in "SB-nn", for sorting; ids without one sort last.
    public var number: Int { Int(id.split(separator: "-").last ?? "") ?? .max }
    public var isRitual: Bool { kind == "ritual" }
    public var isRetired: Bool { lifecycle == "retired" }
    /// The trigger half of the description ("Use when: …"), or the whole description.
    public var trigger: String {
        guard let range = description.range(of: "Use when:") else { return description }
        return description[range.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }

    /// Whether the spell is for this member: applies-to names them (by Tavern id or name) or "all".
    public func applies(to member: RosterMember) -> Bool {
        let names = Set(appliesTo.map { $0.lowercased() })
        return names.contains("all") || names.contains(member.id.lowercased()) || names.contains(member.name.lowercased())
    }

    /// "SB-20 v2", how run evidence cites a spell.
    public var citation: String { "\(id) v\(version)" }
}

/// index.json at the repo root: every spell, retired ones included, sorted by id.
public struct SpellIndex: Codable, Equatable, Sendable {
    public var spells: [Spell]

    public init(spells: [Spell]) { self.spells = spells }

    public static func parse(_ data: Data) throws -> SpellIndex {
        var index = try JSONDecoder().decode(SpellIndex.self, from: data)
        index.spells.sort { ($0.number, $0.id) < ($1.number, $1.id) }
        return index
    }
}

/// A spell's SKILL.md, read when it's opened: the body's sections in order (When to use, Inputs,
/// Steps, Done when, Tools, Permissions, Notes) and the numbered steps, for a run checklist.
public struct SpellDocument: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    /// The body's "# " heading.
    public var title: String?
    public var sections: [Section]

    public func section(_ title: String) -> Section? {
        sections.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// The Steps section's numbered items, with wrapped lines joined to their step.
    public var steps: [String] {
        guard let body = section("Steps")?.body else { return [] }
        var steps: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                steps.append(String(trimmed[range.upperBound...]))
            } else if !trimmed.isEmpty, !steps.isEmpty, line.first == " " || line.first == "\t" {
                steps[steps.count - 1] += " " + trimmed
            }
        }
        return steps
    }

    /// The spell the steps hand off to ("…, then run SB-21"), if any.
    public func chainedSpell(from id: String) -> String? {
        let text = section("Steps")?.body ?? ""
        let pattern = #"\b[Rr]un\s+(SB-\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }.last { $0 != id }
    }

    public static func parse(_ text: String) -> SpellDocument {
        var lines = text.components(separatedBy: .newlines)
        // Frontmatter: index.json already carries it.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var title: String?
        var sections: [Section] = []
        var current: (title: String, lines: [String])?
        var inCode = false
        func flush() {
            if let current {
                sections.append(Section(title: current.title,
                                        body: current.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in lines {
            if line.hasPrefix("```") { inCode.toggle() }
            if !inCode, line.hasPrefix("## ") {
                flush()
                current = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if !inCode, line.hasPrefix("# "), title == nil, current == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        flush()
        return SpellDocument(title: title, sections: sections)
    }
}

/// Where the spellbook comes from: a git URL (or a local path) from roster.json, and a branch.
public struct SpellbookSource: Equatable, Sendable {
    public var repo: String
    /// Nil follows the remote's default branch.
    public var branch: String?

    public init(repo: String, branch: String? = nil) {
        self.repo = repo
        self.branch = branch
    }

    public init?(roster: Roster) {
        guard let repo = roster.spellbookRepo?.trimmingCharacters(in: .whitespaces), !repo.isEmpty else { return nil }
        let branch = roster.spellbookBranch?.trimmingCharacters(in: .whitespaces)
        self.init(repo: repo, branch: branch?.isEmpty == false ? branch : nil)
    }
}

/// The spellbook as last pulled: its spells and the commit they came from.
public struct SpellbookSnapshot: Equatable, Sendable {
    public var spells: [Spell]
    public var commit: String?
    public var committedAt: Date?

    public init(spells: [Spell], commit: String? = nil, committedAt: Date? = nil) {
        self.spells = spells
        self.commit = commit
        self.committedAt = committedAt
    }

    public func spell(id: String) -> Spell? { spells.first { $0.id == id } }

    /// Spells for one member, retired ones left out.
    public func spells(for member: RosterMember) -> [Spell] {
        spells.filter { !$0.isRetired && $0.applies(to: member) }
    }
}

public struct SpellbookError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String {
        if message.contains("Authentication failed") || message.contains("could not read Username") || message.contains("terminal prompts disabled") {
            return "GitHub sign-in needed: git and gh on this Mac can't read the spellbook repo."
        }
        if message.contains("Repository not found") { return "The spellbook repo wasn't found, or this Mac's GitHub sign-in can't see it." }
        if message.contains("Could not resolve host") { return "Offline: couldn't reach the spellbook repo." }
        return message
    }
}

/// Tavern's own read-only clone of the spellbook, in its Application Support folder. Git signs in
/// with the Mac's keychain; if that fails and gh is installed, it tries once more with gh's
/// sign-in. Tavern never edits the clone, so a refresh just moves it to the remote's commit.
public struct SpellbookRepo: Sendable {
    public var source: SpellbookSource
    public var directory: URL

    public init(source: SpellbookSource, directory: URL) {
        self.source = source
        self.directory = directory
    }

    public static func defaultDirectory() -> URL? { TavernPaths.file("spellbook") }

    var hasClone: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) }

    /// Clones on first use, then fetches and moves to the fetched commit. Throws with git's error;
    /// the copy on disk stays as it was.
    public func sync() async throws {
        if hasClone {
            _ = try await Self.git(["-C", directory.path, "remote", "set-url", "origin", source.repo])
            _ = try await Self.git(["-C", directory.path, "fetch", "--quiet", "--depth", "50", "origin", source.branch ?? "HEAD"], network: true)
            _ = try await Self.git(["-C", directory.path, "reset", "--quiet", "--hard", "FETCH_HEAD"])
        } else {
            let fm = FileManager.default
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = directory.appendingPathExtension("partial")
            try? fm.removeItem(at: partial)
            var args = ["clone", "--quiet", "--depth", "50"]
            if let branch = source.branch { args += ["--branch", branch] }
            _ = try await Self.git(args + [source.repo, partial.path], network: true)
            try? fm.removeItem(at: directory)
            try fm.moveItem(at: partial, to: directory)
        }
    }

    /// What's on disk now, without touching the network. Nil before the first clone.
    public func snapshot() async throws -> SpellbookSnapshot? {
        guard hasClone else { return nil }
        let index = try SpellIndex.parse(Data(contentsOf: directory.appendingPathComponent("index.json")))
        let log = try? await Self.git(["-C", directory.path, "log", "-1", "--format=%h %cI"])
        let parts = (log ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
        return SpellbookSnapshot(spells: index.spells, commit: parts.first,
                                 committedAt: parts.count > 1 ? ISO8601DateFormatter().date(from: parts[1]) : nil)
    }

    /// A spell's SKILL.md. Paths that leave the clone are refused.
    public func document(for spell: Spell) throws -> SpellDocument {
        let url = directory.appendingPathComponent(spell.path).standardizedFileURL
        guard url.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw SpellbookError(message: "\(spell.id)'s path leaves the spellbook")
        }
        return SpellDocument.parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// The command a person would run to make the first clone, for the setup row.
    public var cloneCommand: String {
        "git clone \(source.branch.map { "--branch \($0) " } ?? "")\(source.repo) \"\(directory.path)\""
    }

    static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    /// Runs git with prompts off. A network step that fails is retried once with gh's credential
    /// helper, when gh is installed.
    static func git(_ args: [String], network: Bool = false) async throws -> String {
        do {
            return try await run(args)
        } catch let error as SpellbookError where network {
            guard let gh = ghPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw error }
            let helper = ["-c", "credential.helper=", "-c", "credential.helper=!\(gh) auth git-credential"]
            return try await run(helper + args)
        }
    }

    private static func run(_ args: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            // A stalled transfer gives up rather than hanging the refresh.
            process.arguments = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30"] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SpellbookError(message: message.isEmpty ? "git exited \(process.terminationStatus)" : message)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// One manual run of a spell from Tavern (mock 2): its steps as a checklist with a note or evidence
/// link per step, tied to a Linear issue, and chained into the spell its steps hand off to (SB-20
/// then SB-21). Runs stay on this Mac; Tavern posts, sends and edits nothing for a run.
public struct SpellRun: Codable, Equatable, Identifiable, Sendable {
    /// One spell's checklist within the run.
    public struct Part: Codable, Equatable, Sendable {
        public var spellID: String
        public var title: String
        public var version: Int
        public var steps: [String]
        /// A note or evidence link per step, "" when none yet.
        public var notes: [String]
        /// Indexes into `steps`.
        public var checked: [Int]
        public var doneWhen: String?

        public init(spell: Spell, document: SpellDocument) {
            spellID = spell.id
            title = spell.title
            version = spell.version
            steps = document.steps
            notes = Array(repeating: "", count: document.steps.count)
            checked = []
            doneWhen = document.section("Done when")?.body
        }

        public var citation: String { "\(spellID) v\(version)" }
        public var allChecked: Bool { Set(checked).isSuperset(of: steps.indices) }

        public mutating func toggle(_ step: Int) {
            if let index = checked.firstIndex(of: step) { checked.remove(at: index) } else { checked.append(step) }
        }

        public mutating func setNote(_ note: String, for step: Int) {
            while notes.count < steps.count { notes.append("") }
            guard notes.indices.contains(step) else { return }
            notes[step] = note
        }
    }

    public var id: String
    /// The spell run first, then any it chains into.
    public var parts: [Part]
    /// The spellbook commit the steps came from.
    public var commit: String?
    /// Who is doing the work: a roster member, or nil for the owner themself.
    public var agentID: String?
    /// The Linear issue the run is for ("PAUL-203").
    public var issue: String?
    /// What the caster added when casting ("use the Q3 numbers").
    public var message: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(parts: [Part], commit: String?, agentID: String?, issue: String? = nil, message: String? = nil, startedAt: Date = Date()) {
        id = UUID().uuidString
        self.parts = parts
        self.commit = commit
        self.agentID = agentID
        self.issue = issue
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message?.isEmpty == false ? message : nil
        self.startedAt = startedAt
    }

    public init(spell: Spell, document: SpellDocument, commit: String?, agentID: String?, issue: String? = nil, message: String? = nil, startedAt: Date = Date()) {
        self.init(parts: [Part(spell: spell, document: document)], commit: commit, agentID: agentID, issue: issue, message: message, startedAt: startedAt)
    }

    public var spellID: String { parts.first?.spellID ?? "" }
    public var title: String { parts.first?.title ?? "" }
    /// "SB-20 v1 then SB-21 v1".
    public var citation: String { parts.map(\.citation).joined(separator: " then ") }
    public var isFinished: Bool { finishedAt != nil }
    public var allChecked: Bool { parts.allSatisfy(\.allChecked) }
    public var checkedCount: Int { parts.reduce(0) { $0 + $1.checked.count } }
    public var stepCount: Int { parts.reduce(0) { $0 + $1.steps.count } }

    /// Plain text for the issue or thread: the citation, then each step with its mark and note.
    public func summary(by name: String) -> String {
        var lines = ["\(name): cast \(citation)\(issue.map { " on \($0)" } ?? "")\(commit.map { " (spellbook @ \($0))" } ?? "")."]
        if let message { lines.append(message) }
        for part in parts {
            lines.append("")
            lines.append("\(part.citation) \(part.title)")
            for (index, step) in part.steps.enumerated() {
                let note = part.notes.indices.contains(index) ? part.notes[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                lines.append("\(part.checked.contains(index) ? "[x]" : "[ ]") \(step)\(note.isEmpty ? "" : " — \(note)")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What an agent is sent when someone casts a spell for it: read the spell through the
    /// spellbook server, then follow it, citing the version.
    public var agentPrompt: String {
        var lines = ["Please cast \(citation): \(parts.map(\.title).joined(separator: ", then "))."]
        lines.append("Read \(parts.count == 1 ? "it" : "each") with spellbook_get (\(parts.map(\.spellID).joined(separator: ", "))) and follow the steps; cite the version in your report.")
        if let issue { lines.append("Issue: \(issue)") }
        if let message { lines.append("\n" + message) }
        return lines.joined(separator: "\n")
    }

    /// Kind of the event a run start writes, so the Dashboard counts it with agents' casts.
    public static let eventKind = "tavern.spell.run"

    public var startEvent: TavernEvent {
        let payload: JSONValue = [
            "type": "tavern_spell_run",
            "runId": .string(id),
            "spellId": .string(spellID),
            "spells": .array(parts.map { .string($0.citation) }),
            "agent": agentID.map(JSONValue.string) ?? .null,
            "issue": issue.map(JSONValue.string) ?? .null,
            "message": message.map(JSONValue.string) ?? .null,
            "commit": commit.map(JSONValue.string) ?? .null,
        ]
        return TavernEvent(source: EventSource.tavern, sourceID: "spellrun:\(id)", threadKey: "spellbook",
                           authorAgent: "paul", sourceTS: startedAt, receivedTS: startedAt, kind: Self.eventKind,
                           payload: (try? payload.encoded()) ?? Data())
    }
}

/// Spell runs, in spell-runs.json beside the roster.
public struct SpellRunStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL? { TavernPaths.file("spell-runs.json") }

    /// Newest first.
    public func load() -> [SpellRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([SpellRun].self, from: data)) ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    /// Adds or replaces a run by id.
    @discardableResult
    public func save(_ run: SpellRun) throws -> [SpellRun] {
        var all = load().filter { $0.id != run.id }
        all.insert(run, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: url, options: .atomic)
        return all.sorted { $0.startedAt > $1.startedAt }
    }
}

/// A spell someone cast: an agent opening it through the spellbook server (`spellbook_get`), or a
/// run started in Tavern.
public struct SpellCast: Equatable, Identifiable, Sendable {
    public var id: String
    /// The spell's id, or its name when the call named it that way.
    public var spell: String
    public var agentID: String?
    public var date: Date
    public var fromTavern: Bool

    /// Casts since `since`, newest first, optionally for one agent.
    public static func recent(store: EventStore, agentID: String? = nil, since: Date) -> [SpellCast] {
        var casts: [SpellCast] = []
        for event in (try? store.events(source: EventSource.pi, since: since)) ?? [] where event.kind == "pi.message.assistant" {
            let agent = String(event.threadKey.dropFirst("pi:".count))
            if let agentID, agent != agentID { continue }
            guard let json = try? JSONValue.decode(event.payload) else { continue }
            for call in json["message"]?["content"]?.arrayValue ?? [] where call["type"]?.stringValue == "toolCall" {
                guard let spell = ProofOfValue.spellOpened(name: call["name"]?.stringValue ?? "", arguments: call["arguments"] ?? .object([:])) else { continue }
                casts.append(SpellCast(id: call["id"]?.stringValue ?? UUID().uuidString, spell: spell, agentID: agent,
                                       date: event.sourceTS, fromTavern: false))
            }
        }
        for event in (try? store.events(source: EventSource.tavern, since: since)) ?? [] where event.kind == SpellRun.eventKind {
            guard let json = try? JSONValue.decode(event.payload), let spell = json["spellId"]?.stringValue else { continue }
            let agent = json["agent"]?.stringValue
            if let agentID, agent != agentID { continue }
            casts.append(SpellCast(id: event.sourceID, spell: spell, agentID: agent, date: event.sourceTS, fromTavern: true))
        }
        return casts.sorted { $0.date > $1.date }
    }
}
