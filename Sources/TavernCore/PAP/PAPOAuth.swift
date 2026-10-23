import Foundation

/// Signing Tavern in to Personal Agent Proxy: the MCP OAuth flow (dynamic client registration,
/// PKCE, loopback redirect), so no client file or key is needed on the Mac.
///
/// PAP matches redirects exactly, and the loopback port changes each time, so every sign-in
/// registers a fresh client for its redirect (PAP clears ones never used). On PAP's consent page
/// the user picks the agent login Tavern works as ("Custom MCP agent", named Tavern) and sets its
/// permissions there. The client id and the refresh token stay in the login Keychain; PAP rotates
/// the refresh token on every use.
public actor PAPOAuth {
    public static let scope = "mcp"

    struct Grant: Codable, Equatable {
        var clientID: String
        var refreshToken: String
    }

    let base: URL
    let keychain: TokenStore
    let session: URLSession
    private var accessToken: (value: String, expires: Date)?
    /// The refresh in flight: two callers refreshing at once would spend the same refresh token.
    private var refreshing: Task<String, Error>?

    /// A separate party (`TAVERN_HOME`: the demo, screenshots) gets a sign-in of its own, so it
    /// never reads the real party's mail.
    public static var defaultKeychain: KeychainTokenStore {
        KeychainTokenStore(service: "Tavern Personal Agent Proxy",
                           account: TavernPaths.separateHome.map { "refresh-token:\($0.path)" } ?? "refresh-token")
    }

    public init(base: URL = PAP.defaultBase, keychain: TokenStore = PAPOAuth.defaultKeychain,
                session: URLSession = .shared) {
        self.base = base
        self.keychain = keychain
        self.session = session
    }

    public var isSignedIn: Bool { grant != nil }

    var grant: Grant? {
        keychain.read().flatMap { try? JSONDecoder().decode(Grant.self, from: Data($0.utf8)) }
    }

    private func store(_ grant: Grant) throws {
        try keychain.write(String(decoding: try JSONEncoder().encode(grant), as: UTF8.self))
    }

    var authorizeURL: URL { base.appendingPathComponent("oauth/authorize") }
    var tokenURL: URL { base.appendingPathComponent("oauth/token") }
    var registerURL: URL { base.appendingPathComponent("oauth/register") }
    var resource: String { base.appendingPathComponent("mcp").absoluteString }

    /// A valid access token, refreshed with the stored grant when needed.
    public func token() async throws -> String {
        if let accessToken, accessToken.expires > Date().addingTimeInterval(60) { return accessToken.value }
        if let refreshing { return try await refreshing.value }
        guard let grant else { throw PAPError.notAuthorized }
        let task = Task { try await self.refresh(grant) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh(_ grant: Grant) async throws -> String {
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": grant.refreshToken,
            "client_id": grant.clientID,
            "resource": resource,
        ])
        return try keep(response, clientID: grant.clientID)
    }

    /// Opens PAP's sign-in and consent page via `open`, waits for the loopback redirect, and
    /// stores the grant.
    public func signIn(open: @escaping @Sendable (URL) -> Void) async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        try await signIn(redirect: "http://127.0.0.1:\(receiver.port)", clientName: "Tavern") { url in
            open(url)
            return try await receiver.waitForRedirect()
        }
    }

    /// The same sign-in for any redirect: `authorize` shows PAP's page at the URL it's given and
    /// returns the redirect's query once PAP sends the user back (the iPhone app uses
    /// ASWebAuthenticationSession and its own URL scheme).
    public func signIn(redirect: String, clientName: String,
                       authorize: @Sendable (URL) async throws -> [String: String]) async throws {
        let verifier = OAuthPKCE.randomURLSafe(bytes: 32)
        let state = OAuthPKCE.randomURLSafe(bytes: 16)
        let clientID = try await register(redirect: redirect, clientName: clientName)

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let query = try await authorize(components.url!)
        guard query["state"] == state else { throw OAuthError.stateMismatch }
        if let error = query["error"] { throw OAuthError.denied(error) }
        guard let code = query["code"] else { throw OAuthError.noCode }

        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
            "client_id": clientID,
            "resource": resource,
        ])
        _ = try keep(response, clientID: clientID)
    }

    /// Forgets the grant on this Mac. (Revoking Tavern's login is done in PAP.)
    public func signOut() {
        keychain.delete()
        accessToken = nil
    }

    /// Stores a token response's refresh token (PAP sends a new one every time) and access token.
    private func keep(_ response: JSONValue, clientID: String) throws -> String {
        guard let access = response["access_token"]?.stringValue else { throw PAPError.notAuthorized }
        if let refresh = response["refresh_token"]?.stringValue {
            try store(Grant(clientID: clientID, refreshToken: refresh))
        }
        accessToken = (access, Date().addingTimeInterval(response["expires_in"]?.doubleValue ?? 3000))
        return access
    }

    /// RFC 7591 registration of a public client for this one redirect.
    private func register(redirect: String, clientName: String) async throws -> String {
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object([
            "client_name": .string(clientName),
            "redirect_uris": .array([.string(redirect)]),
            "token_endpoint_auth_method": "none",
            "grant_types": .array(["authorization_code", "refresh_token"]),
            "response_types": .array(["code"]),
        ]).encoded()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let id = try JSONValue.decode(data)["client_id"]?.stringValue else {
            throw PAPError.http(status)
        }
        return id
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(OAuthPKCE.formEncode(fields).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A refused grant (revoked, expired, or already used) won't work again: sign in anew.
            if status == 400 || status == 401 { keychain.delete(); accessToken = nil }
            throw PAPError.notAuthorized
        }
        return try JSONValue.decode(data)
    }
}
