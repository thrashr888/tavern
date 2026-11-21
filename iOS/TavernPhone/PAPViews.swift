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

    /// Whether the in-app sign-in sheet has failed, so Safari is offered instead.
    @Published private(set) var offerSafari = false
    private var safariReturn: CheckedContinuation<[String: String], Error>?

    /// In the app's own sign-in sheet, or in Safari, which comes back on the app's URL scheme
    /// (for a sign-in the sheet can't finish, such as an emailed link or Google's).
    func signIn(inSafari: Bool = false) async {
        error = nil
        do {
            try await oauth.signIn(redirect: "\(Self.scheme):/oauth", clientName: "Tavern iPhone") { url in
                if inSafari { return try await self.openInSafari(url) }
                return try await WebSignIn.run(url, scheme: Self.scheme)
            }
            signedIn = true
            offerSafari = false
        } catch {
            self.error = Self.message(for: error)
            offerSafari = true
        }
    }

    private func openInSafari(_ url: URL) async throws -> [String: String] {
        safariReturn?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { done in
            safariReturn = done
            UIApplication.shared.open(url)
        }
    }

    /// The app opened with a URL: PAP sending a Safari sign-in back.
    func handle(_ url: URL) {
        guard url.scheme == Self.scheme, let done = safariReturn else { return }
        safariReturn = nil
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        done.resume(returning: Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a }))
    }

    /// What went wrong, in words: nothing technical unless there's nothing better to say.
    static func message(for error: Error, signingIn: Bool = true) -> String? {
        switch error {
        case ASWebAuthenticationSessionError.canceledLogin:
            return "Sign-in closed before it finished. Try again, or sign in with Safari, which handles Google and emailed links."
        case ASWebAuthenticationSessionError.presentationContextNotProvided, ASWebAuthenticationSessionError.presentationContextInvalid:
            return "Tavern couldn't open the sign-in page. Try again."
        case OAuthError.denied:
            return "Personal Agent Proxy didn't allow Tavern iPhone. Approve it there, then sign in again."
        case OAuthError.stateMismatch, OAuthError.noCode:
            return "The sign-in didn't come back complete. Tap Sign in to try again."
        case let pap as PAPError:
            return pap.description
        case let url as URLError where url.code == .notConnectedToInternet || url.code == .networkConnectionLost:
            return "The iPhone is offline. Sign in once it's connected."
        default:
            return signingIn ? "Couldn't sign in to Personal Agent Proxy (\(error.localizedDescription))."
                : "Personal Agent Proxy didn't answer (\(error.localizedDescription)). Pull to try again."
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
            let result = try await client.read(google, "emails_list", ["search": "in:inbox", "folder": "Inbox"])
            return (result["records"]?.arrayValue ?? []).compactMap(MailRow.init)
        }
    }

    /// The team's Linear issues for Goals (the roster's `linearTeam`, bundled by scripts/party.sh).
    private(set) lazy var linear: LinearSource? = Party.info.linearTeam.flatMap { $0.isEmpty ? nil : LinearSource(proxy: client, teamKey: $0) }

    /// Open goals, recently updated first; cached for a couple of minutes unless `refresh`.
    func goals(refresh: Bool = false) async throws -> [LinearIssue] {
        guard let linear else { return [] }
        return try await client.task("Show Linear goals on Paul's iPhone", goal: "Read open issues for Tavern's Goals tab") {
            try await linear.openIssues(refresh: refresh)
        }
    }

    func goalDetail(_ identifier: String) async throws -> LinearIssueDetail? {
        try await linear?.detail(identifier)
    }
}

struct MailRow: Identifiable, Sendable {
    var id: String
    var subject: String
    var from: String
    var snippet: String
    var date: String

    init(id: String, subject: String, from: String, snippet: String, date: String) {
        self.id = id
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.date = date
    }

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
struct NeedsPAP<Content: View>: View {
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
                if pap.offerSafari {
                    Button("Sign in with Safari instead") { Task { await pap.signIn(inSafari: true) } }
                }
                if let error = pap.error { Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
        }
    }
}

/// Gmail through PAP, and iCloud Mail over IMAP with an app-specific password.
struct MailView: View {
    enum Box: String, CaseIterable { case gmail = "Gmail", icloud = "iCloud" }

    @EnvironmentObject private var pap: PAPPhone
    @AppStorage("tavern.mail.box") private var box: Box = .gmail
    @State private var icloudSetUp = ICloudMail.isSetUp

    var body: some View {
        Group {
            switch box {
            case .gmail:
                NeedsPAP(purpose: "your mail") { MailList(load: { try await pap.inbox() }) }
            case .icloud:
                if icloudSetUp {
                    MailList(load: { try await ICloudMail.inbox(limit: 40) })
                } else {
                    ICloudMailSetup { icloudSetUp = true }
                }
            }
        }
        .navigationTitle("Mail")
        .safeAreaInset(edge: .top) {
            Picker("Mailbox", selection: $box) { ForEach(Box.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
        }
        .toolbar {
            if box == .gmail, pap.signedIn { Button("Sign out") { Task { await pap.signOut() } } }
            if box == .icloud, icloudSetUp {
                Button("Remove") {
                    ICloudMail.forget()
                    icloudSetUp = false
                }
            }
        }
    }
}

/// Newest first, with pull to refresh.
private struct MailList: View {
    let load: () async throws -> [MailRow]
    @State private var rows: [MailRow] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
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
        .overlay {
            if !loaded { ProgressView() } else if rows.isEmpty && error == nil { ContentUnavailableView("Inbox zero", systemImage: "tray") }
        }
        .refreshable { await reload() }
        .task { if !loaded { await reload() } }
    }

    private func reload() async {
        do {
            rows = try await load()
            error = nil
        } catch {
            self.error = PAPPhone.message(for: error, signingIn: false)
        }
        loaded = true
    }
}

/// The iCloud address and an app-specific password, which Paul makes at account.apple.com.
private struct ICloudMailSetup: View {
    let done: () -> Void
    @State private var address = ""
    @State private var password = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("iCloud address", text: $address)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App-specific password", text: $password)
            } header: {
                Text("iCloud Mail")
            } footer: {
                Text("iOS doesn't let apps read Mail.app, so Tavern signs in to iCloud Mail itself, read-only. Make an app-specific password at account.apple.com > Sign-In and Security > App-Specific Passwords. It stays in this iPhone's Keychain.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Button(checking ? "Checking…" : "Connect") {
                checking = true
                Task {
                    do {
                        try ICloudMail.save(address: address, password: password)
                        _ = try await ICloudMail.inbox(limit: 1)
                        done()
                    } catch {
                        ICloudMail.forget()
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                    checking = false
                }
            }
            .disabled(checking || !address.contains("@") || password.count < 16)
            if let url = URL(string: "https://account.apple.com/account/manage") {
                Link("Open account.apple.com", destination: url)
            }
        }
    }
}
