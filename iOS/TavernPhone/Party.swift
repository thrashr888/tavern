import SwiftUI
import TavernCore
import UIKit

/// The party's own art and lore, copied into the app at build time by scripts/phone.sh from the
/// Mac's ~/Library/Application Support/Tavern (iOS/Party, never committed: it's personal). An
/// app built without it shows initials and no portrait.
enum Party {
    static let folder = Bundle.main.url(forResource: "Party", withExtension: nil)

    struct Info: Decodable {
        var partyName: String?
        var lore: [LoreLink]?
        var spellbookStars: [String]?
        /// The Linear team Goals reads (the roster's `linearTeam`).
        var linearTeam: String?
        var members: [Member]?
    }

    /// A party member as Goals needs it: who they are and which Linear projects they own.
    struct Member: Decodable, Identifiable {
        var id: String
        var name: String
        var avatarColor: String?
        var owns: [String]?
        var partyClass: String?
    }

    /// The member an issue belongs to: its `agent:<id>` label (or assignee), else its project's owner.
    static func member(for issue: LinearIssue) -> Member? {
        let members = info.members ?? []
        if let owner = issue.owner?.lowercased(), let found = members.first(where: { $0.id.lowercased() == owner || $0.name.lowercased() == owner }) {
            return found
        }
        guard let project = issue.project?.lowercased() else { return nil }
        return members.first { $0.owns?.contains { $0.lowercased() == project } == true }
    }

    static let info: Info = folder
        .flatMap { try? Data(contentsOf: $0.appendingPathComponent("party.json")) }
        .flatMap { try? JSONDecoder().decode(Info.self, from: $0) } ?? Info()

    static let portrait: UIImage? = image(named: "portrait")

    private static var avatars: [String: UIImage?] = [:]

    /// avatars/<id>.jpg (or .png), loaded once.
    static func avatar(_ id: String) -> UIImage? {
        if let hit = avatars[id] { return hit }
        let found = image(named: "avatars/\(id)")
        avatars[id] = found
        return found
    }

    private static func image(named name: String) -> UIImage? {
        guard let folder else { return nil }
        for ext in ["jpg", "jpeg", "png", "heic"] {
            if let image = UIImage(contentsOfFile: folder.appendingPathComponent("\(name).\(ext)").path) { return image }
        }
        return nil
    }

    /// The spellbook as of the build (index.json and each SKILL.md), or nil without one.
    static let spellbook: SpellbookSnapshot? = {
        guard let dir = folder?.appendingPathComponent("spellbook"),
              let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let index = try? SpellIndex.parse(data) else { return nil }
        return SpellbookSnapshot(spells: index.spells.filter { !$0.isRetired }, commit: try? String(contentsOf: dir.appendingPathComponent("COMMIT"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }()

    static func document(for spell: Spell) -> SpellDocument? {
        guard let dir = folder?.appendingPathComponent("spellbook"),
              let text = try? String(contentsOf: dir.appendingPathComponent(spell.path), encoding: .utf8) else { return nil }
        return SpellDocument.parse(text)
    }
}

extension Color {
    /// Text on the accent (the Mac's onAccent).
    static let onTavernAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.098, blue: 0.051, alpha: 1)
            : UIColor(red: 0.980, green: 0.953, blue: 0.890, alpha: 1)
    })

    /// The Mac app's accent: leather in light mode, candlelight in dark.
    static let tavernAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.882, green: 0.588, blue: 0.247, alpha: 1)
            : UIColor(red: 0.545, green: 0.290, blue: 0.110, alpha: 1)
    })
}
