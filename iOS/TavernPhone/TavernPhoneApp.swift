import SwiftUI
import TavernCore

@main
struct TavernPhoneApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            AgentListView().environmentObject(model)
        }
    }
}

/// One Pi agent the phone talks to: a durable host's TCP address.
struct PhoneAgent: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
}

/// The agents (kept on the phone) and a live session for each.
@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var agents: [PhoneAgent] = []
    private(set) var sessions: [String: PiAgentSession] = [:]
    private let store: EventStore?
    private static let key = "tavern.phone.agents"

    init() {
        store = try? EventStore(path: EventStore.defaultURL().path)
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([PhoneAgent].self, from: data) {
            agents = saved
        }
        // TAVERN_AGENTS ("Flint=127.0.0.1:19011,Ember=…") seeds the list, for the Simulator.
        if agents.isEmpty, let seed = ProcessInfo.processInfo.environment["TAVERN_AGENTS"] {
            agents = Self.parse(seed)
            save()
        }
        agents.forEach(start)
    }

    static func parse(_ text: String) -> [PhoneAgent] {
        text.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let colon = parts[1].lastIndex(of: ":"),
                  let port = UInt16(parts[1][parts[1].index(after: colon)...]) else { return nil }
            let host = String(parts[1][..<colon])
            return PhoneAgent(id: parts[0].lowercased(), name: parts[0], host: host, port: port)
        }
    }

    func session(for agent: PhoneAgent) -> PiAgentSession? { sessions[agent.id] }

    /// Connects (and keeps reconnecting) so the list can show who needs you.
    private func start(_ agent: PhoneAgent) {
        guard let store, sessions[agent.id] == nil else { return }
        let session = PiAgentSession(agentID: agent.id, store: store) { PiTCPTransport(host: agent.host, port: agent.port) }
        sessions[agent.id] = session
        Task { await session.connect() }
    }

    func add(_ agent: PhoneAgent) {
        if let old = sessions.removeValue(forKey: agent.id) { Task { await old.disconnect() } }
        agents.removeAll { $0.id == agent.id }
        agents.append(agent)
        save()
        start(agent)
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let agent = agents[index]
            if let session = sessions.removeValue(forKey: agent.id) { Task { await session.disconnect() } }
        }
        agents.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(agents) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
