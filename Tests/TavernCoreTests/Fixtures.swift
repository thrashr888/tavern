@testable import TavernCore

extension Roster {
    /// A full test party: three Pi agents on three machines and six hosted members, with the
    /// owner, mail and project fields the tests exercise. Not anyone's real setup.
    static let fixture = Roster(
        members: [
            RosterMember(id: "tally", name: "Tally", kind: .pi, host: "Server", partyClass: "Forge Cleric", animal: "Pine marten",
                         avatarColor: "#2f7d4f", tailscaleName: "server-a", platform: "Pi", owns: ["agentkernel", "Rookery"]),
            RosterMember(id: "ember", name: "Ember", kind: .pi, host: "Laptop", partyClass: "Cleric", animal: "Red fox",
                         avatarColor: "#b4532a", tailscaleName: "laptop-b", platform: "Pi", owns: ["Cider"]),
            RosterMember(id: "flint", name: "Flint", kind: .pi, host: "Desk", partyClass: "Wayfinder", avatarColor: "#5b6470",
                         piLaunch: ["/usr/bin/env", "pi", "--mode", "rpc"], tailscaleName: "self", platform: "Pi"),
            RosterMember(id: "rook", name: "Rook", kind: .hosted, partyClass: "Ranger", avatarColor: "#3d5a80",
                         platform: "Instinct", owns: ["Party"], mailFrom: ["@mail.instinct.example"], signOffs: ["Instinct"]),
            RosterMember(id: "quill", name: "Quill", kind: .hosted, partyClass: "Bard", avatarColor: "#4b4b8f",
                         projects: ["tavern", "alchemy"], platform: "Claude"),
            RosterMember(id: "wololo", name: "Wololo", kind: .hosted, partyClass: "Artificer", avatarColor: "#8a5a9e", projects: ["habitable"]),
            RosterMember(id: "flux", name: "Flux", kind: .hosted, partyClass: "Wizard", avatarColor: "#9e7a2f"),
            RosterMember(id: "peter", name: "Peter", kind: .hosted, partyClass: "Druid", animal: "Penguin", avatarColor: "#6a7f3a",
                         owns: ["Systemd runner"]),
            RosterMember(id: "wren", name: "Wren", kind: .hosted, partyClass: "Rogue", avatarColor: "#7a3d4f"),
        ],
        mailProjects: [
            MailProject(id: "tavern", label: "Tavern"),
            MailProject(id: "alchemy", label: "Alchemy"),
            MailProject(id: "party", label: "Party"),
            MailProject(id: "habitable", label: "Habitable"),
        ],
        partyName: "Party", mailLabel: "Party", ownerName: "Sam", linearTeam: "TEAM"
    )
}
