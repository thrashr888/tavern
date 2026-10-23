import BackgroundTasks
import Combine
import SwiftUI
import TavernCore
import UserNotifications

@main
struct TavernPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @StateObject private var pap = PAPPhone()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(pap)
                .onAppear {
                    model.pap = pap
                    model.requestNotifications()
                }
                .onOpenURL { pap.handle($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.inBackground = phase != .active
            if phase == .background { PhoneModel.scheduleHeartbeat() }
        }
        // The phone agents' heartbeat while the app is closed. iOS picks when this runs (often
        // much later than asked, and less on low battery), so beats also run while it's open.
        .backgroundTask(.appRefresh(PhoneModel.heartbeatTask)) {
            await model.beat()
            PhoneModel.scheduleHeartbeat()
        }
    }
}

/// Home (what needs you, what everyone's doing) and the agent list, each opening a thread.
struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    /// TAVERN_OPEN (an agent id) opens that thread at launch, for the Simulator and screenshots.
    @State private var path: [String] = ProcessInfo.processInfo.environment["TAVERN_OPEN"].flatMap { $0.isEmpty ? nil : [$0] } ?? []
    @State private var tab = ProcessInfo.processInfo.environment["TAVERN_TAB"] ?? "home"

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                HomeView()
                    .navigationDestination(for: String.self) { id in destination(id) }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag("home")

            NavigationStack {
                AgentListView()
                    .navigationDestination(for: String.self) { id in destination(id) }
            }
            .tabItem { Label("Party", systemImage: "person.3") }
            .tag("agents")

            NavigationStack { SpellsView() }
                .tabItem { Label("Spells", systemImage: "sparkles") }
                .tag("spells")

            NavigationStack { MailView() }
                .tabItem { Label("Mail", systemImage: "envelope") }
                .tag("mail")

            NavigationStack { GoalsView() }
                .tabItem { Label("Goals", systemImage: "list.bullet.rectangle") }
                .tag("linear")
        }
        .tint(Color.tavernAccent)
    }

    @ViewBuilder private func destination(_ id: String) -> some View {
        if let agent = model.agents.first(where: { $0.id == id }), let session = model.session(for: agent) {
            ThreadView(agent: agent, session: session)
        }
    }
}

/// One agent the phone talks to: a durable host's TCP address, or one that lives on the phone
/// (LocalAgent.swift).
struct PhoneAgent: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    /// True for an agent on the iPhone itself; host and port are unused.
    var local: Bool?
    /// What a phone agent is for, in Paul's words, from Add to the party.
    var role: String?

    var isLocal: Bool { local == true }
    var endpoint: String { isLocal ? "This iPhone" : "\(host):\(port)" }

    static func onPhone(name: String, role: String? = nil) -> PhoneAgent {
        PhoneAgent(id: name.lowercased(), name: name, host: "", port: 0, local: true, role: role)
    }
}

