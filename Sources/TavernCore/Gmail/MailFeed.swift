import Foundation

/// The read-only party mail feed the Mail page shows: signs in, polls, and lists threads from the
/// event log. Never sends, labels, archives or deletes mail.
@MainActor
public final class MailFeed: ObservableObject {
    public enum State: Equatable {
        /// No OAuth client file on this Mac yet (the user creates the client; plan 5.3).
        case notConfigured
        case signedOut
        case signingIn
        case syncing
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State
    @Published public private(set) var threads: [MailThread] = []
    @Published public private(set) var lastSync: Date?
    /// Threads still in the inbox; nil until the first sync reads it. The rest are archived.
    @Published public private(set) var inboxThreads: Set<String>?

    public var pollInterval: Duration = .seconds(90)

    private let store: EventStore
    private let oauth: GmailOAuth?
    private let makeSync: @MainActor () -> GmailSync?
    private var polling: Task<Void, Never>?

    /// `makeSync` builds the syncer once signed in; tests pass one over a fake `GmailHTTP`.
    public init(store: EventStore, oauth: GmailOAuth?, signedIn: Bool, makeSync: @escaping @MainActor () -> GmailSync?) {
        self.store = store
        self.oauth = oauth
        self.makeSync = makeSync
        state = oauth == nil ? .notConfigured : (signedIn ? .ready : .signedOut)
        reload()
    }

    /// Wires the real Gmail API with the client file and Keychain token on this Mac.
    public static func live(store: EventStore, roster: Roster) async -> MailFeed {
        MailItem.reattribute(store: store, roster: roster)
        guard let client = GmailOAuth.Client.load() else {
            return MailFeed(store: store, oauth: nil, signedIn: false) { nil }
        }
        let oauth = GmailOAuth(client: client)
        let signedIn = await oauth.isSignedIn
        return MailFeed(store: store, oauth: oauth, signedIn: signedIn) {
            let http = GmailURLSessionHTTP { try await oauth.token() }
            return GmailSync(api: GmailAPI(http: http), store: store, roster: roster)
        }
    }

    /// Why the last archive failed, if it did ("reconnect Gmail" when the token predates archiving).
    @Published public private(set) var archiveError: String?
    /// Threads archived from Tavern since launch, hidden even before the next sync confirms it.
    @Published public private(set) var archivedHere: Set<String> = []

    /// Archives a thread in Gmail (out of the inbox only) and hides it here right away.
    public func archive(_ thread: MailThread) async {
        guard let sync = makeSync() else { return }
        do {
            try await sync.archive(threadID: thread.threadID)
            inboxThreads?.remove(thread.threadID)
            archivedHere.insert(thread.threadID)
            archiveError = nil
        } catch GmailError.notAuthorized {
            archiveError = "Gmail didn't allow archiving. Disconnect and connect Gmail again to grant it."
        } catch {
            archiveError = "Couldn't archive: \(error)"
        }
    }

    /// Archived in Gmail: no message of the thread is in the inbox any more.
    public func isArchived(_ thread: MailThread) -> Bool {
        if archivedHere.contains(thread.threadID) { return true }
        guard let inboxThreads else { return false }
        return !inboxThreads.contains(thread.threadID)
    }

    public func threads(project: String?) -> [MailThread] {
        project == nil ? threads : threads.filter { $0.project == project }
    }

    public func signIn(open: @escaping @Sendable (URL) -> Void) async {
        guard let oauth else { return }
        state = .signingIn
        do {
            try await oauth.signIn(open: open)
            await refresh()
            startPolling()
        } catch {
            state = .failed("Sign-in failed: \(error)")
        }
    }

    public func signOut() async {
        polling?.cancel()
        polling = nil
        await oauth?.signOut()
        if oauth != nil { state = .signedOut }
    }

    /// One sync now. Mail already stored stays visible whatever happens.
    public func refresh() async {
        guard let sync = makeSync() else { return }
        state = .syncing
        do {
            try await sync.sync()
            inboxThreads = (try? await sync.inboxThreads()) ?? inboxThreads
            lastSync = Date()
            state = .ready
        } catch GmailError.notAuthorized {
            state = .signedOut
        } catch GmailError.labelNotFound(let name) {
            state = .failed("No Gmail label named \(name)")
        } catch {
            state = .failed(String(describing: error))
        }
        reload()
    }

    /// Polls until signed out. Safe to call again.
    public func startPolling() {
        guard polling == nil, state != .notConfigured, state != .signedOut else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if self.state == .signedOut { self.polling = nil; return }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func reload() {
        threads = MailThread.threads(from: (try? store.events(source: EventSource.gmail)) ?? [])
    }
}
