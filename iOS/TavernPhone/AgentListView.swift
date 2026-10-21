import SwiftUI
import TavernCore

/// The party: each agent with its state, and an orange dot when it's waiting on you.
struct AgentListView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var adding = false
    /// TAVERN_OPEN (an agent id) opens that thread at launch, for the Simulator and screenshots.
    @State private var path: [String] = ProcessInfo.processInfo.environment["TAVERN_OPEN"].flatMap { $0.isEmpty ? nil : [$0] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
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
                    ContentUnavailableView("No agents yet", systemImage: "person.3",
                                           description: Text("Add an agent's host and port, such as flint.your-tailnet.ts.net and 19011."))
                }
            }
            .navigationTitle("Tavern")
            .navigationDestination(for: String.self) { id in
                if let agent = model.agents.first(where: { $0.id == id }), let session = model.session(for: agent) {
                    ThreadView(agent: agent, session: session)
                }
            }
            .toolbar {
                Button { adding = true } label: { Label("Add agent", systemImage: "plus") }
            }
            .sheet(isPresented: $adding) { AddAgentView().environmentObject(model) }
        }
    }
}

private struct AgentRow: View {
    let agent: PhoneAgent
    @ObservedObject var session: PiAgentSession

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: agent.name)
                .overlay(alignment: .topTrailing) {
                    if needsYou { Circle().fill(.orange).frame(width: 12, height: 12).overlay(Circle().stroke(.background, lineWidth: 2)) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.headline)
                Text(status).font(.subheadline).foregroundStyle(needsYou ? .orange : .secondary).lineLimit(1)
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
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.5, brightness: 0.65), in: Circle())
    }

    /// A stable color per name.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }
}

/// A host and port for an agent's durable host.
private struct AddAgentView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "19011"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                Text("The agent's durable host, reached over your tailnet. Tavern adds no access of its own.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Add agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        model.add(PhoneAgent(id: trimmed.lowercased(), name: trimmed, host: host.trimmingCharacters(in: .whitespaces), port: UInt16(port) ?? 19011))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port) == nil)
                }
            }
        }
    }
}
