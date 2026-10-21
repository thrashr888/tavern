import CryptoKit
import Foundation
import Network
import Security

/// Google OAuth for an installed (desktop) app: loopback redirect with PKCE, scope `gmail.modify`
/// (read, and archive when the user asks; Tavern never sends or deletes).
///
/// Nothing secret lives in the repo. The OAuth client is the user's own Google Cloud desktop client,
/// downloaded as JSON to `~/Library/Application Support/Tavern/gmail-oauth-client.json`; the refresh
/// token is kept in the login Keychain. Creating that client is the user's call (plan 5.3).
public actor GmailOAuth {
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"

    public struct Client: Equatable, Sendable {
        public var clientID: String
        public var clientSecret: String?
        public var authURI: URL
        public var tokenURI: URL

        /// Parses Google's downloaded client JSON (`{"installed": {...}}`).
        public static func parse(_ data: Data) throws -> Client {
            let json = try JSONValue.decode(data)
            let installed = json["installed"] ?? json["web"] ?? json
            guard let id = installed["client_id"]?.stringValue else { throw GmailOAuthError.badClientFile }
            return Client(
                clientID: id,
                clientSecret: installed["client_secret"]?.stringValue,
                authURI: URL(string: installed["auth_uri"]?.stringValue ?? "") ?? URL(string: "https://accounts.google.com/o/oauth2/auth")!,
                tokenURI: URL(string: installed["token_uri"]?.stringValue ?? "") ?? URL(string: "https://oauth2.googleapis.com/token")!
            )
        }

        public static func defaultURL() -> URL? {
            TavernPaths.file("gmail-oauth-client.json")
        }

        public static func load(from url: URL? = defaultURL()) -> Client? {
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? parse(data)
        }
    }

    let client: Client
    let keychain: TokenStore
    let session: URLSession
    private var accessToken: (value: String, expires: Date)?

    public init(client: Client, keychain: TokenStore = KeychainTokenStore(), session: URLSession = .shared) {
        self.client = client
        self.keychain = keychain
        self.session = session
    }

    public var isSignedIn: Bool { keychain.read() != nil }

    /// A valid access token, refreshed with the stored refresh token when needed.
    public func token() async throws -> String {
        if let accessToken, accessToken.expires > Date().addingTimeInterval(60) { return accessToken.value }
        guard let refresh = keychain.read() else { throw GmailError.notAuthorized }
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        guard let value = response["access_token"]?.stringValue else { throw GmailError.notAuthorized }
        accessToken = (value, Date().addingTimeInterval(response["expires_in"]?.doubleValue ?? 3000))
        return value
    }

    /// Opens Google's consent page via `open`, waits for the loopback redirect, and stores the
    /// refresh token.
    public func signIn(open: @escaping @Sendable (URL) -> Void) async throws {
        let verifier = Self.randomURLSafe(bytes: 32)
        let state = Self.randomURLSafe(bytes: 16)
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(receiver.port)"

        var components = URLComponents(url: client.authURI, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        open(components.url!)

        let query = try await receiver.waitForRedirect()
        guard query["state"] == state else { throw GmailOAuthError.stateMismatch }
        if let error = query["error"] { throw GmailOAuthError.denied(error) }
        guard let code = query["code"] else { throw GmailOAuthError.noCode }

        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        ])
        guard let refresh = response["refresh_token"]?.stringValue else { throw GmailOAuthError.noRefreshToken }
        try keychain.write(refresh)
        if let value = response["access_token"]?.stringValue {
            accessToken = (value, Date().addingTimeInterval(response["expires_in"]?.doubleValue ?? 3000))
        }
    }

    /// Forgets the token on this Mac. (Revoking the grant is done in the Google account.)
    public func signOut() {
        keychain.delete()
        accessToken = nil
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> JSONValue {
        var all = fields
        all["client_id"] = client.clientID
        if let secret = client.clientSecret { all["client_secret"] = secret }
        var request = URLRequest(url: client.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(all).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 400 || status == 401 { keychain.delete() }
            throw GmailError.notAuthorized
        }
        return try JSONValue.decode(data)
    }

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

public enum GmailOAuthError: Error, Equatable {
    case badClientFile
    case stateMismatch
    case denied(String)
    case noCode
    case noRefreshToken
    case loopbackFailed
    case keychain(OSStatus)
}

// MARK: - Token storage

public protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

/// The refresh token in the login Keychain (generic password, service "Tavern Gmail").
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    public init(service: String = "Tavern Gmail", account: String = "refresh-token") {
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
        guard status == errSecSuccess else { throw GmailOAuthError.keychain(status) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Loopback redirect

/// A one-shot HTTP listener on 127.0.0.1 that catches Google's redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    /// What the browser shows once the redirect arrives.
    var donePage = LoopbackReceiver.donePage
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
            ready?.resume(throwing: GmailOAuthError.loopbackFailed)
            ready = nil
            finish(.failure(GmailOAuthError.loopbackFailed))
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
            Self.respond(connection, status: "200 OK", body: self?.donePage ?? Self.donePage)
            self?.finish(.success(query))
        }
    }

    static let donePage = """
        <html><body style="font-family:-apple-system;padding:40px"><h2>Tavern is connected to Gmail (read-only).</h2>\
        <p>You can close this tab.</p></body></html>
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
