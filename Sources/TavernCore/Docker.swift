import Foundation

/// One container from `docker ps --format '{{json .}}'`.
public struct DockerContainer: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var ports: String
    public var command = ""
    public var created = ""
    public var runningFor = ""
    public var networks = ""
    public var mounts = ""
    public var size = ""
    public var labels: [String: String] = [:]

    public var isRunning: Bool { state == "running" }
    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }

    /// docker's `Labels` string, "k=v,k=v", where a value can itself contain commas.
    static func parseLabels(_ raw: String) -> [String: String] {
        var labels: [String: String] = [:]
        var lastKey: String?
        for piece in raw.split(separator: ",", omittingEmptySubsequences: false) {
            if let eq = piece.firstIndex(of: "="), !piece[..<eq].contains(" ") {
                let key = String(piece[..<eq])
                labels[key] = String(piece[piece.index(after: eq)...])
                lastKey = key
            } else if let key = lastKey {
                labels[key, default: ""] += "," + piece
            }
        }
        return labels
    }

    /// Parses docker's JSON-lines output; lines that aren't a container are skipped.
    public static func parse(_ output: String) -> [DockerContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = row["ID"] as? String else { return nil }
            var container = DockerContainer(
                id: id,
                name: (row["Names"] as? String) ?? id,
                image: (row["Image"] as? String) ?? "",
                state: (row["State"] as? String) ?? "",
                status: (row["Status"] as? String) ?? "",
                ports: (row["Ports"] as? String) ?? ""
            )
            container.command = ((row["Command"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            container.created = (row["CreatedAt"] as? String) ?? ""
            container.runningFor = (row["RunningFor"] as? String) ?? ""
            container.networks = (row["Networks"] as? String) ?? ""
            container.mounts = (row["Mounts"] as? String) ?? ""
            container.size = (row["Size"] as? String) ?? ""
            container.labels = parseLabels((row["Labels"] as? String) ?? "")
            return container
        }
        .sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }
}

/// A machine whose containers Tavern lists, read-only: `docker ps` on this Mac, or over SSH on a
/// Pi agent's tailnet host (the same SSH access Tavern already uses for that agent).
public struct DockerHost: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// argv that prints the containers as JSON lines.
    public var argv: [String]

    static let listArgs = "ps -a --no-trunc --format '{{json .}}'"

    /// One host per distinct Pi agent machine, this Mac first.
    public static func hosts(for roster: Roster) -> [DockerHost] {
        var seen = Set<String>()
        var hosts: [DockerHost] = []
        for agent in roster.piAgents {
            guard let machine = agent.tailscaleName, seen.insert(machine).inserted else { continue }
            let name = agent.host ?? machine
            if machine == "self" {
                hosts.insert(DockerHost(id: "self", name: name, argv: ["/bin/sh", "-c", "docker \(listArgs)"]), at: 0)
            } else {
                // Non-login SSH shells skip the profile, so name the usual docker locations.
                let remote = "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH docker \(listArgs)"
                hosts.append(DockerHost(id: machine, name: name,
                                        argv: ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", machine, remote]))
            }
        }
        return hosts
    }

    /// Runs the listing. Throws with docker's own error text when it fails.
    public func containers() async throws -> [DockerContainer] {
        #if os(macOS)
        let argv = self.argv
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw DockerError(message: message.isEmpty ? "docker exited \(process.terminationStatus)" : message)
            }
            return DockerContainer.parse(String(decoding: data, as: UTF8.self))
        }.value
        #else
        throw DockerError(message: "Docker is listed from a Mac")
        #endif
    }
}

public struct DockerError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String {
        if message.contains("Cannot connect to the Docker daemon") || message.contains("failed to connect to the docker API") {
            return "Docker isn't running here."
        }
        if message.contains("command not found") { return "Docker isn't installed here." }
        return message
    }
}
