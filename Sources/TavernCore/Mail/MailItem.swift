import Foundation

/// One Gmail message as Personal Agent Proxy reads it, before it becomes a stored event.
public struct GmailMessage: Equatable, Sendable {
    public static let kind = "mail.message"

    public var id: String
    public var threadID: String
    public var internalDate: Date
    public var subject: String
    public var from: String
    public var snippet: String
    public var body: String
    /// In Sent: written from this Gmail account itself, which outside mail can't fake.
    public var sentFromAccount = false

    public init(id: String, threadID: String, internalDate: Date, subject: String, from: String, snippet: String, body: String) {
        self.id = id
        self.threadID = threadID
        self.internalDate = internalDate
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.body = body
    }
}

/// One stored party mail, as the Mail page shows it.
public struct MailItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var threadID: String
    public var subject: String
    public var from: String
    public var author: String?
    public var project: String?
    public var date: Date
    public var snippet: String
    /// Body with the quoted reply chain cut off.
    public var body: String
    /// The sender is proven, not just claimed: sent from this account. (Mail synced before Tavern
    /// went through Personal Agent Proxy may also be verified by Gmail's DMARC result.) Only
    /// verified mail can trigger agents.
    public var verifiedSender = false

    public init(id: String, threadID: String, subject: String, from: String, author: String?, project: String?,
                date: Date, snippet: String, body: String) {
        self.id = id
        self.threadID = threadID
        self.subject = subject
        self.from = from
        self.author = author
        self.project = project
        self.date = date
        self.snippet = snippet
        self.body = body
    }

    public static func threadKey(_ threadID: String) -> String { "gmail-thread:\(threadID)" }

    public static func event(for message: GmailMessage, roster: Roster) -> TavernEvent {
        let body = stripQuotedReply(message.body)
        let author = detectAuthor(from: message.from, body: body, roster: roster)
        let project = detectProject(subject: message.subject, projects: roster.mailProjects)
        var payload: [String: JSONValue] = [
            "threadId": .string(message.threadID),
            "subject": .string(message.subject),
            "from": .string(message.from),
            "snippet": .string(message.snippet),
            "body": .string(body),
        ]
        if let project { payload["project"] = .string(project) }
        if message.sentFromAccount { payload["verifiedSender"] = .bool(true) }
        return TavernEvent(
            source: EventSource.gmail,
            sourceID: message.id,
            threadKey: threadKey(message.threadID),
            authorAgent: author,
            sourceTS: message.internalDate,
            kind: GmailMessage.kind,
            payload: (try? JSONValue.object(payload).encoded()) ?? Data()
        )
    }

    public init?(event: TavernEvent) {
        guard event.source == EventSource.gmail, let json = try? JSONValue.decode(event.payload) else { return nil }
        self.init(
            id: event.sourceID,
            threadID: json["threadId"]?.stringValue ?? "",
            subject: json["subject"]?.stringValue ?? "",
            from: json["from"]?.stringValue ?? "",
            author: event.authorAgent,
            project: json["project"]?.stringValue,
            date: event.sourceTS,
            snippet: json["snippet"]?.stringValue ?? "",
            body: json["body"]?.stringValue ?? ""
        )
        verifiedSender = json["verifiedSender"]?.boolValue == true
    }

    /// Cuts the body at the first quoted-reply marker ("On … wrote:" or a ">" line).
    static func stripQuotedReply(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { break }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed.hasPrefix("-----Original Message-----") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Who wrote a mail. A member's `mailFrom` (their own address or domain) decides from the
    /// header; otherwise, since several members may send from the owner's address, the sign-off in
    /// the last lines of the body does: a member's name or one of their `signOffs`.
    static func detectAuthor(from: String, body: String, roster: Roster) -> String? {
        let sender = from.lowercased()
        if let member = roster.members.first(where: { $0.mailFrom?.contains { !$0.isEmpty && sender.contains($0.lowercased()) } == true }) {
            return member.id
        }
        // Quoted lines ("> Rook") belong to the message being replied to, not this one.
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        func member(named word: String) -> RosterMember? {
            roster.members.first { $0.name.lowercased() == word || $0.signOffs?.contains { $0.lowercased() == word } == true }
        }
        for line in lines.suffix(4).reversed() {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "-–—~,. ")).lowercased()
            if let member = member(named: cleaned) { return member.id }
            // "— Tally, Forge Cleric ⚒️": a short sign-off line that starts with the name.
            guard cleaned.count <= 60, let first = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).first else { continue }
            if let member = member(named: String(first)), line.trimmingCharacters(in: .whitespaces).first.map({ "-–—~".contains($0) || $0.isLetter }) == true,
               cleaned.hasPrefix(String(first)) {
                return member.id
            }
        }
        return nil
    }

    /// Fills in authors for stored mail that has none, using the current detection.
    @discardableResult
    public static func reattribute(store: EventStore, roster: Roster) -> Int {
        guard let events = try? store.events(source: EventSource.gmail) else { return 0 }
        var fixed = 0
        for event in events where event.authorAgent == nil {
            guard let json = try? JSONValue.decode(event.payload),
                  let author = detectAuthor(from: json["from"]?.stringValue ?? "", body: json["body"]?.stringValue ?? "", roster: roster)
            else { continue }
            if (try? store.setAuthor(source: EventSource.gmail, sourceID: event.sourceID, author: author)) != nil { fixed += 1 }
        }
        return fixed
    }

    /// The mail project named in the subject ("The Party: Tavern - M1 plan" is Tavern), ignoring
    /// Re:/Fwd:. The earliest label in the subject wins; nil when none is named.
    static func detectProject(subject: String, projects: [MailProject]) -> String? {
        let lower = subject.lowercased()
        var best: (index: String.Index, id: String)?
        for project in projects {
            guard let range = lower.range(of: project.label.lowercased()) else { continue }
            let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
            let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
            let isWord = !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
            if isWord, best == nil || range.lowerBound < best!.index { best = (range.lowerBound, project.id) }
        }
        return best?.id
    }
}

