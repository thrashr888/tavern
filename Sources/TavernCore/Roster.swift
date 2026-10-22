import Foundation

/// A party member as Tavern knows them. This is Tavern's own "agent card": no protocol supplies
/// identity today (plan 3d), so the roster is the fallback, and an A2A card can fill it in later.
public struct RosterMember: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Live over Pi RPC: one thread per agent.
        case pi
        /// Hosted elsewhere; Tavern only sees their party mail.
        case hosted
    }

    /// Stable Tavern id. Never a display name, so renames don't break restore or the event log.
    public var id: String
    public var name: String
    public var kind: Kind
    public var host: String?
    public var partyClass: String?
    public var animal: String?
    public var summary: String?
    public var skills: [String]
    /// Hex color for the avatar circle until art is wired up.
    public var avatarColor: String
    /// How to launch this agent's Pi locally in RPC mode: executable path, then arguments.
    /// Nil means no local launch; remote agents wait for an approved transport (plan 5.2).
    public var piLaunch: [String]?
    /// Where this agent's Pi RPC stream is (local command, SSH command or TCP). Overrides `piLaunch`.
    public var piEndpoint: PiEndpoint?
    /// The agent's machine on the tailnet: its MagicDNS short name or machine name, or "self" for
    /// the Mac Tavern runs on. Nil falls back to `host`.
    public var tailscaleName: String?
    /// When the agent works on its own (a host timer, a daily brief), as plain text for the
    /// inspector's Schedule tab. No protocol reports it yet (plan 3d).
    public var schedule: String?
    /// Mail project ids this member works on, for the Identity tab.
    public var projects: [String]?
    /// Where the member runs, as the user thinks of them: "Claude", "ChatGPT", "Grok", "Instinct",
    /// "Pi". Shown with `host` on hover cards ("Sage · Claude", "Scout · Pi on This Mac").
    public var platform: String?
    /// Linear projects this member owns (the user's owner map, 2026-10-14). Issues there count as
    /// theirs unless an agent:<id> label says otherwise.
    public var owns: [String]?
    /// Fragments of the From address that mean this member wrote a mail (an address or "@domain").
    public var mailFrom: [String]?
    /// Sign-offs that mean this member besides their name (a platform name, say).
    public var signOffs: [String]?
    /// Forward new party mail addressed to this Pi agent as an event (`mailEvents` in roster.json).
    public var mailEvents: Bool?
    /// Another member who carries messages to and from this one (Wren talks through Rook).
    public var relay: String?
    /// Phone number or email the member answers on iMessage (Rook, via Instinct). Set in
    /// roster.json; Tavern reads and sends through cider.
    public var imessage: String?

    public init(
        id: String, name: String, kind: Kind, host: String? = nil, partyClass: String? = nil,
        animal: String? = nil, summary: String? = nil, skills: [String] = [], avatarColor: String,
        piLaunch: [String]? = nil, piEndpoint: PiEndpoint? = nil, tailscaleName: String? = nil,
        schedule: String? = nil, projects: [String]? = nil, platform: String? = nil, owns: [String]? = nil,
        mailFrom: [String]? = nil, signOffs: [String]? = nil, imessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.partyClass = partyClass
        self.animal = animal
        self.summary = summary
        self.skills = skills
        self.avatarColor = avatarColor
        self.piLaunch = piLaunch
        self.piEndpoint = piEndpoint
        self.tailscaleName = tailscaleName
        self.schedule = schedule
        self.projects = projects
        self.platform = platform
        self.owns = owns
        self.mailFrom = mailFrom
        self.signOffs = signOffs
        self.imessage = imessage
    }

    public var initial: String { String(name.prefix(1)) }
}

/// A mail filter in the sidebar ("Tavern", "Alchemy", ...). `id` is stable, `label` is display.
public struct MailProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A shared reference the party keeps: the Ways of Working doc, the projects sheet, the plan.
public struct LoreLink: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case doc, sheet, linear, folder, link }
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
    public var kind: Kind

    public init(title: String, url: URL, kind: Kind) {
        self.title = title
        self.url = url
        self.kind = kind
    }
}

