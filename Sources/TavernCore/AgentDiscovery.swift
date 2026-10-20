import Foundation
import Network

/// What a pi-bundle install says about its agent: `~/.config/pi-bundle/agents/<id>.json`, or the
/// older `roster-member.json` it wrote before agent cards. Tavern reads it to offer "Found Ember on
/// M3. Add?" instead of asking for JSON.
public struct AgentCard: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The machine as the user calls it ("M3"), pi-bundle's MACHINE_LABEL.
    public var host: String?
    public var platform: String?
    public var partyClass: String?
    public var animal: String?
    public var avatarColor: String?
    /// The host's loopback port (19011 unless the machine runs more than one agent).
    public var port: UInt16?
    /// "provider/model" from the agent's settings, when the install set one.
    public var model: String?
    /// socat on that machine, for reaching the port over SSH.
    public var socat: String?
    /// An avatar image beside the card (`<id>.png`), when the install had one.
    public var avatar: String?
    /// Older cards are roster entries; their port is in the endpoint.
    var piEndpoint: PiEndpoint?

    public var loopbackPort: UInt16 {
        if let port { return port }
        if case .tcp(_, let port)? = piEndpoint { return port }
        return 19011
    }
}

/// An agent found on this Mac or on a machine reached over SSH.
public struct DiscoveredAgent: Equatable, Identifiable, Sendable {
    public enum Place: Equatable, Sendable {
        case local
        /// Reached with `ssh <host>`: a tailnet name or an SSH alias.
        case ssh(host: String)
    }

    public var card: AgentCard
    public var place: Place
    /// Where the card was read, so the avatar beside it can be fetched.
    public var cardPath: String
    /// Whether the host answered on its port (local only; nil when not checked).
    public var answering: Bool?

    public var id: String { card.id }

    public init(card: AgentCard, place: Place, cardPath: String, answering: Bool? = nil) {
        self.card = card
        self.place = place
        self.cardPath = cardPath
        self.answering = answering
    }

    /// "This Mac", or the machine's own label ("M3"), else the SSH host.
    public var machine: String {
        switch place {
        case .local: return "This Mac"
        case .ssh(let host): return card.host ?? host
        }
    }

    /// The roster entry for this agent, reached locally over TCP or through SSH and socat.
    public func member(color: String = "#6b5b95") -> RosterMember {
        let port = card.loopbackPort
        var member = RosterMember(id: card.id, name: card.name, kind: .pi, host: card.host ?? machine,
                                  partyClass: card.partyClass, animal: card.animal, avatarColor: card.avatarColor ?? color,
                                  platform: card.platform ?? "Pi")
        switch place {
        case .local:
            member.tailscaleName = "self"
            member.piEndpoint = .tcp(host: "127.0.0.1", port: port)
        case .ssh(let host):
            member.tailscaleName = host
            member.piEndpoint = .ssh(host: host, port: port, socat: card.socat ?? PiEndpoint.defaultSocat)
        }
        return member
    }

    /// Path of the avatar image beside the card, if the card names one.
    public var avatarPath: String? {
        guard let avatar = card.avatar, !avatar.contains("/") else { return nil }
        return (cardPath as NSString).deletingLastPathComponent + "/" + avatar
    }
}

public enum AgentDiscovery {
    /// Where pi-bundle leaves cards, relative to the home folder: agent cards first, then the
    /// older per-install roster entries (one folder per agent when a machine runs several).
    static let cardGlobs = [".config/pi-bundle/agents/*.json", ".config/pi-bundle/roster-member.json", ".config/pi-bundle/*/roster-member.json"]

