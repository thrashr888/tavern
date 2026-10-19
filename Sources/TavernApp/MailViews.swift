import AppKit
import SwiftUI
import TavernCore

/// Shared party threads, read-only: a thread list and a reading pane.
struct MailView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String?

    var body: some View {
        Group {
            if let feed = model.mail {
                MailFeedView(feed: feed, projectID: projectID, title: title)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        projectID.flatMap { id in model.roster.mailProjects.first { $0.id == id }?.label } ?? "All threads"
    }
}

private struct MailFeedView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feed: MailFeed
    let projectID: String?
    let title: String
    @State private var selectedThread: String?
    /// Heartbeat mails are agents' hourly status; hidden from the list unless asked for.
    @AppStorage("tavern.mail.showHeartbeats") private var showHeartbeats = false
    /// Threads archived in Gmail are hidden unless asked for.
    @AppStorage("tavern.mail.showArchived") private var showArchived = false

    var body: some View {
        switch feed.state {
        // Mail already stored stays readable while Gmail is unset or signed out.
        case .notConfigured where feed.threads.isEmpty:
            MailSetupNote()
        case .signedOut where feed.threads.isEmpty, .signingIn where feed.threads.isEmpty:
            connectPrompt
        default:
            HStack(spacing: 0) {
                threadList.frame(width: 340)
                    .onAppear(perform: takeFocusedThread)
                    .onChange(of: model.focusedMailThread) { _, _ in takeFocusedThread() }
                Divider()
                readingPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onReceive(NotificationCenter.default.publisher(for: .tavernRefresh)) { _ in Task { await feed.refresh() } }
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $showArchived) { Label("Archived", systemImage: "archivebox") }
                        .help(showArchived ? "Hide threads archived in Gmail" : "Show threads archived in Gmail")
                }
                ToolbarItem {
                    Toggle(isOn: $showHeartbeats) { Label("Heartbeats", systemImage: "waveform.path.ecg") }
                        .help(showHeartbeats ? "Hide agents' heartbeat mails" : "Show agents' heartbeat mails")
                }
                ToolbarItem {
                    Button { Task { await feed.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(feed.state == .syncing)
                        .help(lastSyncText)
                }
            }
        }
    }

    private var threads: [MailThread] {
        feed.threads(project: projectID)
            .filter { showHeartbeats || !$0.isHeartbeat }
            .filter { showArchived || !feed.isArchived($0) }
    }

    /// Selects the thread search or the Dashboard asked for, once.
    private func takeFocusedThread() {
        guard let thread = model.focusedMailThread else { return }
        selectedThread = thread
        model.focusedMailThread = nil
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            statusBar
            List(threads, selection: $selectedThread) { thread in
                ThreadRow(thread: thread, roster: model.roster).tag(thread.threadID)
            }
            .overlay {
                if threads.isEmpty {
                    Text(feed.state == .syncing ? "Reading \(model.roster.party) mail…" : "No \(model.roster.party) threads here yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        if case .failed(let reason) = feed.state {
            Label(reason, systemImage: "exclamationmark.triangle")
                .tavernFont(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var readingPane: some View {
        if let thread = threads.first(where: { $0.threadID == selectedThread }) {
            ThreadReader(thread: thread, roster: model.roster, feed: feed) {
                // After archiving, move to the next thread in the list.
                let list = threads
                if let index = list.firstIndex(where: { $0.threadID == thread.threadID }) {
                    let next = list.indices.contains(index + 1) ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
                    selectedThread = next?.threadID
                }
            }
        } else {
            Text("Select a thread").foregroundStyle(.secondary)
        }
    }

    private var lastSyncText: String {
        guard let date = feed.lastSync else { return "Not synced yet" }
        return "Synced \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Connect Gmail to read \(model.roster.party) threads").tavernFont(.title3, weight: .semibold)
            Text("Reads mail labelled \(model.roster.mailLabelName), and archives a thread when you ask. Tavern never sends or deletes mail.")
                .foregroundStyle(.secondary)
            Button(feed.state == .signingIn ? "Waiting for Google…" : "Connect Gmail") {
                Task { await feed.signIn { url in Task { @MainActor in NSWorkspace.shared.open(url) } } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(feed.state == .signingIn)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown until an OAuth client file exists on this Mac.
private struct MailSetupNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gmail isn't set up on this Mac").tavernFont(.title3, weight: .semibold)
            Text("Tavern reads labelled mail with a desktop OAuth client from your own Google Cloud project (Gmail read-only scope). Save its downloaded JSON as:")
                .foregroundStyle(.secondary)
            Text("~/Library/Application Support/Tavern/gmail-oauth-client.json")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Then reopen this page and choose Connect Gmail.").foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadRow: View {
    let thread: MailThread
    let roster: Roster

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(thread.subject).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text(thread.lastDate.formatted(.relative(presentation: .numeric)))
                    .tavernFont(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(thread.authors.compactMap(roster.member(id:))) { member in
                    AvatarView(member: member, size: 24)
                }
                Text(thread.messages.last?.snippet ?? "")
                    .tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThreadReader: View {
    let thread: MailThread
    let roster: Roster
    @ObservedObject var feed: MailFeed
    let archived: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.subject).tavernFont(.title2, weight: .semibold).textSelection(.enabled)
                    Spacer()
                    if feed.isArchived(thread) {
                        Label("Archived", systemImage: "archivebox").tavernFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            let current = thread
                            archived()
                            Task { await feed.archive(current) }
                        } label: { Label("Archive", systemImage: "archivebox") }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut("a", modifiers: [.command, .control])
                        .help("Archive this thread in Gmail (⌃⌘A)")
                    }
                    if let url = thread.gmailURL {
                        Link("Open in Gmail", destination: url)
                    }
                }
                if let error = feed.archiveError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Reconnect Gmail") {
                            Task {
                                await feed.signOut()
                                await feed.signIn { NSWorkspace.shared.open($0) }
                            }
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                ForEach(thread.messages) { message in
                    MessageCard(message: message, member: message.author.flatMap(roster.member(id:)))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MessageCard: View {
    let message: MailItem
    let member: RosterMember?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let member { AvatarView(member: member, size: 36) }
                Text(member?.name ?? message.from).fontWeight(.semibold)
                Spacer()
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .tavernFont(.caption).foregroundStyle(.secondary)
            }
            Text(LinkedText.attributed(message.body.isEmpty ? message.snippet : message.body))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