public struct Roster: Codable, Equatable, Sendable {
    public var members: [RosterMember]
    public var mailProjects: [MailProject]
    /// What the group is called ("Smithery"); names the mail feed and its label by default.
    public var partyName: String?
    /// The Gmail label Tavern reads; defaults to the party name.
    public var mailLabel: String?
    /// The person Tavern works for, as the party's mail addresses them ("Needs from the user: …").
    public var ownerName: String?
    /// From-address fragments Tavern trusts enough to forward mail to agents as events (the
    /// owner's own address, say). Members' `mailFrom` count too. Other senders never trigger events.
    public var trustedSenders: [String]?
    /// The Linear team key Goals reads (e.g. "ENG"); Goals is off without one.
    public var linearTeam: String?
    /// The party's shared references (docs, sheets, boards), shown under Lore.
    public var lore: [LoreLink]?
    /// The spellbook repo (git URL or local path) Tavern clones read-only for the Spellbook page.
    public var spellbookRepo: String?
    /// The spellbook branch to follow; nil follows the repo's default branch.
    public var spellbookBranch: String?
    /// Spells starred until the user stars or unstars one on this Mac, by SB id.
    public var spellbookStars: [String]?

    public init(members: [RosterMember], mailProjects: [MailProject], partyName: String? = nil, mailLabel: String? = nil,
                ownerName: String? = nil, linearTeam: String? = nil, lore: [LoreLink]? = nil) {
        self.members = members
        self.mailProjects = mailProjects
        self.partyName = partyName
        self.mailLabel = mailLabel
        self.ownerName = ownerName
        self.linearTeam = linearTeam
        self.lore = lore
    }

    public var party: String { partyName ?? "Party" }
    public var mailLabelName: String { mailLabel ?? party }
    public var owner: String { ownerName ?? "me" }
    public var loreLinks: [LoreLink] { lore ?? [] }

    /// Whether a From header belongs to a trusted sender (see `trustedSenders`).
    /// The single mailbox in a From header, lowercased, or nil when there's none or more than one
    /// ("Name <a@b>" or a bare "a@b"). Quoted display names are skipped; anything ambiguous is nil.
    public static func address(in from: String) -> String? {
        var text = from.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        let angle = text.filter { $0 == "<" }.count
        guard angle <= 1, text.filter({ $0 == ">" }).count == angle, !text.contains(",") else { return nil }
        if angle == 1 {
            guard let open = text.firstIndex(of: "<"), let close = text.firstIndex(of: ">"), open < close,
                  text[text.index(after: close)...].trimmingCharacters(in: .whitespaces).isEmpty,
                  !text[..<open].contains("@") else { return nil }
            text = String(text[text.index(after: open)..<close])
        }
        let address = text.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !address.contains(where: \.isWhitespace) else { return nil }
        return address
    }

    /// Whether a From header is a trusted sender: an exact address, or "@domain" for a whole domain,
    /// from `trustedSenders` and members' `mailFrom`. Callers must also check the sender is verified.
    public func isTrustedSender(_ from: String) -> Bool {
        guard let address = Roster.address(in: from) else { return false }
        let fragments = ((trustedSenders ?? []) + members.flatMap { $0.mailFrom ?? [] }).map { $0.lowercased() }
        return fragments.contains { fragment in
            fragment.hasPrefix("@") ? address.hasSuffix(fragment) : (!fragment.isEmpty && address == fragment)
        }
    }

    public var piAgents: [RosterMember] { members.filter { $0.kind == .pi } }

    /// Who owns a Linear project, from members' `owns` lists.
    public func owner(ofProject project: String?) -> RosterMember? {
        guard let name = project?.lowercased() else { return nil }
        return members.first { $0.owns?.contains { $0.lowercased() == name } == true }
    }

    public func member(id: String) -> RosterMember? { members.first { $0.id == id } }

    /// Reads `roster.json`: nil when there's no file, and a thrown error when there is one Tavern
    /// can't read, so nothing saves over it.
    public static func loadFile(from url: URL?) throws -> Roster? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Roster.self, from: Data(contentsOf: url))
    }

    /// Reads `roster.json` if present, otherwise the example party.
    public static func load(from url: URL?) -> Roster {
        guard let url, let data = try? Data(contentsOf: url),
              let roster = try? JSONDecoder().decode(Roster.self, from: data)
        else { return .fallback }
        return roster
    }

    /// Default location: ~/Library/Application Support/Tavern/roster.json
    public static func defaultURL() -> URL? {
        TavernPaths.file("roster.json")
    }

    /// An example party for a first launch without roster.json: one local Pi agent and one
    /// hosted agent. See docs/roster.example.json for every field.
    public static let fallback = Roster(
        members: [
            RosterMember(id: "scout", name: "Scout", kind: .pi, host: "This Mac", partyClass: "Ranger", avatarColor: "#3d7a5a",
                         piLaunch: ["/usr/bin/env", "pi", "--mode", "rpc"], tailscaleName: "self"),
            RosterMember(id: "sage", name: "Sage", kind: .hosted, partyClass: "Bard", avatarColor: "#4b4b8f"),
        ],
        mailProjects: []
    )
}
