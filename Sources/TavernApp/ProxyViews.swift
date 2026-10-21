import SwiftUI
import TavernCore

/// "Sign in to Personal Agent Proxy": the one sign-in that brings in party mail and Linear.
/// Shown on Mail and Goals until it's done, and in Settings.
struct ProxySignInPrompt: View {
    @EnvironmentObject private var model: AppModel
    /// "to read Party threads".
    let purpose: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Sign in to Personal Agent Proxy \(purpose)").tavernFont(.title3, weight: .semibold)
                .multilineTextAlignment(.center)
            Text(ProxySettings.firstSignInNote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProxySignInButton()
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sign In, or "Waiting for Personal Agent Proxy…" while the browser is out.
struct ProxySignInButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let feed = model.mail {
            Watching(feed: feed)
        } else {
            Button("Sign In…") { Task { await model.signInToProxy() } }.buttonStyle(.borderedProminent)
        }
    }

    private struct Watching: View {
        @EnvironmentObject private var model: AppModel
        @ObservedObject var feed: MailFeed

        var body: some View {
            Button(feed.state == .signingIn ? "Waiting for Personal Agent Proxy…" : "Sign In…") {
                Task { await model.signInToProxy() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(feed.state == .signingIn)
        }
    }
}

/// Settings > Connections: the Personal Agent Proxy sign-in and what Tavern may use there.
struct ProxySettings: View {
    @EnvironmentObject private var model: AppModel

    static let firstSignInNote = """
        The first time, choose Custom MCP agent and name it Tavern. Then, in Personal Agent Proxy, \
        give Tavern your Gmail (read, and archive if you like) and Linear (read, create and edit issues).
        """

    var body: some View {
        Form {
            Section {
                if let feed = model.mail {
                    Status(feed: feed)
                } else {
                    ProxySignInButton()
                }
                if let connections = model.proxyConnections {
                    if connections.isEmpty {
                        Text("Tavern can't use anything yet. Give it access in Personal Agent Proxy.").foregroundStyle(.secondary)
                    }
                    ForEach(connections, id: \.id) { connection in
                        LabeledContent("\(connection.integration) · \(connection.account)") {
                            Text(connection.can).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.proxyError {
                    Label(error, systemImage: "exclamationmark.triangle").tavernFont(.caption).foregroundStyle(.orange)
                }
                Link("Open Personal Agent Proxy", destination: PAP.defaultBase)
            } header: {
                Text("Personal Agent Proxy")
            } footer: {
                Text("Mail and Linear come through Personal Agent Proxy: one sign-in on each Mac, and you set what Tavern may do there.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadProxyConnections() }
    }

    private struct Status: View {
        @EnvironmentObject private var model: AppModel
        @ObservedObject var feed: MailFeed

        var body: some View {
            switch feed.state {
            case .signedOut, .signingIn:
                VStack(alignment: .leading, spacing: 8) {
                    Text(ProxySettings.firstSignInNote).foregroundStyle(.secondary)
                    ProxySignInButton()
                }
            default:
                HStack {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") { Task { await model.signOutOfProxy() } }
                }
            }
        }
    }
}
