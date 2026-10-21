import AppKit
import SwiftUI
import TavernCore

/// Tavern > Settings…: the party, its members and lore, instead of editing roster.json by hand.
/// The file is still the store; every change is saved to it a moment after it's made.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// Every edit goes straight through `updateRoster` onto the current roster, so a member added
    /// from the Dashboard meanwhile is never lost to an older copy.
    private var roster: Binding<Roster> {
        Binding(get: { model.roster }, set: { new in model.updateRoster { $0 = new } })
    }

    var body: some View {
        TabView {
            PartySettings(roster: roster)
                .tabItem { Label("Party", systemImage: "flag") }
            MembersSettings(roster: roster)
                .tabItem { Label("Members", systemImage: "person.3") }
            LoreSettings(roster: roster)
                .tabItem { Label("Lore", systemImage: "books.vertical") }
            ProxySettings()
                .tabItem { Label("Connections", systemImage: "link") }
        }
        .disabled(model.rosterLoadError != nil)
        .frame(width: 760, height: 560)
        .safeAreaInset(edge: .bottom) {
            if let error = model.rosterLoadError ?? model.rosterSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .tavernFont(.caption).foregroundStyle(.orange).padding(8)
            }
        }
    }
}

// MARK: - Party

private struct PartySettings: View {
    @EnvironmentObject private var model: AppModel
    @Binding var roster: Roster
    @State private var artError: String?

