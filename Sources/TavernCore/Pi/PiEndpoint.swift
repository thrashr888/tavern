import Foundation

/// How Tavern reaches an agent's Pi RPC stream.
///
/// - `command`: run a local command whose stdin/stdout speak Pi RPC. Covers a local
///   `pi --mode rpc`, and reaching a remote Pi through existing SSH, e.g.
///   `ssh -T ser8 socat - UNIX-CONNECT:/path/to/proxy.sock`.
/// - `tcp`: a plain TCP stream of RPC lines, e.g. a tailnet-only socat port or an SSH local forward.
///
/// Tavern never opens ports, installs anything or changes a host; it only connects to what the
/// roster names.
public enum PiEndpoint: Codable, Equatable, Sendable {
    case command([String])
    case tcp(host: String, port: UInt16)

    private enum CodingKeys: String, CodingKey { case kind, argv, host, port }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "command":
            self = .command(try container.decode([String].self, forKey: .argv))
        case "tcp":
            self = .tcp(host: try container.decode(String.self, forKey: .host),
                        port: try container.decode(UInt16.self, forKey: .port))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "Unknown endpoint kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .command(let argv):
            try container.encode("command", forKey: .kind)
            try container.encode(argv, forKey: .argv)
        case .tcp(let host, let port):
            try container.encode("tcp", forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        }
    }

    /// Short description for the inspector, e.g. "ssh ser8" or "tcp ser8:18999".
    public var summary: String {
        switch self {
        case .command(let argv):
            // "ssh … host socat - TCP:127.0.0.1:19011" reads as "SSH to host, port 19011".
            if URL(fileURLWithPath: argv.first ?? "").lastPathComponent == "ssh", let last = argv.last {
                let host = argv.dropLast().last { !$0.hasPrefix("-") && !$0.contains("=") && $0 != argv.first } ?? "?"
                if let port = last.split(separator: ":").last, Int(port) != nil { return "SSH to \(host), port \(port)" }
                return "SSH to \(host)"
            }
            let words = argv.map { URL(fileURLWithPath: $0).lastPathComponent }
            return words.prefix(3).joined(separator: " ")
        case .tcp(let host, let port):
            return "tcp \(host):\(port)"
        }
    }

    public var isRemote: Bool {
        switch self {
        case .tcp: return true
        case .command(let argv):
            return argv.contains { ["ssh", "tailscale"].contains(URL(fileURLWithPath: $0).lastPathComponent) }
        }
    }

    public func makeTransport() throws -> PiTransport {
        switch self {
        case .command(let configured):
            let argv = PiProcessTransport.continuing(configured)
            guard let executable = argv.first else { throw PiTransportError.notRunning }
            return PiProcessTransport(executable: URL(fileURLWithPath: executable), arguments: Array(argv.dropFirst()))
        case .tcp(let host, let port):
            return PiTCPTransport(host: host, port: port)
        }
    }
}

extension RosterMember {
    /// The configured endpoint: `piEndpoint`, else the older `piLaunch` command.
    public var endpoint: PiEndpoint? {
        piEndpoint ?? piLaunch.map(PiEndpoint.command)
    }
}

extension PiEndpoint {
    /// socat for a remote shell that may not have Homebrew on its PATH (a Mac reached over SSH).
    public static let defaultSocat = "PATH=$PATH:/opt/homebrew/bin:/usr/local/bin socat"

    /// A durable host on another machine, through the user's SSH and socat to its loopback port.
    public static func ssh(host: String, port: UInt16, socat: String = defaultSocat) -> PiEndpoint {
        .command(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", host,
                  "\(socat) - TCP:127.0.0.1:\(port)"])
    }

    /// The port of a durable host on this Mac (`tcp 127.0.0.1:<port>`), else nil.
    public var localPort: UInt16? {
        if case .tcp(let host, let port) = self, ["127.0.0.1", "localhost", "::1"].contains(host) { return port }
        return nil
    }

    /// Host, port and socat of an endpoint made by `ssh(host:port:socat:)` (pi-bundle writes the
    /// same shape), so Settings can edit it; nil for anything else, such as a command with its own
    /// `-p` or `-i`, which Settings leaves as Custom rather than rebuild without them.
    public var sshTarget: (host: String, port: UInt16, socat: String)? {
        guard case .command(let argv) = self, argv.count == 8, let last = argv.last,
              let range = last.range(of: " - TCP:127.0.0.1:"), let port = UInt16(last[range.upperBound...]) else { return nil }
        let host = argv[6]
        guard Array(argv[..<6]) == ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15"],
              !host.isEmpty, !host.hasPrefix("-"), !host.contains("="), !host.contains(" ") else { return nil }
        return (host, port, String(last[..<range.lowerBound]))
    }
}