/// The agents (kept on the phone) and a live session for each, plus local notifications when
/// one needs you or finishes while the app is in the background. No push: it only notifies
/// while iOS lets it run.
@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var agents: [PhoneAgent] = []
    private(set) var sessions: [String: PiAgentSession] = [:]
    private var watchers: [String: AnyCancellable] = [:]
    private var lastPresence: [String: PiAgentSession.Presence] = [:]
    private var lastDialog: [String: String] = [:]
    var inBackground = false
    private let store: EventStore?
    /// Location and battery, lent to every agent while the app is connected.
    private let sensors = PhoneSensors()
    /// Mail and Linear for the phone's own agents, through the app's PAP login.
    weak var pap: PAPPhone?
    private static let key = "tavern.phone.agents"
    /// Set once the phone has made its first agent of its own, so removing it sticks.
    private static let setUpKey = "tavern.phone.localAgentSetUp"
    nonisolated static let heartbeatTask = "dev.thrashr888.tavern.phone.heartbeat"
    private var heartbeatTimer: AnyCancellable?

    init() {
        store = try? EventStore(path: EventStore.defaultURL().path)
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([PhoneAgent].self, from: data) {
            agents = saved
        }
        // TAVERN_AGENTS ("Flint=127.0.0.1:19011,Ember=…", from scripts/phone.sh) sets the list.
        if let seed = ProcessInfo.processInfo.environment["TAVERN_AGENTS"], !seed.isEmpty {
            agents = Self.parse(seed)
            save()
        }
        #if !targetEnvironment(simulator)
        // On a real iPhone, loopback is the phone itself: those entries (the Simulator's demo
        // agent and its SSH forwards) can never connect.
        agents.removeAll { !$0.isLocal && ["127.0.0.1", "localhost", "::1"].contains($0.host) }
        #endif
        // The party's first member that lives on the phone sets itself up on first launch.
        if !UserDefaults.standard.bool(forKey: Self.setUpKey) {
            UserDefaults.standard.set(true, forKey: Self.setUpKey)
            if !agents.contains(where: \.isLocal) {
                agents.insert(.onPhone(name: "Pip", role: "Paul's pocket helper: where he is, his battery, his inbox and Linear goals, and remembering things for him."), at: 0)
            }
            save()
        }
        agents.forEach(start)
        // While the app is open, a due beat runs within a minute.
        heartbeatTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in Task { await self?.beat() } }
    }

    /// Runs the phone agents' due heartbeats and waits for any turn they start.
    func beat() async {
        await LocalAgentRuntime.beatDue()
    }

    /// Asks iOS for a background refresh in 15 minutes at the soonest; only due agents beat.
    nonisolated static func scheduleHeartbeat() {
        let request = BGAppRefreshTaskRequest(identifier: heartbeatTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func parse(_ text: String) -> [PhoneAgent] {
        text.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let colon = parts[1].lastIndex(of: ":"),
                  let port = UInt16(parts[1][parts[1].index(after: colon)...]) else { return nil }
            return PhoneAgent(id: parts[0].lowercased(), name: parts[0], host: String(parts[1][..<colon]), port: port)
        }
    }

    func session(for agent: PhoneAgent) -> PiAgentSession? { sessions[agent.id] }

    /// Connects (and keeps reconnecting) so Home and the list can show who needs you.
    private func start(_ agent: PhoneAgent) {
        guard let store, sessions[agent.id] == nil else { return }
        let session: PiAgentSession
        if agent.isLocal {
            let runtime = LocalAgentRuntime.runtime(for: agent, reach: reach)
            session = PiAgentSession(agentID: agent.id, store: store) { LocalAgentTransport(runtime: runtime) }
        } else {
            session = PiAgentSession(agentID: agent.id, store: store) { PiTCPTransport(host: agent.host, port: agent.port) }
            session.lentTools = PhoneSensors.tools
            session.lentToolHandler = { [sensors] tool, arguments in try await sensors.answer(tool, arguments) }
        }
        sessions[agent.id] = session
        watchers[agent.id] = session.$dialog.combineLatest(session.$presence)
            .sink { [weak self] dialog, presence in
                Task { @MainActor in self?.changed(agent: agent, dialog: dialog, presence: presence) }
            }
        Task { await session.connect() }
    }

    /// What a phone agent's tools reach.
    private var reach: LocalAgentRuntime.Reach {
        LocalAgentRuntime.Reach(
            sensor: { [sensors] tool in try await sensors.answer(tool, .object([:])) },
            inbox: { [weak self] in
                guard let pap = self?.pap, pap.signedIn else { throw PhoneSensors.Failure(errorDescription: "Sign in to Personal Agent Proxy on the Mail tab first.") }
                return try await pap.inbox()
            },
            goals: { [weak self] in
                guard let pap = self?.pap, pap.signedIn else { throw PhoneSensors.Failure(errorDescription: "Sign in to Personal Agent Proxy on the Goals tab first.") }
                return try await pap.goals()
            })
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
            watchers.removeValue(forKey: agent.id)
            if let session = sessions.removeValue(forKey: agent.id) { Task { await session.disconnect() } }
            if agent.isLocal { LocalAgentRuntime.forget(agent) }
        }
        agents.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(agents) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Notifications

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func changed(agent: PhoneAgent, dialog: PiDialog?, presence: PiAgentSession.Presence) {
        defer {
            lastPresence[agent.id] = presence
            lastDialog[agent.id] = dialog?.id
        }
        guard inBackground else { return }
        if let dialog, lastDialog[agent.id] != dialog.id {
            notify("\(agent.name) is waiting on you", dialog.title, id: "dialog-\(agent.id)-\(dialog.id)")
        } else if lastPresence[agent.id] == .working, presence == .idle {
            let reply = sessions[agent.id]?.transcript.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text ?? "The turn settled."
            notify("\(agent.name) finished", String(reply.prefix(160)), id: "done-\(agent.id)-\(Date().timeIntervalSince1970)")
        }
    }

    private func notify(_ title: String, _ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