    var body: some View {
        Form {
            Section("Appearance") { ThemePicker() }
            Section {
                TextField("Party name", text: optional(\.partyName), prompt: Text("Party"))
                TextField("Your name", text: optional(\.ownerName), prompt: Text("me"))
                    .help("How the party's mail addresses you (\"Needs from Paul: …\").")
                LabeledContent("Party image") {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = PartyArt.portrait {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 260, maxHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading) {
                            Button(PartyArt.portrait == nil ? "Choose Image…" : "Change…") { pick("portrait") }
                            if PartyArt.portrait != nil {
                                Button("Remove", role: .destructive) { setArt("portrait", nil) }
                            }
                        }
                    }
                }
                if let artError {
                    Text(artError).tavernFont(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("The image heads the Dashboard.").foregroundStyle(.secondary)
            }

            Section {
                TextField("Mail label", text: optional(\.mailLabel), prompt: Text(roster.party))
                    .help("The Gmail label Tavern reads. Defaults to the party name.")
                TextField("Linear team key", text: optional(\.linearTeam), prompt: Text("e.g. ENG"))
                    .help("Goals reads this team. Empty turns Goals off.")
                LabeledContent("Mail projects") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($roster.mailProjects) { $project in
                            HStack {
                                TextField("Label", text: $project.label).labelsHidden()
                                Button { roster.mailProjects.removeAll { $0.id == project.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Project") {
                            var n = roster.mailProjects.count + 1
                            while roster.mailProjects.contains(where: { $0.id == "project-\(n)" }) { n += 1 }
                            roster.mailProjects.append(MailProject(id: "project-\(n)", label: "New project"))
                        }
                    }
                }
            } header: {
                Text("Mail and goals")
            } footer: {
                Text("A new mail label or Linear team takes effect the next time Tavern opens.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func optional(_ keyPath: WritableKeyPath<Roster, String?>) -> Binding<String> {
        Binding(get: { roster[keyPath: keyPath] ?? "" },
                set: { roster[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private func pick(_ name: String) {
        if let url = ImagePicker.choose() { setArt(name, url) }
    }

    private func setArt(_ name: String, _ url: URL?) {
        do {
            try PartyArt.set(name, from: url)
            artError = nil
        } catch {
            artError = "Couldn't use that image."
        }
        model.objectWillChange.send()
    }
}

enum ImagePicker {
    /// An open panel for one image; nil when cancelled.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Members

private struct MembersSettings: View {
    @EnvironmentObject private var model: AppModel
    @Binding var roster: Roster
    @State private var selection: String?
    @State private var confirmingRemove: RosterMember?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    if !model.discovered.isEmpty || model.discovering {
                        Section("Found on your machines") {
                            ForEach(model.discovered) { agent in
                                FoundRow(agent: agent) {
                                    Task {
                                        await model.add(agent)
                                        if model.roster.member(id: agent.id) != nil { selection = agent.id }
                                    }
                                }
                            }
                            if model.discovering {
                                Label("Looking…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section(model.hasRosterFile ? "Party" : "Example party") {
                        ForEach(roster.members) { member in
                            HStack(spacing: 8) {
                                AvatarView(member: member, size: 22, hoverCard: false)
                                Text(member.name)
                                Spacer()
                                Text(member.kind == .pi ? "Pi" : (member.platform ?? "Hosted")).tavernFont(.caption).foregroundStyle(.secondary)
                            }
                            .tag(member.id)
                        }
                        .onMove { roster.members.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Button("Pi Agent") { addMember(kind: .pi) }
                        Button("Hosted Member") { addMember(kind: .hosted) }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Button { confirmingRemove = roster.members.first { $0.id == selection } } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection.flatMap { roster.member(id: $0) } == nil)
                    Spacer()
                    Button("Look Again") {
                        model.clearDismissed()
                        Task { await model.discoverAgents() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.discovering)
                    .help("Look for pi-bundle agents on this Mac and, over SSH, on your tailnet.")
                }
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)

            Group {
                if let id = selection, let index = roster.members.firstIndex(where: { $0.id == id }) {
                    MemberForm(member: $roster.members[index])
                } else {
                    ContentUnavailableView("No member selected", systemImage: "person.crop.circle",
                                           description: Text("Add a found agent, or + to add one yourself."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if model.discovered.isEmpty { await model.discoverAgents() } }
        .confirmationDialog("Remove \(confirmingRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmingRemove != nil }, set: { if !$0 { confirmingRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let member = confirmingRemove {
                    roster.members.removeAll { $0.id == member.id }
                    selection = nil
                }
                confirmingRemove = nil
            }
        } message: {
            Text("Tavern stops showing them. Their mail, history and host stay as they are.")
        }
    }

    private func addMember(kind: RosterMember.Kind) {
        let name = kind == .pi ? "New Agent" : "New Member"
        var member = RosterMember(id: roster.newMemberID(for: name), name: name, kind: kind, avatarColor: "#6b5b95")
        if kind == .pi {
            member.platform = "Pi"
            member.host = "This Mac"
            member.tailscaleName = "self"
            member.piEndpoint = .tcp(host: "127.0.0.1", port: 19011)
        }
        roster.members.append(member)
        selection = member.id
    }
}

/// "Ember · M3 · answering   [Add]"
private struct FoundRow: View {
    @EnvironmentObject private var model: AppModel
    let agent: DiscoveredAgent
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: agent.card.avatarColor ?? "#6b5b95")).frame(width: 22, height: 22)
                .overlay(Text(String(agent.card.name.prefix(1))).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.card.name)
                Text(detail).tavernFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add", action: add).disabled(model.adding.contains(agent.id))
        }
    }

    private var detail: String {
        var parts = [agent.machine]
        if let model = agent.card.model { parts.append(model) }
        if agent.answering == false { parts.append("not answering") }
        return parts.joined(separator: " · ")
    }
}

private struct MemberForm: View {
    @EnvironmentObject private var model: AppModel
    @Binding var member: RosterMember
    @State private var artError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(member: member, size: 56, hoverCard: false)
                    VStack(alignment: .leading, spacing: 6) {
                        Button(PartyArt.avatar(member.id) == nil ? "Choose Avatar…" : "Change Avatar…") {
                            if let url = ImagePicker.choose() { setAvatar(url) }
                        }
                        if PartyArt.avatar(member.id) != nil {
                            Button("Use Color Instead", role: .destructive) { setAvatar(nil) }
                        }
                    }
                    Spacer()
                    ColorPicker("Color", selection: color, supportsOpacity: false)
                }
                if let artError { Text(artError).tavernFont(.caption).foregroundStyle(.orange) }
                TextField("Name", text: $member.name)
                TextField("Class", text: optional(\.partyClass), prompt: Text("e.g. Ranger"))
                TextField("Animal", text: optional(\.animal), prompt: Text("e.g. Fox"))
                TextField("Summary", text: optional(\.summary), prompt: Text("What they do for the party"), axis: .vertical)
                    .lineLimit(1...3)
            }

            Section("Where they run") {
                Picker("Kind", selection: $member.kind) {
                    Text("Pi agent").tag(RosterMember.Kind.pi)
                    Text("Hosted elsewhere").tag(RosterMember.Kind.hosted)
                }
                TextField("Machine", text: optional(\.host), prompt: Text("e.g. M3"))
                TextField("Platform", text: optional(\.platform), prompt: Text(member.kind == .pi ? "Pi" : "e.g. Claude"))
                if member.kind == .pi {
                    ConnectionEditor(member: $member)
                }
            }

            Section("Reaching them") {
                ListField(title: "Mail from", prompt: "address or @domain, comma separated", values: $member.mailFrom)
                    .help("From addresses that mean this member wrote a party mail.")
                TextField("iMessage", text: optional(\.imessage), prompt: Text("phone or email"))
                if member.kind == .pi {
                    Toggle("Send new party mail to them as events", isOn: Binding(
                        get: { member.mailEvents == true }, set: { member.mailEvents = $0 ? true : nil }))
                }
            }

            Section {
                LabeledContent("Tavern id", value: member.id).textSelection(.enabled)
            } footer: {
                Text("The id never changes, so history and pages follow a renamed member.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var color: Binding<Color> {
        Binding(get: { Color(hex: member.avatarColor) }, set: { member.avatarColor = $0.hexString })
    }

    private func optional(_ keyPath: WritableKeyPath<RosterMember, String?>) -> Binding<String> {
        Binding(get: { member[keyPath: keyPath] ?? "" },
                set: { member[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private func setAvatar(_ url: URL?) {
        do {
            try PartyArt.set("avatars/\(member.id)", from: url)
            artError = nil
        } catch {
            artError = "Couldn't use that image."
        }
        model.objectWillChange.send()
    }
}

/// A comma-separated list typed as text and saved when the field is left or Return is pressed,
/// so a trailing comma survives while the next address is typed.
private struct ListField: View {
    let title: String
    let prompt: String
    @Binding var values: [String]?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onAppear { text = joined }
            .onChange(of: values) { _, _ in if !focused { text = joined } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private var joined: String { (values ?? []).joined(separator: ", ") }

    private func commit() {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let new = items.isEmpty ? nil : items
        if new != values { values = new }
    }
}

/// A Pi agent's connection: a durable host on this Mac, or one on another machine over SSH.
/// Hand-written commands show as they are; choosing a place replaces them.
private struct ConnectionEditor: View {
    @Binding var member: RosterMember

    private enum Place: Hashable { case local, ssh, custom }

    private var place: Place {
        guard let endpoint = member.endpoint else { return .local }
        if endpoint.localPort != nil { return .local }
        if endpoint.sshTarget != nil { return .ssh }
        return .custom
    }

    var body: some View {
        Picker("Connection", selection: Binding(get: { place }, set: setPlace)) {
            Text("This Mac").tag(Place.local)
            Text("Another machine (SSH)").tag(Place.ssh)
            if place == .custom { Text("Custom").tag(Place.custom) }
        }
        switch place {
        case .local:
            TextField("Port", value: Binding(get: { Int(member.endpoint?.localPort ?? 19011) },
                                             set: { member.piEndpoint = .tcp(host: "127.0.0.1", port: UInt16(clamping: $0)) }),
                      format: .number.grouping(.never))
        case .ssh:
            let target = member.endpoint?.sshTarget
            TextField("SSH host", text: Binding(get: { target?.host ?? "" }, set: { host in
                member.piEndpoint = .ssh(host: host, port: target?.port ?? 19011, socat: target?.socat ?? PiEndpoint.defaultSocat)
                member.tailscaleName = host.isEmpty ? nil : host
            }), prompt: Text("as you'd type after ssh"))
            TextField("Port", value: Binding(get: { Int(target?.port ?? 19011) }, set: { port in
                member.piEndpoint = .ssh(host: target?.host ?? "", port: UInt16(clamping: port), socat: target?.socat ?? PiEndpoint.defaultSocat)
            }), format: .number.grouping(.never))
        case .custom:
            LabeledContent("Command", value: member.endpoint?.summary ?? "").textSelection(.enabled)
        }
    }

    private func setPlace(_ new: Place) {
        switch new {
        case .local:
            member.piEndpoint = .tcp(host: "127.0.0.1", port: 19011)
            member.piLaunch = nil
            member.tailscaleName = "self"
        case .ssh:
            member.piEndpoint = .ssh(host: "", port: 19011)
            member.piLaunch = nil
            member.tailscaleName = nil
        case .custom:
            break
        }
    }
}

// MARK: - Lore

private struct LoreSettings: View {
    @Binding var roster: Roster
    @State private var newTitle = ""
    @State private var newURL = ""

    private var links: Binding<[LoreLink]> {
        Binding(get: { roster.lore ?? [] }, set: { roster.lore = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(links.wrappedValue.enumerated()), id: \.offset) { index, link in
                    HStack {
                        Picker("", selection: links[index].kind) {
                            Label("Doc", systemImage: "doc.text").tag(LoreLink.Kind.doc)
                            Label("Sheet", systemImage: "tablecells").tag(LoreLink.Kind.sheet)
                            Label("Linear", systemImage: "checklist").tag(LoreLink.Kind.linear)
                            Label("Folder", systemImage: "folder").tag(LoreLink.Kind.folder)
                            Label("Link", systemImage: "link").tag(LoreLink.Kind.link)
                        }
                        .labelsHidden().fixedSize()
                        TextField("Title", text: links[index].title).labelsHidden()
                        Text(link.url.host() ?? link.url.absoluteString).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button { links.wrappedValue.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Title", text: $newTitle)
                    TextField("URL", text: $newURL)
                    Button("Add") {
                        guard let url = URL(string: newURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
                        let title = newTitle.trimmingCharacters(in: .whitespaces)
                        links.wrappedValue.append(LoreLink(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                                           url: url, kind: LoreLink.guessKind(url)))
                        newTitle = ""
                        newURL = ""
                    }
                    .disabled(URL(string: newURL)?.scheme == nil)
                }
            } header: {
                Text("Lore")
            } footer: {
                Text("The party's shared docs, sheets and boards, under Go > Lore.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension LoreLink {
    /// A kind from the URL: Google Docs and Sheets, Linear, Drive folders; else a plain link.
    static func guessKind(_ url: URL) -> Kind {
        let text = url.absoluteString
        if text.contains("docs.google.com/document") { return .doc }
        if text.contains("docs.google.com/spreadsheets") { return .sheet }
        if url.host()?.hasSuffix("linear.app") == true { return .linear }
        if text.contains("drive.google.com/drive/folders") { return .folder }
        return .link
    }
}

extension Color {
    /// "#rrggbb" in sRGB, the roster's color format.
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let r = Int((color.redComponent * 255).rounded()), g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
