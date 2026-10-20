import Foundation

/// Writes roster.json for Settings. The file stays the store: Settings edits the fields Tavern
/// knows and leaves everything else in the file (keys from a newer Tavern, hand-added notes) alone.
public enum RosterFile {
    /// Top-level keys Settings owns. Anything else in the file is kept as it was.
    static let rosterKeys = ["members", "mailProjects", "partyName", "mailLabel", "ownerName", "trustedSenders", "linearTeam", "lore"]
    /// Member keys Settings owns; other keys on a member are kept.
    static let memberKeys = ["id", "name", "kind", "host", "partyClass", "animal", "summary", "skills", "avatarColor", "piLaunch",
                             "piEndpoint", "tailscaleName", "schedule", "projects", "platform", "owns", "mailFrom", "signOffs",
                             "mailEvents", "relay", "imessage"]

    public enum SaveError: Error, LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            if case .unreadable(let reason) = self { return "roster.json can't be read (\(reason)); fix it by hand first" }
            return nil
        }
    }

    /// Saves `roster` to `url`. The first save keeps the old file as roster.json.before-settings.
    /// A file that exists but can't be read or parsed is never overwritten.
    public static func save(_ roster: Roster, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing: [String: Any]?
        if fm.fileExists(atPath: url.path) {
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    throw SaveError.unreadable("not a JSON object")
                }
                existing = object
            } catch let error as SaveError {
                throw error
            } catch {
                throw SaveError.unreadable(error.localizedDescription)
            }
        }
        let backup = url.appendingPathExtension("before-settings")
        if existing != nil, !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try merged(roster, into: existing ?? [:])
        try data.write(to: url, options: .atomic)
    }

    /// The roster's JSON laid over `original`, keeping keys Tavern doesn't model.
    static func merged(_ roster: Roster, into original: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        guard var fresh = try JSONSerialization.jsonObject(with: encoder.encode(roster)) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }
        let oldMembers = (original["members"] as? [[String: Any]]) ?? []
        if let members = fresh["members"] as? [[String: Any]] {
            fresh["members"] = members.map { member -> [String: Any] in
                guard let id = member["id"] as? String,
                      var old = oldMembers.first(where: { $0["id"] as? String == id }) else { return member }
                for key in memberKeys { old.removeValue(forKey: key) }
                return old.merging(member) { _, new in new }
            }
        }
        var result = original
        for key in rosterKeys { result.removeValue(forKey: key) }
        result.merge(fresh) { _, new in new }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

extension Roster {
    /// An id for a new member from their name: lowercase letters and digits, unique in the roster.
    public func newMemberID(for name: String) -> String {
        let base = String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
        let stem = base.isEmpty ? "member" : base
        var id = stem
        var n = 2
        while member(id: id) != nil {
            id = "\(stem)\(n)"
            n += 1
        }
        return id
    }
}
