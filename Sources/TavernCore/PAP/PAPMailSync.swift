import Foundation

/// Pulls the party's labelled mail into the event log through Personal Agent Proxy's Google
/// connection: source `gmail`, keyed by Gmail's own message ids.
///
/// PAP lists email with Gmail's search syntax but has no history API, labels or thread ids:
/// - New mail: a search for the label `after:` the newest stored mail (less a day of overlap,
///   which dedup makes harmless). The first run reads up to `fullSyncLimit` of the label.
/// - Threads: a reply joins the stored thread with its subject (Re:/Fwd: aside), keeping the real
///   Gmail thread id that mail stored before PAP has; otherwise the subject is the thread.
/// - Verified senders: PAP doesn't pass Gmail's Authentication-Results, so only mail in Sent
///   (written from this account, which outside mail can't fake) counts as verified.
/// - Archive: PAP's permissioned `emails_archive`, on each inbox message of the thread.
@MainActor
public struct PAPMailSync {
    public static let cursorSource = "pap-mail"
    nonisolated static let subjectThreadPrefix = "subject:"

    let client: PAPClient
    let store: EventStore
    let roster: Roster
    public var labelName: String
    public var fullSyncLimit: Int

    public init(client: PAPClient, store: EventStore, roster: Roster, labelName: String? = nil, fullSyncLimit: Int = 300) {
        self.client = client
        self.store = store
        self.roster = roster
        self.labelName = labelName ?? roster.mailLabelName
        self.fullSyncLimit = fullSyncLimit
    }

    /// `label:the-party`: Gmail's search names a label with hyphens for its spaces.
    nonisolated static func labelQuery(_ name: String) -> String {
        let slug = name.lowercased().map { $0 == " " || $0 == "/" ? "-" : $0 }
        return "label:\(String(slug))"
    }

    private func mailbox() async throws -> String {
        try await client.connection("Google", describedAs: "Gmail connection").id
    }

    /// Ids, newest first, of the mail a search finds, at most `limit`.
    func list(_ connection: String, search: String, folder: String? = nil, limit: Int) async throws -> [(id: String, date: Date?)] {
        var found: [(id: String, date: Date?)] = []
        var page: String?
        repeat {
            var params: [String: JSONValue] = ["search": .string(search)]
            if let folder { params["folder"] = .string(folder) }
            if let page { params["page"] = .string(page) }
            let result = try await client.read(connection, "emails_list", params)
            for record in result["records"]?.arrayValue ?? [] {
                guard let id = record["id"]?.stringValue, !id.hasPrefix("draft-") else { continue }
                found.append((id, record["values"]?["date"]?.stringValue.flatMap(Self.parseDate)))
            }
            page = result["nextPage"]?.stringValue
        } while page != nil && found.count < limit
        return Array(found.prefix(limit))
    }

    @discardableResult
    public func sync() async throws -> Int {
        let connection = try await mailbox()
        let label = Self.labelQuery(labelName)
        var search = label
        var limit = fullSyncLimit
        if let cursor = try store.cursor(for: Self.cursorSource), let newest = Double(cursor) {
            // A day of overlap catches mail Gmail files late; dedup drops what's already stored.
            search += " after:\(Int(newest) - 86_400)"
            limit = 500
        }
        let listed = try await list(connection, search: search, limit: limit)
        let stored = Set(try store.events(source: EventSource.gmail).map(\.sourceID))
        let new = listed.filter { !stored.contains($0.id) }
        let sent = new.isEmpty ? [] : Set(try await list(connection, search: "\(search) in:sent", limit: limit).map(\.id))

        var threads = ThreadIndex(events: try store.events(source: EventSource.gmail))
        var events: [TavernEvent] = []
        for item in new.reversed() {
            guard var message = try await message(connection, id: item.id) else { continue }
            message.sentFromAccount = sent.contains(message.id)
            message.threadID = threads.thread(for: message.subject)
            events.append(MailItem.event(for: message, roster: roster))
        }
        // Never ahead of now: a cursor in the future would skip mail until then.
        let newest = (listed.compactMap(\.date) + events.map(\.sourceTS)).max().map { min($0, Date()) }
        let previous = try store.cursor(for: Self.cursorSource)
        let cursor = newest.map { String(Int($0.timeIntervalSince1970)) } ?? previous ?? String(Int(Date().timeIntervalSince1970))
        return try store.append(events, cursor: (Self.cursorSource, cursor))
    }

    /// One email with its body, as a `GmailMessage`; nil when it's gone.
    func message(_ connection: String, id: String) async throws -> GmailMessage? {
        let record: JSONValue
        do {
            record = try await client.read(connection, "emails_get", ["id": .string(id)])["record"] ?? .null
        } catch PAPError.tool(let text) where text.hasPrefix("There is no") {
            return nil
        }
        guard let values = record["values"] else { return nil }
        let body = values["body"]?.stringValue ?? ""
        let message = GmailMessage(
            id: record["id"]?.stringValue ?? id,
            threadID: "",
            internalDate: values["date"]?.stringValue.flatMap(Self.parseDate) ?? Date(),
            subject: values["subject"]?.stringValue ?? "(no subject)",
            from: values["from"]?.stringValue ?? "",
            snippet: String(MailItem.stripQuotedReply(body).prefix(160)),
            body: body
        )
        return message
    }

    /// Archives every inbox message of a thread through PAP. Messages already out of the inbox
    /// are skipped; PAP refusing the action for Tavern's login throws its words.
    public func archive(threadID: String) async throws {
        let connection = try await mailbox()
        let ids = try store.events(threadKey: MailItem.threadKey(threadID)).map(\.sourceID)
        let inbox = Set(try await list(connection, search: Self.labelQuery(labelName), folder: "Inbox", limit: 500).map(\.id))
        for id in ids where inbox.contains(id) {
            _ = try await client.run(connection, "emails_archive", ["id": .string(id)])
        }
    }

    public func inboxThreads() async throws -> Set<String> {
        let connection = try await mailbox()
        let inbox = Set(try await list(connection, search: Self.labelQuery(labelName), folder: "Inbox", limit: 500).map(\.id))
        let events = try store.events(source: EventSource.gmail).filter { inbox.contains($0.sourceID) }
        return Set(events.compactMap(MailItem.init(event:)).map(\.threadID))
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Stored threads by cleaned subject, newest wins, growing as new mail is added.
    struct ThreadIndex {
        private var bySubject: [String: String] = [:]

        init(events: [TavernEvent]) {
            for item in events.compactMap(MailItem.init(event:)).sorted(by: { $0.date < $1.date }) where !item.threadID.isEmpty {
                bySubject[Self.key(item.subject)] = item.threadID
            }
        }

        mutating func thread(for subject: String) -> String {
            let key = Self.key(subject)
            if let known = bySubject[key] { return known }
            let id = PAPMailSync.subjectThreadPrefix + key
            bySubject[key] = id
            return id
        }

        static func key(_ subject: String) -> String {
            MailThread.cleanSubject(subject).lowercased()
        }
    }
}
