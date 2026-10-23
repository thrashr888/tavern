import AuthenticationServices
import SwiftUI
import TavernCore

/// The phone's own Personal Agent Proxy login ("Tavern iPhone"): Paul approves it and sets its
/// permissions in PAP. The phone only reads (mail and Linear issues), one PAP task per refresh.
@MainActor
final class PAPPhone: ObservableObject {
    static let scheme = "dev.thrashr888.tavern.phone"
    @Published private(set) var signedIn = false
    @Published var error: String?

    let oauth = PAPOAuth(keychain: KeychainTokenStore(service: "Tavern iPhone Personal Agent Proxy"))
    private(set) lazy var client = PAPClient.live(oauth: oauth)

    init() {
        Task { signedIn = await oauth.isSignedIn }
    }

    func signIn() async {
        error = nil
        do {
            try await oauth.signIn(redirect: "\(Self.scheme):/oauth", clientName: "Tavern iPhone") { url in
                try await WebSignIn.run(url, scheme: Self.scheme)
            }
            signedIn = true
        } catch {
            self.error = "Couldn't sign in: \(error)"
        }
    }

    func signOut() async {
        await oauth.signOut()
        signedIn = false
    }

    /// Mail in the inbox, newest first.
    func inbox() async throws -> [MailRow] {
        try await client.task("Show Paul's inbox on his iPhone", goal: "Read the newest inbox mail for Tavern's Mail tab") { [client] in
            let google = try await client.connection("Google", describedAs: "Gmail connection").id
            let result = try await client.read(google, "emails_list", ["search": "in:inbox", "folder": "inbox"])
            return (result["records"]?.arrayValue ?? []).compactMap(MailRow.init)
        }
    }

    /// Open Linear issues.
    func issues() async throws -> [IssueRow] {
        try await client.task("Show Linear issues on Paul's iPhone", goal: "Read open issues for Tavern's Linear tab") { [client] in
            let linear = try await client.connection("Linear", describedAs: "Linear connection").id
            var rows: [IssueRow] = []
            for type in ["Started", "Unstarted", "Triage"] {
                let result = try await client.read(linear, "issues_list", ["statusType": .string(type)])
                rows += (result["records"]?.arrayValue ?? []).compactMap(IssueRow.init)
            }
            return rows
        }
    }
}

struct MailRow: Identifiable, Sendable {
    var id: String
    var subject: String
    var from: String
    var snippet: String
    var date: String

    init?(_ record: JSONValue) {
        guard let id = record["id"]?.stringValue, !id.hasPrefix("draft-") else { return nil }
        let values = record["values"]
        self.id = id
        subject = values?["subject"]?.stringValue ?? record["title"]?.stringValue ?? "(no subject)"
        from = values?["from"]?.stringValue ?? ""
        snippet = values?["snippet"]?.stringValue ?? values?["preview"]?.stringValue ?? ""
        date = values?["date"]?.stringValue ?? ""
    }
}

struct IssueRow: Identifiable, Sendable {
    var id: String
    var title: String
    var status: String
    var assignee: String
    var url: URL?

    init?(_ record: JSONValue) {
        guard let id = record["id"]?.stringValue, let values = record["values"] else { return nil }
        self.id = id
        title = values["title"]?.stringValue ?? ""
        status = values["status"]?.stringValue ?? ""
        assignee = values["assignee"]?.stringValue ?? ""
        url = record["url"]?.stringValue.flatMap(URL.init(string:))
    }
}

/// PAP's sign-in page in an ASWebAuthenticationSession; returns the redirect's query.
enum WebSignIn {
    @MainActor private static var current: ASWebAuthenticationSession?
    @MainActor private static let anchor = Anchor()

    @MainActor
    static func run(_ url: URL, scheme: String) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { done in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                current = nil
                if let error { return done.resume(throwing: error) }
                let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                done.resume(returning: Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a }))
            }
            session.presentationContextProvider = anchor
            current = session
            session.start()
        }
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// "Sign in to Personal Agent Proxy" until there's a login, then the content.
private struct NeedsPAP<Content: View>: View {
    @EnvironmentObject private var pap: PAPPhone
    let purpose: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        if pap.signedIn {
            content()
        } else {
            ContentUnavailableView {
                Label("Personal Agent Proxy", systemImage: "key")
            } description: {
                Text("Sign in so Tavern can read \(purpose). In PAP, approve the \"Tavern iPhone\" agent and give it read access.")
            } actions: {
                Button("Sign in") { Task { await pap.signIn() } }.buttonStyle(.borderedProminent).tint(Color.tavernAccent)
                if let error = pap.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
    }
}

struct MailView: View {
    @EnvironmentObject private var pap: PAPPhone
    @State private var rows: [MailRow] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NeedsPAP(purpose: "your mail") {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.from).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(row.date).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(row.subject).font(.subheadline).lineLimit(2)
                        if !row.snippet.isEmpty { Text(row.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
            .overlay { if loaded && rows.isEmpty && error == nil { ContentUnavailableView("Inbox zero", systemImage: "tray") } }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
        }
        .navigationTitle("Mail")
        .toolbar { if pap.signedIn { Button("Sign out") { Task { await pap.signOut() } } } }
    }

    private func load() async {
        do {
            rows = try await pap.inbox()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        loaded = true
    }
}

struct LinearView: View {
    @EnvironmentObject private var pap: PAPPhone
    @State private var rows: [IssueRow] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NeedsPAP(purpose: "Linear") {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(rows) { row in
                    let label = VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row.status).font(.caption2.weight(.semibold)).foregroundStyle(Color.tavernAccent)
                            Spacer()
                            if !row.assignee.isEmpty { Text(row.assignee).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(row.title).font(.subheadline).lineLimit(2)
                    }
                    if let url = row.url { Link(destination: url) { label.foregroundStyle(.primary) } } else { label }
                }
            }
            .overlay { if loaded && rows.isEmpty && error == nil { ContentUnavailableView("No open issues", systemImage: "checkmark.circle") } }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
        }
        .navigationTitle("Linear")
    }

    private func load() async {
        do {
            rows = try await pap.issues()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        loaded = true
    }
}
