import Foundation

/// Where Tavern gets mail and Linear: through Personal Agent Proxy (one sign-in, permissions set in
/// PAP), or directly with this Mac's own Gmail OAuth client and Linear key file.
public enum ServiceRoute: String, CaseIterable, Sendable {
    case proxy
    case direct

    public static let defaultsKey = "tavern.services.route"

    /// The saved choice; without one, direct when this Mac already has the Gmail client file or the
    /// Linear key (an existing setup keeps working), else Personal Agent Proxy.
    public static func current(defaults: UserDefaults = .standard,
                               fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> ServiceRoute {
        if let saved = defaults.string(forKey: defaultsKey).flatMap(ServiceRoute.init(rawValue:)) { return saved }
        let direct = [GmailOAuth.Client.defaultURL(), LinearSource.defaultKeyURL].compactMap { $0 }.contains(where: fileExists)
        return direct ? .direct : .proxy
    }
}
