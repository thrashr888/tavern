import SwiftUI
import TavernCore

/// Read-only config for each Pi agent, plus the model-switch lock (plan 3c). There is no settings
/// form: settings change in chat. The lock is the one control, locked by default.
struct AgentConfigView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings change in chat. The lock stops Tavern from switching an agent's model; it doesn't stop the agent or its host.")
                    .foregroundStyle(.secondary)
                ForEach(model.roster.piAgents) { agent in
                    if let session = model.session(for: agent.id) {
                        AgentConfigCard(agent: agent, session: session, store: model.store)
                    } else {
                        UnconfiguredCard(agent: agent)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Agent config")
    }
}

private struct UnconfiguredCard: View {
    let agent: RosterMember

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(member: agent, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).tavernFont(.headline)
                Text("\(agent.host ?? "") · no Pi connection configured").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AgentConfigCard: View {
    let agent: RosterMember
    @ObservedObject var session: PiAgentSession
    let store: EventStore?
    @State private var choice: PiModel?
    @State private var confirming: PiModel?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(member: agent, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).tavernFont(.headline)
                    Text("\(agent.host ?? "") · \(session.presence.label)").foregroundStyle(.secondary)
                }
                Spacer()
                if session.presence == .disconnected {
                    Button("Connect") { Task { await session.connect() } }
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Model", session.config.model?.label ?? "Not reported")
                row("Thinking", session.config.thinkingLevel ?? "Not reported")
                row("Last known good", session.lastKnownGoodModel?.label ?? "None yet")
                row("Host", session.config.durable ? "Durable host" : "pi --mode rpc")
                row("Connection", agent.endpoint?.summary ?? "Not configured")
            }
            .tavernFont(.callout)

            Divider()

            Toggle(isOn: Binding(get: { session.modelLocked }, set: { session.setModelLocked($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock model switching")
                    Text("While locked, Tavern never sends set_model to \(agent.name).")
                        .tavernFont(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if !session.modelLocked {
                switchControls
            }

            if let pending = session.pendingModel {
                HStack {
                    Label("Switching to \(pending.label) when this turn settles", systemImage: "clock")
                    Spacer()
                    Button("Cancel") { session.cancelPendingModel() }
                }
                .tavernFont(.callout)
                .foregroundStyle(.orange)
            }
            if let error {
                Text(error).tavernFont(.caption).foregroundStyle(.red)
            }

            ChangeLogList(entries: store.map { ModelChangeLog.entries(agentID: agent.id, store: $0) } ?? [])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .task(id: session.presence) {
            if session.presence == .idle || session.presence == .working {
                await session.loadAvailableModels()
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Switch model") {
                guard let target = confirming else { return }
                confirming = nil
                Task { await perform { try await session.switchModel(to: target) } }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var switchControls: some View {
        HStack(spacing: 10) {
            if session.availableModels.isEmpty {
                Text("\(agent.name) doesn't list other models.").foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $choice) {
                    Text("Choose a model").tag(PiModel?.none)
                    ForEach(session.availableModels, id: \.self) { option in
                        Text(option.label).tag(Optional(option))
                    }
                }
                .frame(maxWidth: 320)
                Button("Switch…") { confirming = choice }
                    .disabled(choice == nil || choice == session.config.model)
            }
            Spacer()
            Button("Revert to last known good") {
                Task { await perform { try await session.revertToLastKnownGood() } }
            }
            .disabled(session.lastKnownGoodModel == nil || session.lastKnownGoodModel == session.config.model)
        }
        .tavernFont(.callout)
    }

    private var confirmTitle: String {
        "Switch \(agent.name) to \(confirming?.label ?? "")?"
    }

    private var confirmMessage: String {
        let from = session.config.model?.label ?? "its current model"
        let timing = session.isWorking
            ? "\(agent.name) is mid-turn; the switch applies after the turn settles."
            : "The switch applies now."
        return "From \(from) to \(confirming?.label ?? ""). \(timing)"
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct ChangeLogList: View {
    let entries: [ModelChangeLog.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model changes").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("None from Tavern").tavernFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(10)) { entry in
                HStack {
                    Text("\(entry.from ?? "?") → \(entry.to.label)")
                    Spacer()
                    Text(entry.reason).foregroundStyle(.secondary)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
                .tavernFont(.callout)
            }
        }
    }
}
