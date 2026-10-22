import SwiftUI
import TavernCore

/// Docker containers on each Pi agent's machine, read-only, Orchard-style: a searchable list
/// grouped by machine, and the selected container's details as titled cards. Refreshes every
/// 30 seconds while open.
struct ServicesView: View {
    @EnvironmentObject private var model: AppModel
    private var results: [String: Result<[DockerContainer], DockerError>] { model.containerResults }
    private var refreshedAt: Date? { model.containersRefreshedAt }
    @State private var selection: String?
    @State private var query = ""

    private var hosts: [DockerHost] { DockerHost.hosts(for: model.roster) }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                .splitAutosave("services")
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Services")
        .onReceive(NotificationCenter.default.publisher(for: .tavernRefresh)) { _ in Task { await refresh() } }
        .onChange(of: model.focusedService) { _, focus in
            guard let focus else { return }
            selection = focus
            model.focusedService = nil
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search containers", text: $query).textFieldStyle(.plain)
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(refreshedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            List(selection: $selection) {
                ForEach(hosts) { host in
                    Section {
                        switch results[host.id] {
                        case nil:
                            ProgressView().controlSize(.small)
                        case .failure(let error):
                            Label(error.description, systemImage: "exclamationmark.triangle")
                                .tavernFont(.caption).foregroundStyle(.orange)
                        case .success(let containers):
                            let shown = filtered(containers)
                            if shown.isEmpty {
                                Text(containers.isEmpty ? "No containers" : "No matches")
                                    .tavernFont(.caption).foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                            }
                            ForEach(shown) { container in
                                ContainerListRow(container: container).themedTag(key(host, container), selection: selection)
                            }
                        }
                    } header: {
                        HStack {
                            Text(host.name)
                            Spacer()
                            if case .success(let containers) = results[host.id] {
                                CountBadge(count: containers.filter(\.isRunning).count)
                            }
                        }
                        .padding(.trailing, 6)
                        .padding(.top, 6)
                    }
                }
            }
            .listStyle(.sidebar)
            .themedList()
        }
    }

    private func filtered(_ containers: [DockerContainer]) -> [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return containers }
        return containers.filter { [$0.name, $0.image, $0.composeProject ?? ""].contains { $0.lowercased().contains(q) } }
    }

    private func key(_ host: DockerHost, _ container: DockerContainer) -> String { "\(host.id)/\(container.id)" }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let (host, container) = selected {
            ContainerDetail(host: host, container: container)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Select a container").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selected: (DockerHost, DockerContainer)? {
        guard let selection else { return nil }
        for host in hosts {
            guard case .success(let containers) = results[host.id] else { continue }
            if let container = containers.first(where: { key(host, $0) == selection }) { return (host, container) }
        }
        return nil
    }

    private func refresh() async {
        await model.refreshContainers()
        if let focus = model.focusedService {
            selection = focus
            model.focusedService = nil
        }
        if selection == nil, let first = hosts.lazy.compactMap({ host -> String? in
            guard case .success(let containers) = results[host.id], let c = containers.first else { return nil }
            return key(host, c)
        }).first {
            selection = first
        }
    }
}

private struct ContainerListRow: View {
    let container: DockerContainer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).tavernFont(.callout, weight: .semibold).lineLimit(1)
                Text(container.composeProject.map { "\($0) · \(container.status)" } ?? container.status)
                    .tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

private struct ContainerDetail: View {
    let host: DockerHost
    let container: DockerContainer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(container.name).tavernFont(.title2, weight: .semibold)
                        Text(container.isRunning ? "Running" : container.state.capitalized)
                            .tavernFont(.caption, weight: .semibold)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((container.isRunning ? Color.green : Color.secondary).opacity(0.2), in: Capsule())
                            .foregroundStyle(container.isRunning ? Color.green : Color.secondary)
                    }
                    Text(container.image).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }

                InfoCard(title: "Overview") {
                    InfoRow(label: "Machine", value: host.name)
                    InfoRow(label: "Container ID", value: String(container.id.prefix(12)), monospaced: true, copyable: true)
                    InfoRow(label: "Status", value: container.status)
                    if !container.created.isEmpty { InfoRow(label: "Created", value: container.created) }
                    if !container.size.isEmpty { InfoRow(label: "Size", value: container.size) }
                }
                if !container.command.isEmpty {
                    InfoCard(title: "Process") {
                        InfoRow(label: "Command", value: container.command, monospaced: true, copyable: true)
                    }
                }
                InfoCard(title: "Network") {
                    InfoRow(label: "Ports", value: container.ports.isEmpty ? "None published" : container.ports.replacingOccurrences(of: ", ", with: "\n"), monospaced: !container.ports.isEmpty)
                    if !container.networks.isEmpty { InfoRow(label: "Networks", value: container.networks, monospaced: true) }
                }
                if !container.mounts.isEmpty {
                    InfoCard(title: "Storage") {
                        InfoRow(label: "Mounts", value: container.mounts.replacingOccurrences(of: ",", with: "\n"), monospaced: true)
                    }
                }
                if let project = container.composeProject {
                    InfoCard(title: "Compose") {
                        InfoRow(label: "Project", value: project)
                        if let service = container.composeService { InfoRow(label: "Service", value: service) }
                        if let dir = container.labels["com.docker.compose.project.working_dir"] {
                            InfoRow(label: "Directory", value: dir, monospaced: true, copyable: true)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
