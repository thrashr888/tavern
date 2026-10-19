import Foundation

/// Read-only Gmail REST calls Tavern makes (scope `gmail.readonly`). No send, modify or delete.
public protocol GmailHTTP: Sendable {
    /// GET `https://gmail.googleapis.com/gmail/v1/users/me/<path>` with `query`. Returns body and status.
    func get(_ path: String, query: [URLQueryItem]) async throws -> (Data, Int)
    /// POST a JSON body to the same base. Only used to archive a thread.
    func post(_ path: String, body: Data) async throws -> (Data, Int)
}

extension GmailHTTP {
    public func post(_ path: String, body: Data) async throws -> (Data, Int) { (Data(), 405) }
}

public enum GmailError: Error, Equatable {
    case http(status: Int, path: String)
    case labelNotFound(String)
    case notAuthorized
}

/// A Gmail message reduced to what the party feed shows.
public struct GmailMessage: Equatable, Sendable {
    public var id: String
    public var threadID: String
    public var historyID: String?
    public var internalDate: Date
    public var subject: String
    public var from: String
    public var messageIDHeader: String?
    public var snippet: String
    public var body: String
    /// Sent from this Gmail account itself (the SENT label), which outside mail can't fake.
    public var sentFromAccount = false
    /// Domains Gmail verified for this message (DMARC pass), from its own `Authentication-Results`.
    public var verifiedDomains: [String] = []

    public init(id: String, threadID: String, historyID: String?, internalDate: Date, subject: String,
                from: String, messageIDHeader: String?, snippet: String, body: String) {
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.internalDate = internalDate
        self.subject = subject
        self.from = from
        self.messageIDHeader = messageIDHeader
        self.snippet = snippet
        self.body = body
    }

    /// Parses a `users.messages.get` (format=full) response.
    public static func parse(_ json: JSONValue) -> GmailMessage? {
        guard let id = json["id"]?.stringValue, let threadID = json["threadId"]?.stringValue else { return nil }
        let headers = json["payload"]?["headers"]?.arrayValue ?? []
        func header(_ name: String) -> String? {
            headers.first { $0["name"]?.stringValue?.lowercased() == name.lowercased() }?["value"]?.stringValue
        }
        let millis = Double(json["internalDate"]?.stringValue ?? "") ?? 0
        var message = GmailMessage(
            id: id,
            threadID: threadID,
            historyID: json["historyId"]?.stringValue,
            internalDate: Date(timeIntervalSince1970: millis / 1000),
            subject: header("Subject") ?? "(no subject)",
            from: header("From") ?? "",
            messageIDHeader: header("Message-ID"),
            snippet: decodeEntities(json["snippet"]?.stringValue ?? ""),
            body: plainText(of: json["payload"]) ?? htmlText(of: json["payload"]).map(textFromHTML) ?? ""
        )
        message.sentFromAccount = json["labelIds"]?.arrayValue?.contains { $0.stringValue == "SENT" } == true
        // Only the topmost Authentication-Results counts: Gmail adds its own on top, and any below
        // it came with the message, so a sender could have written them.
        message.verifiedDomains = headers.first { $0["name"]?.stringValue?.lowercased() == "authentication-results" }
            .flatMap { $0["value"]?.stringValue }
            .map(verifiedDomains(in:)) ?? []
        return message
    }

    /// Domains with `dmarc=pass` (its header.from) in an Authentication-Results value written by
    /// Gmail (authserv-id mx.google.com). Comments and quoted strings are removed first, and the
    /// result must be the clause's first token, so text like `(dmarc=pass header.from=x)` or a
    /// property value can't pass for a result.
    static func verifiedDomains(in results: String) -> [String] {
        let clauses = stripCommentsAndQuotes(results.lowercased()).split(separator: ";")
        guard clauses.first?.split(whereSeparator: \.isWhitespace).first == "mx.google.com" else { return [] }
        var domains: [String] = []
        for clause in clauses.dropFirst() {
            let words = clause.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first == "dmarc=pass" else { continue }
            for word in words.dropFirst() where word.hasPrefix("header.from=") {
                let value = String(word.dropFirst("header.from=".count))
                if !value.isEmpty, !value.contains("@") { domains.append(value) }
            }
        }
        return domains
    }

    /// Drops RFC 5322 comments (nested parentheses) and quoted strings, honoring backslash escapes.
    static func stripCommentsAndQuotes(_ text: String) -> String {
        var out = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for ch in text {
            if escaped { escaped = false; continue }
            if ch == "\\", depth > 0 || quoted { escaped = true; continue }
            if quoted { if ch == "\"" { quoted = false; out.append(" ") }; continue }
            if ch == "(" { depth += 1; continue }
            if depth > 0 { if ch == ")" { depth -= 1; if depth == 0 { out.append(" ") } }; continue }
            if ch == "\"" { quoted = true; continue }
            out.append(ch)
        }
        return out
    }

    /// The first text/plain part, depth-first. Gmail uses base64url without padding.
    static func plainText(of part: JSONValue?) -> String? {
        guard let part else { return nil }
        if part["mimeType"]?.stringValue == "text/plain", let data = part["body"]?["data"]?.stringValue {
            return decodeBase64URL(data)
        }
        for child in part["parts"]?.arrayValue ?? [] {
            if let text = plainText(of: child) { return text }
        }
        return nil
    }

