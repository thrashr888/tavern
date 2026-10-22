import AppKit
import SwiftUI
import TavernCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// Last open page, by stable Tavern id. Restored at launch (Dashboard on first launch).
    @SceneStorage("tavern.page") private var pageKey: String = ""
    @AppStorage(TextScale.storageKey) private var textScale = TextScale.standard
    @State private var selection: Page?
    @State private var searching = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .themedSidebar(Theme.current)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232)
                .splitAutosave("sidebar")
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView(selection: $selection)
            case .agent(let id):
                AgentThreadView(agentID: id)
            case .member(let id):
                MemberView(memberID: id, selection: $selection)
            case .mail(let project):
                MailView(projectID: project)
            case .settings:
                AgentConfigView()
            case .goals:
                GoalsView(page: $selection)
            case .services:
                ServicesView()
            case .spellbook(let spell):
                SpellbookView(book: model.spellbook, page: $selection, spellID: spell)
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        // ⌘K floats over the window; a click outside it closes it.
        .overlay {
            if searching {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { searching = false }
                    SearchPalette(selection: $selection) { searching = false }
                        .environmentObject(model)
                        .themedSurface()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tavernOpenSearch)) { _ in searching = true }
        // ⌘K on top: close the sidebar's hover card and hold new ones until it's gone.
        .onChange(of: searching) { _, open in QuickCardController.shared.setSuspended(open) }
        // ⌘F finds in the open conversation; pages without one open Search instead.
        .onReceive(NotificationCenter.default.publisher(for: .tavernFind)) { _ in
            switch selection ?? .dashboard {
            case .agent: break
            case .member(let id) where model.roster.member(id: id)?.imessage != nil: break
            default: searching = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tavernOpenGoals)) { _ in selection = .goals }
        .onReceive(NotificationCenter.default.publisher(for: .tavernOpenPage)) { note in
            if let key = note.object as? String, let page = Page(storageKey: key) {
                selection = Page.restore(page.storageKey, roster: model.roster) == page ? page : selection
            }
        }
        .tavernFont(.body)
        .environment(\.textScale, textScale)
        .background {
            // ⌘+ (shifted =) as a second shortcut for View > Bigger, which owns ⌘=.
            Button("") { textScale = TextScale.bigger(than: textScale) }
                .keyboardShortcut("+", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            // TAVERN_PAGE (a page storage key, e.g. "agent:flint") opens a page at launch, for testing.
            let requested = ProcessInfo.processInfo.environment["TAVERN_PAGE"]
            selection = Page.restore(requested ?? (pageKey.isEmpty ? nil : pageKey), roster: model.roster)
            // TAVERN_SETTINGS=1 opens Settings and TAVERN_SEARCH=1 opens ⌘K, for screenshots.
            if ProcessInfo.processInfo.environment["TAVERN_SETTINGS"] == "1" { openSettings() }
            if ProcessInfo.processInfo.environment["TAVERN_SEARCH"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { searching = true }
            }
        }
        .task { await model.watchTailscale() }
        .task { await model.watchWake() }
        .task { await model.startMail() }
        .task { model.startNotifications() }
        .task(id: "\(model.roster.spellbookRepo ?? "")#\(model.roster.spellbookBranch ?? "")") { await model.spellbook.watch(roster: model.roster) }
        .onChange(of: selection) { _, newValue in
            if let newValue { pageKey = newValue.storageKey }
            searching = false // a click in the sidebar is a click outside ⌘K too
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modifiers: ModifierWatcher
    @Binding var selection: Page?

    /// The Spellbook row stays selected while a spell is open on it.
    private var spellbookPage: Page {
        if case .spellbook = selection { return selection ?? .spellbook(spell: nil) }
        return .spellbook(spell: nil)
    }

    var body: some View {
        List(selection: $selection) {
            SidebarLink(selection: selection, value: Page.dashboard) {
                row { Label("Dashboard", systemImage: "square.grid.2x2") } hint: { ShortcutHint(page: .dashboard) }
            }
            SidebarLink(selection: selection, value: Page.goals) {
                row { Label("Goals", systemImage: "checklist") } hint: { ShortcutHint(page: .goals) }
            }
            if model.roster.spellbookRepo != nil {
                SidebarLink(selection: selection, value: spellbookPage) {
                    Label("Spellbook", systemImage: "book.closed")
                }
            }
            Button {
                NotificationCenter.default.post(name: .tavernOpenSearch, object: nil)
            } label: {
                HStack {
                    Label("Search", systemImage: "magnifyingglass")
                    Spacer()
                    Text("⌘K").tavernFont(.caption).foregroundStyle(.secondary)
                }
                // The whole row clicks, not just the label.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The whole party: Pi agents live, hosted members by their last mail.
            Section("Party") {
                // The home agent (on this Mac) leads the list.
                ForEach(homeFirst(model.roster.piAgents)) { agent in
                    SidebarLink(selection: selection, value: Page.agent(id: agent.id)) {
                        row {
                            if let session = model.session(for: agent.id) {
                                PiAgentRow(agent: agent, session: session, needs: model.attentionCounts[agent.id] ?? 0)
                            } else {
                                AgentRow(agent: agent, status: "not connected", needs: model.attentionCounts[agent.id] ?? 0)
                            }
                        } hint: { ShortcutHint(page: .agent(id: agent.id)) }
                        .memberQuickCard(agent)
                    }
                }
                ForEach(model.roster.members.filter { $0.kind == .hosted }) { member in
                    SidebarLink(selection: selection, value: Page.member(id: member.id)) {
                        row {
                            HostedMemberRow(member: member, lastSeen: model.lastSeen[member.id], needs: model.attentionCounts[member.id] ?? 0)
                        } hint: { ShortcutHint(page: .member(id: member.id)) }
                        .memberQuickCard(member)
                    }
                }
            }

            Section("Machines") {
                SidebarLink(selection: selection, value: Page.services) {
                    row { Label("Services", systemImage: "shippingbox") } hint: { ShortcutHint(page: .services) }
                }
            }

            Section("Mail") {
                SidebarLink(selection: selection, value: Page.mail(project: nil)) {
                    row { Label("All threads", systemImage: "tray") } hint: { ShortcutHint(page: .mail(project: nil)) }
                }
                ForEach(model.roster.mailProjects) { project in
                    SidebarLink(selection: selection, value: Page.mail(project: project.id)) {
                        Label(project.label, systemImage: "number")
                    }
                }
            }

            // The party's shared references, opened in the browser.
            Section("Lore") {
                ForEach(model.roster.loreLinks) { link in
                    Button { NSWorkspace.shared.open(link.url) } label: {
                        HStack {
                            Label(link.title, systemImage: link.symbol)
                            Spacer()
                            Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(link.url.absoluteString)
                }
            }

            Section {
                SidebarLink(selection: selection, value: Page.settings) {
                    Label("Agent config", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarHighlight(custom: Theme.current.palette != nil))
        // Breathing room: rows on a 36pt rhythm, and space under the traffic lights.
        .environment(\.defaultMinListRowHeight, 36)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 6) }
        .animation(.easeOut(duration: 0.12), value: modifiers.held)
    }

    /// The home agent first, the rest in roster order.
    private func homeFirst(_ agents: [RosterMember]) -> [RosterMember] {
        let home = model.roster.homeAgentID
        return agents.filter { $0.id == home } + agents.filter { $0.id != home }
    }

    private func row<Content: View, Hint: View>(@ViewBuilder _ content: () -> Content, @ViewBuilder hint: () -> Hint) -> some View {
        HStack {
            content()
            Spacer(minLength: 4)
            hint()
        }
    }
}

/// A hosted member: avatar, class, and when they last wrote to the party.
private struct HostedMemberRow: View {
    let member: RosterMember
    let lastSeen: Date?
    var needs = 0

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(member: member, size: 32, hoverCard: false)
                .overlay(alignment: .topTrailing) { NeedsDot(count: needs).offset(x: 4, y: -3) }
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name).fontWeight(.medium)
                Text([member.partyClass, lastSeen.map { "seen \($0.formatted(.relative(presentation: .named)))" } ?? "mail only"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A sidebar row for a Pi agent with a local launch, showing its live presence.
private struct PiAgentRow: View {
    let agent: RosterMember
    @ObservedObject var session: PiAgentSession
    var needs = 0

    var body: some View {
        AgentRow(agent: agent, status: session.dialog != nil ? "waiting on you" : session.presence.label, needs: needs)
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var model: AppModel
    let agent: RosterMember
    let status: String
    var needs = 0

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(member: agent, size: 40, hoverCard: false)
                .overlay(alignment: .topTrailing) { NeedsDot(count: needs).offset(x: 3, y: -2) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(agent.name).fontWeight(.semibold)
                    if model.roster.homeAgentID == agent.id { HomeBadge() }
                }
                if let partyClass = agent.partyClass {
                    Text(partyClass).tavernFont(.caption).foregroundStyle(.secondary)
                }
                Text([agent.host, status].compactMap { $0 }.joined(separator: " · "))
                    .tavernFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AvatarView: View {
    let member: RosterMember
    var size: CGFloat = 28
    /// Off in the sidebar, where the whole row shows the quick-reply card instead.
    var hoverCard = true

    var body: some View {
        Group {
            if let image = PartyArt.avatar(member.id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(hex: member.avatarColor).overlay(
                    Text(member.initial)
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(hex: member.avatarColor), lineWidth: max(1, size / 24)))
        .accessibilityLabel(member.name)
        .modifier(OptionalHoverCard(member: member, enabled: hoverCard))
    }
}

private struct OptionalHoverCard: ViewModifier {
    let member: RosterMember
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.memberHoverCard(member) } else { content }
    }
}

extension View {
    /// After a short hover, a card saying who this is: class, service and machine, model, presence.
    func memberHoverCard(_ member: RosterMember) -> some View {
        modifier(MemberHoverCardModifier(member: member))
    }
}

private struct MemberHoverCardModifier: ViewModifier {
    let member: RosterMember
    @State private var hovering = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(550))
                        if hovering { showing = true }
                    }
                } else {
                    showing = false
                }
            }
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                MemberHoverCard(member: member).themedSurface()
            }
    }
}

struct MemberHoverCard: View {
    let member: RosterMember
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let image = PartyArt.avatar(member.id) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(hex: member.avatarColor)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name).tavernFont(.headline, weight: .semibold)
                    Text([member.partyClass, member.animal].compactMap { $0 }.joined(separator: " · "))
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                if let where_ = whereItRuns { row("Runs", where_) }
                if let model = model.session(for: member.id)?.config.model?.shortName { row("Model", model) }
                if let usage = model.session(for: member.id)?.config.usage { row("Spent", usage.summary) }
                if let presence { row("Status", presence) }
                if let owns = owned, !owns.isEmpty { row("Owns", owns) }
            }
            .tavernFont(.caption)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    /// "Claude", "Pi on M5", "Instinct · iMessage".
    private var whereItRuns: String? {
        var parts: [String] = []
        if let platform = member.platform { parts.append(member.host.map { "\(platform) on \($0)" } ?? platform) }
        else if let host = member.host { parts.append(host) }
        if member.imessage != nil { parts.append("iMessage") }
        if let relay = member.relay.flatMap({ model.roster.member(id: $0) }) { parts.append("via \(relay.name)") }
        return parts.isEmpty ? (member.kind == .hosted ? "\(model.roster.party) mail" : nil) : parts.joined(separator: " · ")
    }

    private var presence: String? {
        if let session = model.session(for: member.id) {
            return session.dialog != nil ? "Waiting on you" : session.presence.label.capitalized
        }
        return model.lastSeen[member.id].map { "Wrote \($0.formatted(.relative(presentation: .named)))" }
    }

    private var owned: String? {
        let all = (member.owns ?? []).sorted()
        return all.isEmpty ? nil : all.joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// Party art from ~/Library/Application Support/Tavern: `portrait.png` (or .jpg/.heic) and
/// `avatars/<id>.png`. Members without art get a colored initial. Loaded once per name.
@MainActor
enum PartyArt {
    private static var cache: [String: NSImage?] = [:]

    static var portrait: NSImage? { image("portrait") }
    static func avatar(_ id: String) -> NSImage? { image("avatars/\(id)") }

    /// Forgets loaded art, after Settings changes it.
    static func reload() { cache.removeAll() }

    /// Sets `portrait` or `avatars/<id>` from an image file the user picked (saved as PNG), or
    /// removes it when `source` is nil. The new image is read and written before any old file
    /// goes, so a bad pick, or picking the current file itself, never loses the art.
    static func set(_ name: String, from source: URL?) throws {
        // Only "portrait" or "avatars/<id>": never a path that leaves the Tavern folder.
        guard let base = TavernPaths.base, !name.contains(".."), !name.hasPrefix("/") else { return }
        let fm = FileManager.default
        defer { reload() }
        var keep: String?
        if let source {
            guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let destination = base.appendingPathComponent("\(name).png")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            keep = "png"
        }
        for ext in ["png", "jpg", "jpeg", "heic"] where ext != keep {
            try? fm.removeItem(at: base.appendingPathComponent("\(name).\(ext)"))
        }
    }

    private static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var found: NSImage?
        if let base = TavernPaths.base {
            for ext in ["png", "jpg", "jpeg", "heic"] {
                if let image = NSImage(contentsOf: base.appendingPathComponent("\(name).\(ext)")) { found = image; break }
            }
        }
        cache[name] = found
        return found
    }
}

extension Color {
    /// "#rrggbb" to Color; gray when the string doesn't parse.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

extension Notification.Name {
    /// Opens the ⌘K palette (from the menu command or the sidebar).
    static let tavernOpenSearch = Notification.Name("tavern.openSearch")
    /// Opens Goals; set `AppModel.focusedGoal` first to select an issue.
    static let tavernOpenGoals = Notification.Name("tavern.openGoals")
}

/// Edit > Search… (⌘K).
struct SearchCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search…") { NotificationCenter.default.post(name: .tavernOpenSearch, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Find…") { NotificationCenter.default.post(name: .tavernFind, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { NotificationCenter.default.post(name: .tavernFindNext, object: nil) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { NotificationCenter.default.post(name: .tavernFindPrevious, object: nil) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

extension LoreLink {
    var symbol: String {
        switch kind {
        case .doc: return "doc.text"
        case .sheet: return "tablecells"
        case .linear: return "checklist"
        case .folder: return "folder"
        case .link: return "link"
        }
    }
}

/// The orange "needs you" mark on a party member's avatar: a dot, with a number from two up.
struct NeedsDot: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Group {
                if count > 1 {
                    Text("\(min(count, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                } else {
                    Color.clear.frame(width: 11, height: 11)
                }
            }
            .background(Color.orange, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .accessibilityLabel(count == 1 ? "Needs you" : "\(count) things need you")
        }
    }
}

/// Marks the home agent: the Pi agent on this Mac, which can set Tavern up through its tools.
struct HomeBadge: View {
    var body: some View {
        Image(systemName: "house.fill")
            .imageScale(.small)
            .foregroundStyle(Color.tavernAccent)
            .help("On this Mac: it can set up Tavern with Tavern's own tools, asking you first")
    }
}
