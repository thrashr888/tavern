import Foundation

/// Personal Agent Proxy (app.personalagentproxy.com): one sign-in that gives Tavern the party's
/// mail and Linear with the permissions the user sets there; no Google Cloud client or Linear key.
///
/// PAP's MCP server is Streamable HTTP without sessions: every POST carries one JSON-RPC message
/// and gets JSON back, signed in with an OAuth bearer token. It has five fixed tools; Tavern uses
/// `list_connections`, `read` (tools that only read) and `run` (archive, Linear edits).
public enum PAP {
    public static let defaultBase = URL(string: "https://app.personalagentproxy.com")!
    public static var mcpURL: URL { defaultBase.appendingPathComponent("mcp") }
}

public enum PAPError: Error, Equatable, CustomStringConvertible {
    /// Not signed in, or the sign-in was revoked.
    case notAuthorized
    case http(Int)
    case rpc(String)
    /// A tool answered with an error, in PAP's own words ("This login may not run …").
    case tool(String)
    /// The proxy has no connection of this kind that Tavern's login may use.
    case noConnection(String)

    public var description: String {
        switch self {
        case .notAuthorized: return "Not signed in to Personal Agent Proxy"
        case .http(let status): return "Personal Agent Proxy answered HTTP \(status)"
        case .rpc(let message): return "Personal Agent Proxy: \(message)"
        case .tool(let message): return message
        case .noConnection(let kind):
            return "Personal Agent Proxy has no \(kind) for Tavern yet. Connect it there and give Tavern access."
        }
    }

    /// PAP refused the action for this login, as opposed to the record not fitting it.
    var isForbidden: Bool {
        if case .tool(let message) = self { return message.hasPrefix("This login may not") }
        return false
    }
}

/// Sends one POST to the MCP endpoint. Tests script it.
public protocol PAPHTTP: Sendable {
    func post(_ body: Data, token: String) async throws -> (Data, Int)
}

/// One account PAP holds for Tavern ("Google", "Linear"), with what Tavern may do with it.
public struct PAPConnection: Equatable, Sendable {
    public var id: String
    public var integration: String
    public var account: String
    public var can: String
}

/// The MCP client: JSON-RPC over HTTPS with a bearer token from `token`.
public actor PAPClient {
    let http: PAPHTTP
    let token: @Sendable () async throws -> String
    private var initialized = false
    private var nextID = 1
    private var cachedConnections: [PAPConnection]?

    public init(http: PAPHTTP, token: @escaping @Sendable () async throws -> String) {
        self.http = http
        self.token = token
    }

    /// The live client for the hosted proxy.
    public static func live(oauth: PAPOAuth) -> PAPClient {
        PAPClient(http: PAPURLSessionHTTP()) { try await oauth.token() }
    }

    public func connections(refresh: Bool = false) async throws -> [PAPConnection] {
        if !refresh, let cachedConnections { return cachedConnections }
        let result = try await call("list_connections", [:])
        let connections = (result["connections"]?.arrayValue ?? []).compactMap { item -> PAPConnection? in
            guard let id = item["connection"]?.stringValue else { return nil }
            return PAPConnection(id: id, integration: item["integration"]?.stringValue ?? "",
                                 account: item["account"]?.stringValue ?? "", can: item["can"]?.stringValue ?? "")
        }
        cachedConnections = connections
        return connections
    }

    /// The first connection of an integration ("Google", "Linear"), looking again when the cached
    /// list has none (the user may have just connected it). Throws `.noConnection` without one.
    public func connection(_ integration: String, describedAs kind: String) async throws -> PAPConnection {
        func matching(_ list: [PAPConnection]) -> PAPConnection? {
            list.first { $0.integration.caseInsensitiveCompare(integration) == .orderedSame }
        }
        if let found = matching(try await connections()) { return found }
        guard let found = matching(try await connections(refresh: true)) else { throw PAPError.noConnection(kind) }
        return found
    }

    /// Runs a connection's tool that only reads.
    public func read(_ connection: String, _ tool: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await call("read", ["connection": .string(connection), "tool": .string(tool), "params": .object(params)])
    }

    /// Runs a connection's tool that changes something (archiving, a Linear edit).
    public func run(_ connection: String, _ tool: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await call("run", ["connection": .string(connection), "tool": .string(tool), "params": .object(params)])
    }

    /// Files the calls `body` makes under one PAP task, so the proxy's log shows them as one job
    /// with its goal. The task is finished even when `body` throws.
    public func task<T: Sendable>(_ title: String, goal: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let started = try await call("start_task", ["title": .string(title), "goal": .string(goal)])
        let id = started["task"]?.stringValue ?? started["id"]?.stringValue
        do {
            let result = try await body()
            if let id { _ = try? await call("finish_task", ["task": .string(id)]) }
            return result
        } catch {
            if let id { _ = try? await call("finish_task", ["task": .string(id)]) }
            throw error
        }
    }

    /// Calls one of PAP's MCP tools and returns its structured result.
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        if !initialized {
            _ = try await rpc("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": .object([:]),
                "clientInfo": ["name": "tavern", "title": "Tavern", "version": "1"],
            ])
            try await notify("notifications/initialized")
            initialized = true
        }
        let result = try await rpc("tools/call", ["name": .string(name), "arguments": .object(arguments)])
        if result["isError"]?.boolValue == true {
            throw PAPError.tool(result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "The tool failed")
        }
        if let structured = result["structuredContent"] { return structured }
        // Every PAP tool answers with JSON text too.
        guard let text = result["content"]?.arrayValue?.first?["text"]?.stringValue else { return .null }
        return (try? JSONValue.decode(Data(text.utf8))) ?? .string(text)
    }

    private func rpc(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let body = try JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]).encoded()
        let reply = try Self.message(in: try await send(body))
        if let message = reply["error"]?["message"]?.stringValue { throw PAPError.rpc(message) }
        return reply["result"] ?? .null
    }

    private func notify(_ method: String) async throws {
        _ = try await send(try JSONValue.object(["jsonrpc": "2.0", "method": .string(method)]).encoded())
    }

    private func send(_ body: Data) async throws -> Data {
        let (data, status) = try await http.post(body, token: try await token())
        if status == 401 || status == 403 {
            initialized = false
            throw PAPError.notAuthorized
        }
        guard (200..<300).contains(status) else { throw PAPError.http(status) }
        return data
    }

    /// The JSON-RPC message in a reply: plain JSON, or the last `data:` event of an SSE stream
    /// (the spec lets a server answer either way; PAP answers JSON).
    static func message(in data: Data) throws -> JSONValue {
        if let json = try? JSONValue.decode(data) { return json }
        let text = String(decoding: data, as: UTF8.self)
        let events = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard let last = events.last(where: { !$0.isEmpty }) else { throw PAPError.rpc("Unreadable reply") }
        return try JSONValue.decode(Data(last.utf8))
    }
}

public struct PAPURLSessionHTTP: PAPHTTP {
    let url: URL

    public init(url: URL = PAP.mcpURL) {
        self.url = url
    }

    public func post(_ body: Data, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