    /// The first text/html part, for mail sent without a plain-text alternative.
    static func htmlText(of part: JSONValue?) -> String? {
        guard let part else { return nil }
        if part["mimeType"]?.stringValue == "text/html", let data = part["body"]?["data"]?.stringValue {
            return decodeBase64URL(data)
        }
        for child in part["parts"]?.arrayValue ?? [] {
            if let html = htmlText(of: child) { return html }
        }
        return nil
    }

    /// Readable text from an HTML mail body: block tags become line breaks, quoted replies become
    /// "> " lines so they're cut like plain-text quotes, and other tags go.
    static func textFromHTML(_ html: String) -> String {
        // Mail bodies are untrusted and can be huge; the regex pass only ever sees the first 200 KB.
        var text = String(html.prefix(200_000))
        let rules: [(String, String)] = [
            ("(?is)<(script|style|head)[^>]*>.*?</\\1>", ""),
            ("(?is)<blockquote[^>]*>.*", "\n> quoted"),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|li|h[1-6]|tr)>", "\n"),
            ("(?i)<li[^>]*>", "- "),
            ("(?s)<[^>]+>", ""),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = decodeEntities(text).replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeBase64URL(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Typed wrappers over the few endpoints the feed needs.
public struct GmailAPI: Sendable {
    let http: GmailHTTP

    public init(http: GmailHTTP) {
        self.http = http
    }

    func json(_ path: String, _ query: [URLQueryItem] = []) async throws -> JSONValue {
        let (data, status) = try await http.get(path, query: query)
        if status == 401 || status == 403 { throw GmailError.notAuthorized }
        guard (200..<300).contains(status) else { throw GmailError.http(status: status, path: path) }
        return try JSONValue.decode(data)
    }

    /// The id of the label shown as `name`.
    public func labelID(named name: String) async throws -> String {
        let labels = try await json("labels")["labels"]?.arrayValue ?? []
        guard let id = labels.first(where: { $0["name"]?.stringValue == name })?["id"]?.stringValue else {
            throw GmailError.labelNotFound(name)
        }
        return id
    }

    /// Current mailbox history id, the starting cursor after a full sync.
    public func profileHistoryID() async throws -> String? {
        try await json("profile")["historyId"]?.stringValue
    }

    /// Newest-first message ids in a label, up to `limit`.
    public func messageIDs(labelID: String, limit: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "labelIds", value: labelID),
                         URLQueryItem(name: "maxResults", value: String(min(100, limit - ids.count)))]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await json("messages", query)
            ids += (page["messages"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            pageToken = page["nextPageToken"]?.stringValue
        } while pageToken != nil && ids.count < limit
        return ids
    }

    /// Threads with at least one message both in `labelID` and the inbox (not archived).
    public func inboxThreadIDs(labelID: String, limit: Int = 500) async throws -> Set<String> {
        var threads = Set<String>()
        var pageToken: String?
        var seen = 0
        repeat {
            var query = [URLQueryItem(name: "labelIds", value: labelID), URLQueryItem(name: "labelIds", value: "INBOX"),
                         URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await json("messages", query)
            let items = page["messages"]?.arrayValue ?? []
            seen += items.count
            threads.formUnion(items.compactMap { $0["threadId"]?.stringValue })
            pageToken = page["nextPageToken"]?.stringValue
        } while pageToken != nil && seen < limit
        return threads
    }

    public struct HistoryPage: Equatable, Sendable {
        public var addedMessageIDs: [String]
        public var historyID: String?
    }

    /// Messages added to `labelID` since `startHistoryID`. Throws `.http(404)` when the id expired.
    public func history(since startHistoryID: String, labelID: String) async throws -> HistoryPage {
        var added: [String] = []
        var latest: String?
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "startHistoryId", value: startHistoryID),
                         URLQueryItem(name: "labelId", value: labelID),
                         URLQueryItem(name: "historyTypes", value: "messageAdded"),
                         URLQueryItem(name: "historyTypes", value: "labelAdded")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await json("history", query)
            for record in page["history"]?.arrayValue ?? [] {
                for key in ["messagesAdded", "labelsAdded"] {
                    for item in record[key]?.arrayValue ?? [] {
                        if let id = item["message"]?["id"]?.stringValue, !added.contains(id) { added.append(id) }
                    }
                }
            }
            latest = page["historyId"]?.stringValue ?? latest
            pageToken = page["nextPageToken"]?.stringValue
        } while pageToken != nil
        return HistoryPage(addedMessageIDs: added, historyID: latest)
    }

    /// Archives a thread: takes it out of the inbox, nothing else (needs the gmail.modify scope).
    public func archive(threadID: String) async throws {
        let body = try JSONValue.object(["removeLabelIds": .array([.string("INBOX")])]).encoded()
        let (_, status) = try await http.post("threads/\(threadID)/modify", body: body)
        if status == 401 || status == 403 { throw GmailError.notAuthorized }
        guard (200..<300).contains(status) else { throw GmailError.http(status: status, path: "threads/modify") }
    }

    public func message(id: String) async throws -> GmailMessage? {
        GmailMessage.parse(try await json("messages/\(id)", [URLQueryItem(name: "format", value: "full")]))
    }
}

/// URLSession transport with a bearer token from `tokenProvider`.
public struct GmailURLSessionHTTP: GmailHTTP {
    let tokenProvider: @Sendable () async throws -> String
    let session: URLSession

    public init(session: URLSession = .shared, tokenProvider: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func get(_ path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func post(_ path: String, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
