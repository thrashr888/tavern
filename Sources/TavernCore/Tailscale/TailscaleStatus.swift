import Foundation

/// One machine on the tailnet, from `tailscale status --json` (the `Self` entry or a `Peer` value).
public struct TailscaleNode: Equatable, Sendable {
    /// The machine name Tailscale shows, e.g. "ser8".
    public var hostName: String
    /// Full MagicDNS name without the trailing dot, e.g. "ser8.tail1234.ts.net".
    public var dnsName: String?
    public var ips: [String]
    public var os: String?
    public var online: Bool
    public var lastSeen: Date?
    /// True for the machine Tavern runs on.
    public var isSelf: Bool

    public init(hostName: String, dnsName: String? = nil, ips: [String] = [], os: String? = nil,
                online: Bool, lastSeen: Date? = nil, isSelf: Bool = false) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.ips = ips
        self.os = os
        self.online = online
        self.lastSeen = lastSeen
        self.isSelf = isSelf
    }

    /// The MagicDNS short name, e.g. "ser8" from "ser8.tail1234.ts.net".
    public var magicDNSShortName: String? {
        dnsName?.split(separator: ".").first.map(String.init)
    }

    /// A URL for the machine on the tailnet. Says where it lives, not that anything is served there.
    public var url: URL? {
        dnsName.flatMap { URL(string: "http://\($0)") }
    }
}

/// A read-only snapshot of the local Tailscale client.
public struct TailscaleStatus: Equatable, Sendable {
    /// "Running", "Stopped", "NeedsLogin", ...
    public var backendState: String
    public var tailnetName: String?
    public var magicDNSSuffix: String?
    public var nodes: [TailscaleNode]

    public init(backendState: String, tailnetName: String? = nil, magicDNSSuffix: String? = nil, nodes: [TailscaleNode]) {
        self.backendState = backendState
        self.tailnetName = tailnetName
        self.magicDNSSuffix = magicDNSSuffix
        self.nodes = nodes
    }

    public var isRunning: Bool { backendState == "Running" }

    /// Parses `tailscale status --json`. Unknown fields are ignored.
    public static func parse(_ data: Data) throws -> TailscaleStatus {
        let json = try JSONValue.decode(data)
        var nodes: [TailscaleNode] = []
        if let me = json["Self"], let node = node(from: me, isSelf: true) {
            nodes.append(node)
        }
        if case .object(let peers)? = json["Peer"] {
            nodes += peers.values.compactMap { node(from: $0, isSelf: false) }
                .sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
        }
        return TailscaleStatus(
            backendState: json["BackendState"]?.stringValue ?? "Unknown",
            tailnetName: json["CurrentTailnet"]?["Name"]?.stringValue,
            magicDNSSuffix: json["MagicDNSSuffix"]?.stringValue ?? json["CurrentTailnet"]?["MagicDNSSuffix"]?.stringValue,
            nodes: nodes
        )
    }

    private static func node(from json: JSONValue, isSelf: Bool) -> TailscaleNode? {
        guard let hostName = json["HostName"]?.stringValue else { return nil }
        var dnsName = json["DNSName"]?.stringValue
        if dnsName?.hasSuffix(".") == true { dnsName?.removeLast() }
        if dnsName?.isEmpty == true { dnsName = nil }
        return TailscaleNode(
            hostName: hostName,
            dnsName: dnsName,
            ips: json["TailscaleIPs"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            os: json["OS"]?.stringValue,
            // The Self entry reports Online for the local client; treat a running local client as online.
            online: json["Online"]?.boolValue ?? isSelf,
            lastSeen: PiEntries.parseTimestamp(json["LastSeen"]?.stringValue),
            isSelf: isSelf
        )
    }

    /// The node for a roster member: `tailscaleName`, else `host`.
    public func node(for member: RosterMember) -> TailscaleNode? {
        node(named: member.tailscaleName ?? member.host)
    }

    /// The node for an agent's host. Matches the roster's `tailscaleName` (or `host`) against the
    /// MagicDNS short name first, then the machine name, case-insensitively.
    public func node(named name: String?) -> TailscaleNode? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        if name == "self" { return nodes.first(where: \.isSelf) }
        return nodes.first { $0.magicDNSShortName?.lowercased() == name }
            ?? nodes.first { $0.hostName.lowercased() == name }
    }
}

/// Runs the local `tailscale status --json`. Read-only: no login, no keys, no config changes.
public enum TailscaleReader {
    /// Where the CLI usually lives on macOS: Homebrew or the standalone install, then the App Store app.
    public static let candidatePaths = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public enum ReadError: Error, Equatable {
        case notInstalled
        case failed(status: Int32)
    }

    public static func read(paths: [String] = candidatePaths) async throws -> TailscaleStatus {
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReadError.notInstalled
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["status", "--json"]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw ReadError.failed(status: process.terminationStatus)
                    }
                    continuation.resume(returning: try TailscaleStatus.parse(data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
