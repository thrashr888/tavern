import Foundation

/// One iMessage in a member's conversation, as `cider messages list` reports it.
public struct IMessage: Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var fromMe: Bool
    public var date: Date
    /// Absolute paths of photos and files sent with it (cider 0.13+).
    public var attachments: [String]

    public init(id: String, text: String, fromMe: Bool, date: Date, attachments: [String] = []) {
        self.id = id
        self.text = text
        self.fromMe = fromMe
        self.date = date
        self.attachments = attachments
    }

    /// Attachments Tavern can draw inline.
    public var images: [String] {
        attachments.filter { ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// The words of the message; cider's "[Attachment]" placeholder is dropped when the image shows.
    public var displayText: String {
        text == "[Attachment]" || (text == "[Attachment or rich text]" && !attachments.isEmpty) ? "" : text
    }
}

/// Reads and sends a member's iMessages through cider, on this Mac. Reading lists recent
/// messages and keeps the one conversation; sending happens only when the user presses Send.
public struct CiderMessages: Sendable {
    public var cider: String

    public init(cider: String = CiderMessages.defaultPath) { self.cider = cider }

    /// A cider Tavern carries in Application Support wins (one with features Homebrew's lacks
    /// yet, like attachment paths); otherwise Homebrew's.
    public static var defaultPath: String {
        let bundled = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tavern/bin/cider").path
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return "/opt/homebrew/bin/cider"
    }

    public func history(with handle: String, days: Int = 7) async throws -> [IMessage] {
        let data = try await run(["messages", "list", "--days", String(days), "--limit", "2000"])
        return Self.parse(data, handle: handle)
    }

    public func send(_ text: String, to handle: String) async throws {
        _ = try await run(["messages", "send", "--to", handle, "--text", text])
    }

    /// Sends an image through cider (`messages send --file`, thrashr888/cider#7), from a temporary copy.
    public func sendImage(_ data: Data, fileExtension: String, to handle: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["messages", "send", "--to", handle, "--file", file.path])
    }

    static func parse(_ data: Data, handle: String) -> [IMessage] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let format = ISO8601DateFormatter()
        let wanted = normalized(handle)
        return rows.compactMap { row -> IMessage? in
            // Whole-handle match only: a suffix match would let a look-alike number in.
            let matches = normalized((row["conversation"] as? String) ?? "") == wanted
            let attachments = (row["attachments"] as? [String]) ?? []
            guard matches, let text = row["text"] as? String, !text.isEmpty || !attachments.isEmpty,
                  let stamp = row["timestamp"] as? String, let date = format.date(from: stamp) else { return nil }
            return IMessage(id: "\(row["id"] ?? stamp)", text: text, fromMe: (row["is_from_me"] as? Bool) ?? false,
                            date: date, attachments: attachments)
        }
        .sorted { $0.date < $1.date }
    }

    /// An email lowercased, or a phone number as "+" and all its digits.
    static func normalized(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.lowercased() }
        return "+" + trimmed.filter(\.isNumber)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        #if os(macOS)
        let program = cider
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CiderError(message: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
        #else
        throw CiderError(message: "Messages are read on a Mac")
        #endif
    }
}

public struct CiderError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message.isEmpty ? "cider failed" : message }
}
