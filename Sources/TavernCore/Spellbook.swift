import Foundation

/// One spell from the party's spellbook repo (private-agent-skills), as its generated index.json
/// lists it. Tavern only reads spells; changes go through the repo. Kind, lifecycle and gate stay
/// strings so a value a newer repo adds doesn't hide the whole list.
public struct Spell: Codable, Equatable, Identifiable, Sendable {
    /// "SB-nn", never reused.
    public var id: String
    /// The spell's folder, spells/<name>.
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
