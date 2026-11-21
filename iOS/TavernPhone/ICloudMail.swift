import Foundation
import Network
import TavernCore

/// iCloud Mail's inbox over IMAP, read-only (EXAMINE and BODY.PEEK never mark anything read).
/// iOS gives apps no access to Mail.app, so this signs in with an app-specific password Paul makes
/// at account.apple.com and types into Tavern; it lives in the Keychain on this iPhone only.
enum ICloudMail {
    private static let keychain = KeychainTokenStore(service: "Tavern iPhone iCloud Mail", account: "app-password")
    private static let addressKey = "tavern.phone.icloudAddress"

    static var address: String? {
        get { UserDefaults.standard.string(forKey: addressKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: addressKey) }
    }

    static var isSetUp: Bool { address != nil && keychain.read() != nil }

    static func save(address: String, password: String) throws {
        // App-specific passwords show as xxxx-xxxx-xxxx-xxxx; spaces from a paste don't belong.
        try keychain.write(password.replacingOccurrences(of: " ", with: ""))
        self.address = address.trimmingCharacters(in: .whitespaces)
    }

    static func forget() {
        keychain.delete()
        address = nil
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// The newest `limit` messages in the inbox, newest first, as Mail rows (ids `icloud:<uid>`).
    static func inbox(limit: Int = 15) async throws -> [MailRow] {
        guard let address, let password = keychain.read() else {
            throw Failure(errorDescription: "iCloud Mail isn't set up. Add it on the Mail tab.")
        }
        let session = IMAPSession()
        defer { session.close() }
        try await session.open(host: "imap.mail.me.com", port: 993)
        _ = try await session.command("LOGIN \(quoted(address)) \(quoted(password))", failure: "iCloud didn't accept the address and app-specific password.")
        let examined = try await session.command("EXAMINE INBOX")
        let count = examined.lines.compactMap { line -> Int? in
            let parts = line.split(separator: " ")
            return parts.count >= 3 && parts[2] == "EXISTS" ? Int(parts[1]) : nil
        }.last ?? 0
        guard count > 0 else { return [] }
        let first = max(1, count - limit + 1)
        let fetched = try await session.command("FETCH \(first):\(count) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        _ = try? await session.command("LOGOUT")
        return fetched.messages.reversed().map { message in
            let headers = parseHeaders(message.literal)
            return MailRow(id: "icloud:\(message.uid ?? "\(message.sequence)")",
                           subject: headers["subject"].map(decodeWords) ?? "(no subject)",
                           from: headers["from"].map(decodeWords).map(displayName) ?? "",
                           snippet: "", date: headers["date"] ?? "")
        }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Header fields, unfolded, by lowercased name.
    static func parseHeaders(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        var last: String?
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.first == " " || line.first == "\t", let last {
                fields[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = name
            }
        }
        return fields
    }

    /// "Jane Doe <jane@x.com>" → "Jane Doe"; a bare address stays as it is.
    static func displayName(_ from: String) -> String {
        guard let angle = from.firstIndex(of: "<") else { return from }
        let name = from[..<angle].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? from : name
    }

    /// RFC 2047 encoded words (=?UTF-8?B?…?= and =?UTF-8?Q?…?=), as subjects and names use them.
    static func decodeWords(_ text: String) -> String {
        let pattern = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/
        var result = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: pattern) {
            let between = rest[..<match.range.lowerBound]
            // Whitespace between two encoded words is dropped.
            if !(between.allSatisfy(\.isWhitespace) && !result.isEmpty) { result += between }
            let charset = String(match.1).lowercased()
            let encoding: String.Encoding = charset.contains("8859-1") || charset.contains("latin1") ? .isoLatin1 : (charset.contains("1252") ? .windowsCP1252 : .utf8)
            var data: Data?
            if match.2.uppercased() == "B" {
                var base64 = String(match.3)
                while base64.count % 4 != 0 { base64 += "=" }
                data = Data(base64Encoded: base64)
            } else {
                data = quotedPrintable(String(match.3).replacingOccurrences(of: "_", with: " "))
            }
            result += data.flatMap { String(data: $0, encoding: encoding) } ?? String(match.0)
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    private static func quotedPrintable(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "=", let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: index)..<end], radix: 16) {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(text[index]).utf8))
                index = text.index(after: index)
            }
        }
        return Data(bytes)
    }
}

/// Just enough IMAP for the inbox: tagged commands over TLS, untagged lines, and FETCH literals.
final class IMAPSession: @unchecked Sendable {
    struct Reply {
        var lines: [String] = []
        var messages: [(sequence: Int, uid: String?, literal: String)] = []
    }

    private let queue = DispatchQueue(label: "tavern.imap")
    private var connection: NWConnection?
    private var buffer = Data()
    private var tag = 0

    func open(host: String, port: UInt16) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
        self.connection = connection
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; done.resume()
                case .failed(let error), .waiting(let error): finished = true; done.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        _ = try await readLine() // The server's greeting.
    }

    func close() { connection?.cancel() }

    /// Sends a command and reads until its tagged status; a NO or BAD throws `failure`.
    func command(_ text: String, failure: String? = nil) async throws -> Reply {
        tag += 1
        let label = "t\(tag)"
        try await send("\(label) \(text)\r\n")
        var reply = Reply()
        while true {
            let line = try await readLine()
            if line.hasPrefix(label + " ") {
                let status = line.dropFirst(label.count + 1)
                guard status.hasPrefix("OK") else { throw ICloudMail.Failure(errorDescription: failure ?? "iCloud Mail said: \(status)") }
                return reply
            }
            // `* 12 FETCH (UID 345 BODY[...] {120}` is followed by 120 bytes, then `)`.
            if line.hasPrefix("* "), line.contains(" FETCH "), line.hasSuffix("}"),
               let open = line.lastIndex(of: "{"), let size = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) {
                let literal = try await read(size)
                let parts = line.split(separator: " ")
                let uid = parts.firstIndex(of: "(UID").flatMap { parts.indices.contains($0 + 1) ? String(parts[$0 + 1]) : nil }
                    ?? parts.firstIndex(of: "UID").flatMap { parts.indices.contains($0 + 1) ? String(parts[$0 + 1]) : nil }
                reply.messages.append((Int(parts[1]) ?? 0, uid, String(decoding: literal, as: UTF8.self)))
                _ = try await readLine() // The closing `)` (sometimes with a trailing UID).
            } else {
                reply.lines.append(line)
            }
        }
    }

    private func send(_ text: String) async throws {
        guard let connection else { throw ICloudMail.Failure(errorDescription: "Not connected to iCloud Mail.") }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                return line
            }
            try await receive()
        }
    }

    private func read(_ count: Int) async throws -> Data {
        while buffer.count < count { try await receive() }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    private func receive() async throws {
        guard let connection else { throw ICloudMail.Failure(errorDescription: "Not connected to iCloud Mail.") }
        let data: Data = try await withCheckedThrowingContinuation { done in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error { return done.resume(throwing: error) }
                if let data, !data.isEmpty { return done.resume(returning: data) }
                done.resume(throwing: ICloudMail.Failure(errorDescription: isComplete ? "iCloud Mail closed the connection." : "iCloud Mail sent nothing."))
            }
        }
        buffer.append(data)
    }
}
