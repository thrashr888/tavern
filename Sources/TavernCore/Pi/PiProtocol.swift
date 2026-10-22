import Foundation

// Pi RPC records, per pi.dev/docs/latest/rpc, rpc-commands and rpc-extension-ui (checked 2026-10-15).
// One JSON object per LF-terminated line on stdin (commands) and stdout (responses and events).

/// Commands Tavern sends. Deliberately no `new_session`, `switch_session` or `fork`: one thread per agent.
public enum PiCommand: Equatable, Sendable {
    public enum StreamingBehavior: String, Sendable {
        case steer
        case followUp
    }

    case prompt(String, streamingBehavior: StreamingBehavior?, images: [PiImage] = [])
    case steer(String, images: [PiImage] = [])
    case followUp(String, images: [PiImage] = [])
    case abort
    case compact
    case getState
    case getSessionStats
    /// Entries strictly after `since`, or all entries when nil.
    case getEntries(since: String?)
    case getAvailableModels
    /// Only sent when the agent's model lock is off and the user confirmed (plan 3c).
    case setModel(PiModel)
    /// An outside happening (new mail) handed to a durable host's agent. `key` is the request id,
    /// stable for the same happening, so the host runs it once however often it's sent.
    case event(source: String, text: String, key: String)
    /// A durable host's MCP Apps card page for a tool result.
    case readCard(server: String, uri: String)
    /// A card's button calling a tool on its own server (after the user agreed).
    case callCardTool(server: String, name: String, arguments: JSONValue)
    /// A durable host's heartbeat checks, dry run: what's new, without waking the agent.
    case heartbeatCheck

    public var type: String {
        switch self {
        case .prompt: return "prompt"
        case .steer: return "steer"
        case .followUp: return "follow_up"
        case .abort: return "abort"
        case .compact: return "compact"
        case .getState: return "get_state"
        case .getSessionStats: return "get_session_stats"
        case .getEntries: return "get_entries"
        case .getAvailableModels: return "get_available_models"
        case .setModel: return "set_model"
        case .event: return "event"
        case .readCard: return "read_card"
        case .callCardTool: return "call_card_tool"
        case .heartbeatCheck: return "heartbeat_check"
        }
    }

    /// Commands that hand the agent a message. A resend of one keeps its `requestId`.
    public var submitsMessage: Bool {
        switch self {
        case .prompt, .steer, .followUp, .event: return true
        default: return false
        }
    }

    /// `requestId` lets a durable host run a resent message once; plain `pi --mode rpc` ignores it.
    /// It must be unique across app launches, unlike `id`.
    public func json(id: String, requestId: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "type": .string(type)]
        if submitsMessage, let requestId { object["requestId"] = .string(requestId) }
        switch self {
        case .prompt(let message, let behavior, let images):
            object["message"] = .string(message)
            if let behavior { object["streamingBehavior"] = .string(behavior.rawValue) }
            if !images.isEmpty { object["images"] = .array(images.map(\.json)) }
        case .steer(let message, let images), .followUp(let message, let images):
            object["message"] = .string(message)
            if !images.isEmpty { object["images"] = .array(images.map(\.json)) }
        case .getEntries(let since):
            if let since { object["since"] = .string(since) }
        case .setModel(let model):
            object["provider"] = .string(model.provider)
            object["modelId"] = .string(model.id)
        case .event(let source, let text, let key):
            object["source"] = .string(source)
            object["text"] = .string(text)
            object["requestId"] = .string(key)
        case .readCard(let server, let uri):
            object["server"] = .string(server)
            object["uri"] = .string(uri)
        case .callCardTool(let server, let name, let arguments):
            object["server"] = .string(server)
            object["name"] = .string(name)
            object["arguments"] = arguments
        case .abort, .compact, .getState, .getSessionStats, .getAvailableModels, .heartbeatCheck:
            break
        }
        return .object(object)
    }
}

/// An image attached to a message, as Pi's `ImageContent`.
public struct PiImage: Equatable, Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    var json: JSONValue {
        .object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)])
    }
}

/// An `extension_ui_request` dialog that pauses the agent until answered ("waiting on you").
public struct PiDialog: Equatable, Identifiable, Sendable {
    public enum Method: String, Sendable {
        case select, confirm, input, editor
    }

    public var id: String
    public var method: Method
    public var title: String
    public var message: String?
    public var options: [String]
    public var placeholder: String?
    public var prefill: String?

    /// A durable host asking before a risky tool call runs (tavern-durable's approvals).
    public var isApproval: Bool { method == .confirm && id.hasPrefix("approval-") }

    public init(id: String, method: Method, title: String, message: String? = nil,
                options: [String] = [], placeholder: String? = nil, prefill: String? = nil) {
        self.id = id
        self.method = method
        self.title = title
        self.message = message
        self.options = options
        self.placeholder = placeholder
        self.prefill = prefill
    }
}

/// Tavern's answer to a dialog, sent as `extension_ui_response`.
public enum PiDialogAnswer: Equatable, Sendable {
    case value(String)
    case confirmed(Bool)
    case cancelled

    public func json(dialogID: String) -> JSONValue {
        var object: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(dialogID)]
        switch self {
        case .value(let value): object["value"] = .string(value)
        case .confirmed(let confirmed): object["confirmed"] = .bool(confirmed)
        case .cancelled: object["cancelled"] = true
        }
        return .object(object)
    }
}

public struct PiResponse: Equatable, Sendable {
    public var id: String?
    public var command: String
    public var success: Bool
    public var data: JSONValue?
    public var error: String?
}

/// One parsed stdout line.
public enum PiRecord: Equatable, Sendable {
    case response(PiResponse)
    /// A dialog that needs an answer.
    case dialog(PiDialog)
    /// Fire-and-forget extension UI (notify, setStatus, ...). Shown, never answered.
    case extensionNotice(method: String, raw: JSONValue)
    /// Any session event: message_update, agent_end, agent_settled, tool_execution_*, compaction ...
    case event(type: String, raw: JSONValue)

    public static func parse(_ line: Data) throws -> PiRecord {
        let json = try JSONValue.decode(line)
        let type = json["type"]?.stringValue ?? ""
        switch type {
        case "response":
            return .response(PiResponse(
                id: json["id"]?.stringValue,
                command: json["command"]?.stringValue ?? "",
                success: json["success"]?.boolValue ?? false,
                data: json["data"],
                error: json["error"]?.stringValue
            ))
        case "extension_ui_request":
            let methodName = json["method"]?.stringValue ?? ""
            guard let method = PiDialog.Method(rawValue: methodName), let id = json["id"]?.stringValue else {
                return .extensionNotice(method: methodName, raw: json)
            }
            return .dialog(PiDialog(
                id: id,
                method: method,
                title: json["title"]?.stringValue ?? "",
                message: json["message"]?.stringValue,
                options: json["options"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                placeholder: json["placeholder"]?.stringValue,
                prefill: json["prefill"]?.stringValue
            ))
        default:
            return .event(type: type, raw: json)
        }
    }
}

/// Splits a byte stream into LF-terminated records, stripping an optional trailing CR.
/// Splits on LF only (not U+2028/U+2029), as the RPC docs require.
public struct LineFramer {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
