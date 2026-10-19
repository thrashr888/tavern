import Foundation

/// A sidebar destination. Tavern reopens to the last one (2026-10-15), so each page has a
/// stable storage key built from Tavern ids, never from display names.
public enum Page: Hashable, Sendable {
    case dashboard
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

    public var storageKey: String {
        switch self {
        case .dashboard: return "dashboard"
        case .agent(let id): return "agent:\(id)"
        case .member(let id): return "member:\(id)"
        case .mail(let project): return "mail:\(project ?? "all")"
        case .settings: return "settings"
        case .goals: return "goals"
        case .services: return "services"
        }
    }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count) {
        case ("dashboard", 1): self = .dashboard
        case ("settings", 1): self = .settings
        case ("goals", 1): self = .goals
        case ("services", 1): self = .services
        case ("agent", 2): self = .agent(id: parts[1])
        case ("member", 2): self = .member(id: parts[1])
        case ("mail", 2): self = .mail(project: parts[1] == "all" ? nil : parts[1])
        default: return nil
        }
    }

    /// The page to open at launch. Falls back to the Dashboard on first launch, or when the stored
    /// page points at an agent or project that is no longer in the roster.
    public static func restore(_ storageKey: String?, roster: Roster) -> Page {
        guard let storageKey, let page = Page(storageKey: storageKey) else { return .dashboard }
        switch page {
        case .agent(let id):
            return roster.member(id: id)?.kind == .pi ? page : .dashboard
        case .member(let id):
            return roster.member(id: id) == nil ? .dashboard : page
        case .mail(let project?):
            return roster.mailProjects.contains { $0.id == project } ? page : .dashboard
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
