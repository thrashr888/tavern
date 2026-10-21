import Foundation

/// Where Tavern keeps its files: ~/Library/Application Support/Tavern, or `TAVERN_HOME` for a
/// separate party (a demo, screenshots) that must not touch the real one: its own roster, event
/// store and art, its own Personal Agent Proxy sign-in, and no notifications.
public enum TavernPaths {
    public static var separateHome: URL? {
        guard let home = ProcessInfo.processInfo.environment["TAVERN_HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var base: URL? {
        separateHome ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tavern", isDirectory: true)
    }

    public static func file(_ name: String) -> URL? { base?.appendingPathComponent(name) }

    /// The user's home folder; on iPhone, the app's own container.
    public static var userHome: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
