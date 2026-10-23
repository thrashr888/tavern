import SwiftUI
import TavernCore

/// The party: each agent with its state, and an accent dot when it's waiting on you.
struct AgentListView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var adding = false

    var body: some View {
        List {
            ForEach(model.agents) { agent in
                if let session = model.session(for: agent) {
                    NavigationLink(value: agent.id) { AgentRow(agent: agent, session: session) }
                }
            }
            .onDelete { model.remove(at: $0) }
        }
        .overlay {
            if model.agents.isEmpty {
                ContentUnavailableView("No one in the party yet", systemImage: "person.3",
                                       description: Text("Tap + to make an agent that lives on this iPhone, or to add a host's agent."))
            }
        }
        .navigationTitle("Party")
        .refreshable {
            for agent in model.agents { await model.session(for: agent)?.reconnectNow() }
        }
        .toolbar {
            Button { adding = true } label: { Label("Add to the party", systemImage: "plus") }
        }
        .sheet(isPresented: $adding) { AddAgentView().environmentObject(model) }
    }
}

private struct AgentRow: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: agent.name)
                .overlay(alignment: .topTrailing) {
                    if needsYou { Circle().fill(Color.tavernAccent).frame(width: 12, height: 12).overlay(Circle().stroke(.background, lineWidth: 2)) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.headline)
                Text(status).font(.subheadline).foregroundStyle(needsYou ? Color.tavernAccent : .secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var needsYou: Bool {
        if session.dialog != nil { return true }
        if case .failed = session.presence { return true }
        return false
    }

    private var status: String {
        if let dialog = session.dialog { return "Waiting on you: \(dialog.title)" }
        return session.presence.label
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        // The party's art from the Mac (avatars/<id>), else an initial on a color of its own.
        if let image = Party.avatar(name.lowercased()) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(hue: hue, saturation: 0.5, brightness: 0.65), in: Circle())
        }
    }

    /// A stable color per name.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }
}

/// A new agent on this iPhone (it sets itself up: memory, tools, a hello), or a host's agent
/// by its durable host's address.
private struct AddAgentView: View {
    enum Kind: String, CaseIterable {
        case phone = "On this iPhone", host = "On a host"
    }

    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.phone
    @State private var name = ""
    @State private var role = ""
    @State private var host = ""
    @State private var port = "19011"

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var taken: Bool { model.agents.contains { $0.id == trimmedName.lowercased() } }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Where it runs", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Section {
                    TextField("Name", text: $name)
                    if kind == .phone {
                        TextField("What it's for (optional)", text: $role, axis: .vertical).lineLimit(2...4)
                    } else {
                        TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Port", text: $port).keyboardType(.numberPad)
                    }
                } footer: {
                    if taken {
                        Text("Someone in the party already has that name.").foregroundStyle(.red)
                    } else if kind == .phone {
                        Text("Runs on Apple's on-device model, so nothing leaves the phone except what its tools read. It can see where the phone is and its battery, read your inbox and Linear goals, and keeps its own memory on the phone. It sets itself up and says hello.")
                    } else {
                        Text("The agent's durable host, reached over your tailnet. Tavern adds no access of its own.")
                    }
                }
            }
            .navigationTitle("Add to the party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(kind == .phone ? "Create" : "Add") {
                        switch kind {
                        case .phone:
                            let job = role.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.add(.onPhone(name: trimmedName, role: job.isEmpty ? nil : job))
                        case .host:
                            model.add(PhoneAgent(id: trimmedName.lowercased(), name: trimmedName, host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? 19011))
                        }
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    private var canAdd: Bool {
        guard !trimmedName.isEmpty, !taken else { return false }
        return kind == .phone || (!host.trimmingCharacters(in: .whitespaces).isEmpty && UInt16(port) != nil)
    }
}
