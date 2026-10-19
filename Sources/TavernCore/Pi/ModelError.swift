import Foundation

/// A provider error made readable. Pi stores errors as the raw HTTP status plus the provider's
/// JSON body (`401 {"type":"error","error":{...},"request_id":"req_…"}`), sometimes wrapped in a
/// notice (`No answer: model_error "401 {…}"`). This pulls out what a person needs.
public struct ModelError: Equatable, Sendable {
    public var title: String
    public var message: String
    public var status: Int?
    public var requestID: String?

    public init(title: String, message: String, status: Int? = nil, requestID: String? = nil) {
        self.title = title
        self.message = message
        self.status = status
        self.requestID = requestID
    }

    /// One line for places with no room for a card: "Not signed in: OAuth access token is invalid."
    public var summary: String { message.isEmpty ? title : "\(title): \(message)" }

    public static func parse(_ raw: String) -> ModelError {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var reason: String?
        // `No answer: model_error "…"` — the quoted part is a JSON string holding the real error.
        if let colon = text.range(of: "No answer: ") {
            let rest = text[colon.upperBound...]
            let word = rest.prefix { !$0.isWhitespace }
            reason = String(word)
            var body = rest.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("\""), let data = body.data(using: .utf8),
               let unquoted = try? JSONDecoder().decode(String.self, from: data) {
                body = unquoted
            }
            text = body
        }
        if text.isEmpty, let reason {
            return ModelError(title: reason == "no_model" ? "No model configured" : "No answer",
                              message: reason == "no_model" ? "This agent has no model it can use." : reason)
        }

        var status: Int?
        if let space = text.firstIndex(of: " "), let code = Int(text[..<space]), (100..<600).contains(code) {
            status = code
            text = String(text[text.index(after: space)...])
        }
        var message = text
        var kind: String?
        var requestID: String?
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let inner = object["error"] as? [String: Any]
            message = (inner?["message"] as? String) ?? (object["message"] as? String) ?? text
            kind = inner?["type"] as? String
            requestID = object["request_id"] as? String
        }
        return ModelError(title: title(status: status, kind: kind), message: message, status: status, requestID: requestID)
    }

    private static func title(status: Int?, kind: String?) -> String {
        switch (status, kind) {
        case (401, _), (_, "authentication_error"): return "Not signed in"
        case (403, _), (_, "permission_error"): return "Not allowed"
        case (429, _), (_, "rate_limit_error"): return "Rate limited or out of quota"
        case (529, _), (_, "overloaded_error"): return "Provider overloaded"
        case (404, _), (_, "not_found_error"): return "Model not found"
        case (400, _), (_, "invalid_request_error"): return "Request rejected"
        case (let code?, _) where code >= 500: return "Provider error"
        default: return "Model error"
        }
    }
}
