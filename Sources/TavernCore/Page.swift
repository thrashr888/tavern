import Foundation

/// A sidebar destination. Tavern reopens to the last one (2026-10-15), so each page has a
/// stable storage key built from Tavern ids, never from display names.
public enum Page: Hashable, Sendable {
    case dashboard
    case projects
    /// Saved inline widgets from all agents.
    case pinnedWidgets
    case project(id: String)
    /// A Pi agent's single thread. No session list, by design.
    case agent(id: String)
    /// A hosted party member (mail only): their recent mail, presence and tasks.
    case member(id: String)
    /// Mail filtered to a project, or all threads when `project` is nil.
    case mail(project: String?)
    case settings
    /// Open PAUL issues from Linear, read-only (plan 3f).
    case goals
    /// Docker containers on the Pi agents' machines, read-only.
    case services
    /// The party's spells, read-only, with one open by its SB id (never its title).
    case spellbook(spell: String?)

    public var storageKey: String {
        switch self {
        case .dashboard: return "dashboard"
        case .pinnedWidgets: return "pinned-widgets"
        case .projects: return "home"
        case .project(let id): return "project:\(id)"
        case .agent(let id): return "agent:\(id)"
        case .member(let id): return "member:\(id)"
        case .mail(let project): return "mail:\(project ?? "all")"
        case .settings: return "settings"
        case .goals: return "goals"
        case .services: return "services"
        case .spellbook(let spell): return spell.map { "spellbook:\($0)" } ?? "spellbook"
        }
    }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count) {
        case ("dashboard", 1): self = .dashboard
        case ("pinned-widgets", 1): self = .pinnedWidgets
        case ("projects", 1), ("home", 1): self = .projects
        case ("project", 2): self = .project(id: parts[1])
        case ("settings", 1): self = .settings
        case ("goals", 1): self = .goals
        case ("services", 1): self = .services
        case ("spellbook", 1): self = .spellbook(spell: nil)
        case ("spellbook", 2): self = .spellbook(spell: parts[1])
        case ("agent", 2): self = .agent(id: parts[1])
        case ("member", 2): self = .member(id: parts[1])
        case ("mail", 2): self = .mail(project: parts[1] == "all" ? nil : parts[1])
        default: return nil
        }
    }

    /// The page to open at launch. Falls back to Home on first launch, or when the stored
    /// page points at an agent or project that is no longer in the roster.
    public static func restore(_ storageKey: String?, roster: Roster) -> Page {
        guard let storageKey, let page = Page(storageKey: storageKey) else { return .projects }
        switch page {
        case .agent(let id):
            return roster.member(id: id)?.kind == .pi ? page : .projects
        case .member(let id):
            return roster.member(id: id) == nil ? .projects : page
        case .mail(let project?):
            return roster.mailProjects.contains { $0.id == project } ? page : .projects
        default:
            return page
        }
    }
}

extension Page {
    /// Where a party member lives: a Pi agent's thread, or a hosted member's page.
    public static func forMember(_ member: RosterMember) -> Page {
        member.kind == .pi ? .agent(id: member.id) : .member(id: member.id)
    }
}
