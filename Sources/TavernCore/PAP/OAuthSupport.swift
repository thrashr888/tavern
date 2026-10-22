import CryptoKit
import Foundation
import Network
import Security

/// PKCE and form encoding for an installed app's OAuth sign-in (RFC 7636, RFC 8252).
enum OAuthPKCE {
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, Equatable {
    case stateMismatch
    case denied(String)
    case noCode
    case loopbackFailed
    case keychain(OSStatus)
}

// MARK: - Token storage

public protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

/// A token in the login Keychain (generic password).
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    public init(service: String, account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ token: String) throws {
        delete()
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw OAuthError.keychain(status) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Loopback redirect

/// A one-shot HTTP listener on 127.0.0.1 that catches the sign-in redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tavern.oauth.loopback")
    // Touched only on `queue`.
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(listener: NWListener) {
        self.listener = listener
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let receiver = LoopbackReceiver(listener: try NWListener(using: parameters))
        try await receiver.listen()
        return receiver
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ready = continuation
                self.listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
        case .failed, .cancelled:
            ready?.resume(throwing: OAuthError.loopbackFailed)
            ready = nil
            finish(.failure(OAuthError.loopbackFailed))
        default:
            break
        }
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.waiter = continuation
                }
            }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { self.finish(.failure(CancellationError())) }
    }

    /// First result wins; later ones are ignored. Runs on `queue`.
    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard let query = Self.query(fromRequest: request) else {
                // Favicon or other noise.
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            Self.respond(connection, status: "200 OK", body: Self.donePage)
            self?.finish(.success(query))
        }
    }

    static let donePage = """
        <html><body style="font-family:-apple-system;padding:40px"><h2>Tavern is signed in to Personal Agent Proxy.</h2>\
        <p>You can close this tab. Tavern reads mail and Linear with the permissions you give it there.</p></body></html>
        """

    /// The query of `GET /?code=…&state=… HTTP/1.1`; nil for any other path.
    static func query(fromRequest request: String) -> [String: String]? {
        let line = request.prefix { $0 != "\r\n" && $0 != "\n" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/" || components.path.isEmpty,
              let items = components.queryItems, !items.isEmpty
        else { return nil }
        var result: [String: String] = [:]
        for item in items { result[item.name] = item.value ?? "" }
        return result
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
