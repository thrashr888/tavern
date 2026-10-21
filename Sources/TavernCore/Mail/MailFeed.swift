import Foundation

/// The party mail feed the Mail page shows: signs in to Personal Agent Proxy, polls, and lists
/// threads from the event log. Never sends, labels or deletes mail; archives a thread only when
/// the user asks.
@MainActor
public final class MailFeed: ObservableObject {
    public enum State: Equatable {
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
    private let oauth: PAPOAuth?
    private let makeSync: @MainActor () -> PAPMailSync?
    private var polling: Task<Void, Never>?

    /// `makeSync` builds the syncer; tests pass one over a fake `PAPHTTP`.
    public init(store: EventStore, oauth: PAPOAuth?, signedIn: Bool, makeSync: @escaping @MainActor () -> PAPMailSync?) {
        self.store = store
        self.oauth = oauth
        self.makeSync = makeSync
        state = signedIn ? .ready : .signedOut
        reload()
    }

    /// Wires mail through Personal Agent Proxy with Tavern's sign-in. Each sync reads `roster()`
    /// for authors and projects; the label stays the one Tavern opened with.
    public static func live(store: EventStore, oauth: PAPOAuth, client: PAPClient, roster current: @escaping @MainActor () -> Roster) async -> MailFeed {
        let roster = current()
        MailItem.reattribute(store: store, roster: roster)
        let signedIn = await oauth.isSignedIn
        return MailFeed(store: store, oauth: oauth, signedIn: signedIn) {
            PAPMailSync(client: client, store: store, roster: current(), labelName: roster.mailLabelName)
        }
    }

    /// Why the last archive failed, if it did (PAP doesn't allow it, or the sign-in lapsed).
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
        } catch let error as PAPError where error.isForbidden {
            archiveError = "Personal Agent Proxy doesn't let Tavern archive. Allow Archive for Tavern's Gmail there."
        } catch PAPError.notAuthorized {
            state = .signedOut
            archiveError = "Sign in to Personal Agent Proxy again to archive."
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
        } catch PAPError.notAuthorized {
            state = .signedOut
        } catch {
            state = .failed(String(describing: error))
        }
        reload()
    }

    /// Polls until signed out. Safe to call again.
    public func startPolling() {
        guard polling == nil, state != .signedOut else { return }
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

    /// After a roster edit: gives stored mail without an author one by the new rules, and re-lists.
    public func rosterChanged(_ roster: Roster) {
        if MailItem.reattribute(store: store, roster: roster) > 0 { reload() }
    }

    private func reload() {
        threads = MailThread.threads(from: (try? store.events(source: EventSource.gmail)) ?? [])
    }
}