/// A party mail thread: its messages oldest first.
public struct MailThread: Equatable, Identifiable, Sendable {
    public var id: String { threadID }
    public var threadID: String
    public var messages: [MailItem]

    public var subject: String { Self.cleanSubject(messages.first?.subject ?? "") }
    public var project: String? { messages.compactMap(\.project).last }
    public var lastDate: Date { messages.last?.date ?? .distantPast }
    public var authors: [String] {
        var seen: [String] = []
        for author in messages.compactMap(\.author) where !seen.contains(author) { seen.append(author) }
        return seen
    }
    /// Opens the thread in Gmail on the web. A thread known only by its subject opens at its
    /// latest message, whose id Gmail also takes.
    public var gmailURL: URL? {
        let id = threadID.hasPrefix(PAPMailSync.subjectThreadPrefix) ? messages.last?.id ?? "" : threadID
        return URL(string: "https://mail.google.com/mail/u/0/#all/\(id)")
    }

    /// Agents' hourly "… Heartbeat" status mails: useful as presence, noise in the thread list.
    public var isHeartbeat: Bool { subject.localizedCaseInsensitiveContains("heartbeat") }

    /// What the latest message asks of the owner, from the party's "Needs from <owner>: …"
    /// convention or an "Action needed" subject; nil when it asks nothing.
    public func ask(of owner: String) -> String? {
        guard let last = messages.last else { return nil }
        for line in last.body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "needs from \(owner.lowercased()):", options: .caseInsensitive), range.lowerBound == trimmed.startIndex else { continue }
            let ask = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
            let lower = ask.lowercased()
            let none = lower.isEmpty || lower == "n/a" || ["nothing", "none", "no "].contains { lower.hasPrefix($0) } || lower == "no"
            return none ? nil : String(ask)
        }
        // Heartbeats repeat "Action Needed" every hour; only a real thread's subject counts.
        if !isHeartbeat, last.subject.localizedCaseInsensitiveContains("action needed") { return subject }
        return nil
    }

    /// Threads newest-activity first, optionally only one project's.
    public static func threads(from events: [TavernEvent], project: String? = nil) -> [MailThread] {
        let items = events.compactMap(MailItem.init(event:))
        let grouped = Dictionary(grouping: items, by: \.threadID)
        return grouped
            .map { MailThread(threadID: $0.key, messages: $0.value.sorted { $0.date < $1.date }) }
            .filter { project == nil || $0.project == project }
            .sorted { $0.lastDate > $1.lastDate }
    }

    static func cleanSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(re|fwd?|fw):\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text.isEmpty ? "(no subject)" : text
    }
}

extension MailItem {
    /// Members the mail greets in its opening line ("Peter, Ember, Tally - quick nudge…",
    /// "Quill (cc Tally, Ember), the plan…"), not just anyone it mentions.
    public func addressees(in roster: Roster) -> [String] {
        guard let first = body.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
        var greeting = Substring(first.prefix(160))
        for stop in [" - ", " — ", ":", ". "] {
            if let range = greeting.range(of: stop) { greeting = greeting[..<range.lowerBound] }
        }
        let words = Set(greeting.lowercased().split { !$0.isLetter }.map(String.init))
        return roster.members.filter { words.contains($0.name.lowercased()) }.map(\.id)
    }
}

extension Array where Element == MailThread {
    /// The newest mail each member wrote (heartbeats included): presence for agents with no
    /// live connection.
    public func lastSeen() -> [String: Date] {
        var seen: [String: Date] = [:]
        for thread in self {
            for message in thread.messages {
                guard let author = message.author else { continue }
                if message.date > seen[author] ?? .distantPast { seen[author] = message.date }
            }
        }
        return seen
    }

    /// Threads a member wrote in, newest first.
    public func involving(_ memberID: String) -> [MailThread] {
        filter { $0.messages.contains { $0.author == memberID } }.sorted { $0.lastDate > $1.lastDate }
    }
}

extension MailThread {
    /// Whether every word of `query` appears somewhere in the thread: its subject, a sender's
    /// address or member name, or a message's text. Case and accents don't matter.
    public func matches(_ query: String, roster: Roster) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        var haystack = [subject]
        for message in messages {
            haystack.append(message.from)
            if let author = message.author, let name = roster.member(id: author)?.name { haystack.append(name) }
            haystack.append(message.body.isEmpty ? message.snippet : message.body)
        }
        let text = haystack.joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