    /// Reads cards on this Mac. Checks each host's port so the list can say which ones are up.
    public static func local(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [DiscoveredAgent] {
        var files: [(String, Data)] = []
        let fm = FileManager.default
        for glob in cardGlobs {
            let parts = glob.split(separator: "/").map(String.init)
            for path in expand(parts, under: home.path, fm: fm) {
                if let data = fm.contents(atPath: path) { files.append((path, data)) }
            }
        }
        var found = cards(from: files).map { DiscoveredAgent(card: $0.card, place: .local, cardPath: $0.path) }
        for index in found.indices {
            found[index].answering = await isListening(port: found[index].card.loopbackPort)
        }
        return found
    }

    /// The command that prints every card on a remote machine, each after a `--- <path>` line.
    /// Run through sh: a Mac's login shell is zsh, which stops at a glob that matches nothing.
    public static let remoteScript =
        "sh -c 'for f in " + cardGlobs.map { "$HOME/\($0)" }.joined(separator: " ")
        + #"; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; echo; }; done; true'"#

    /// Reads cards on another machine over the user's own SSH (keys or agent; never a prompt).
    public static func remote(host: String, timeout: Int = 5) async -> [DiscoveredAgent] {
        guard let output = try? await run(ssh(host: host, timeout: timeout) + [remoteScript], timeout: timeout + 3) else { return [] }
        return parse(output).map { DiscoveredAgent(card: $0.card, place: .ssh(host: host), cardPath: $0.path) }
    }

    /// Copies the avatar beside a found agent's card to `destination` (a local copy, or base64 over SSH).
    public static func fetchAvatar(of agent: DiscoveredAgent, to destination: URL) async -> Bool {
        guard let path = agent.avatarPath, isSafeName(destination.deletingPathExtension().lastPathComponent) else { return false }
        let data: Data?
        switch agent.place {
        case .local:
            data = FileManager.default.contents(atPath: path)
        case .ssh(let host):
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let output = try? await run(ssh(host: host, timeout: 5) + ["base64 < \(quoted)"], timeout: 15)
            data = output.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        }
        guard let data, !data.isEmpty else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: destination, options: .atomic)) != nil
    }

    /// Tailnet machines worth asking: online Macs and Linux boxes other than this one, by the
    /// name SSH would use (MagicDNS short name, else machine name).
    public static func sshCandidates(in status: TailscaleStatus?) -> [String] {
        guard let status, status.isRunning else { return [] }
        let names = status.nodes
            .filter { !$0.isSelf && $0.online && ["macos", "linux"].contains(($0.os ?? "").lowercased()) }
            .map { $0.magicDNSShortName ?? $0.hostName }
        var seen = Set<String>()
        // Peers name themselves; a name like "-oProxyCommand=…" must never reach ssh.
        return names.filter { isSafeName($0) && seen.insert($0.lowercased()).inserted }
    }

    /// Parses `remoteScript` output.
    static func parse(_ output: String) -> [(card: AgentCard, path: String)] {
        var files: [(String, Data)] = []
        var path: String?
        var body: [Substring] = []
        func flush() {
            if let path { files.append((path, Data(body.joined(separator: "\n").utf8))) }
            body = []
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") {
                flush()
                path = String(line.dropFirst(4))
            } else {
                body.append(line)
            }
        }
        flush()
        return cards(from: files)
    }

    /// Decodes card files, one per agent id; the first file for an id wins (agent cards come first).
    static func cards(from files: [(String, Data)]) -> [(card: AgentCard, path: String)] {
        var result: [(card: AgentCard, path: String)] = []
        for (path, data) in files {
            // The id names files (avatars/<id>.png), so a card from another machine can't carry a path.
            guard let card = try? JSONDecoder().decode(AgentCard.self, from: data), isSafeName(card.id), !card.id.contains("."),
                  !result.contains(where: { $0.card.id == card.id }) else { continue }
            result.append((card, path))
        }
        return result
    }

    private static func expand(_ parts: [String], under dir: String, fm: FileManager) -> [String] {
        guard let first = parts.first else { return [dir] }
        let rest = Array(parts.dropFirst())
        guard first.contains("*") else { return expand(rest, under: dir + "/" + first, fm: fm) }
        let suffix = first.replacingOccurrences(of: "*", with: "")
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.sorted()
        return names.flatMap { expand(rest, under: dir + "/" + $0, fm: fm) }
    }

    private static func ssh(host: String, timeout: Int) -> [String] {
        ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "--", host]
    }

    /// Letters, digits, ".", "_" and "-", not starting with "-": safe as an ssh host or a file name.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name != ".." && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Runs a command and returns its stdout, or throws when it fails or runs past `timeout` seconds.
    private static func run(_ argv: [String], timeout: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: argv[0])
                    process.arguments = Array(argv.dropFirst())
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timer)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()
                    guard process.terminationStatus == 0 else { throw TailscaleReader.ReadError.failed(status: process.terminationStatus) }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Whether something accepts connections on 127.0.0.1:`port` within a second.
    public static func isListening(port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .waiting: once.run { continuation.resume(returning: false) }
                default: return
                }
                connection.cancel()
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                once.run { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }
}

/// Runs a closure at most once across threads.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
