import Foundation

extension Roster {
    /// The Pi agent on this Mac, the one Tavern lets set it up: the first agent whose host is
    /// reached on loopback. Nil when every agent lives elsewhere.
    public var homeAgentID: String? {
        piAgents.first { agent in
            guard case .tcp(let host, _)? = agent.endpoint else { return false }
            return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        }?.id
    }
}
