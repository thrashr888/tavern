import AppKit
import SwiftUI
import TavernCore

/// Previews for links in Pi threads, loaded once per address and shared by every chip, card and
/// the inspector's Links tab. Mail never asks: fetching a mail link can ping a tracker.
@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    @Published private(set) var previews: [URL: LinkPreview] = [:]
    @Published private(set) var loading: Set<URL> = []
    private var requested: Set<URL> = []
    private let images = NSCache<NSString, NSImage>()

    func preview(for url: URL) -> LinkPreview? { previews[LinkPreviewCache.normalized(url)] }
    func isLoading(_ url: URL) -> Bool { loading.contains(LinkPreviewCache.normalized(url)) }

    func request(_ url: URL) {
        let url = LinkPreviewCache.normalized(url)
        guard requested.insert(url).inserted else { return }
        loading.insert(url)
        Task {
            let preview = await LinkPreviewFetcher.shared.preview(for: url)
            loading.remove(url)
            if let preview { previews[url] = preview }
        }
    }

    /// A cached icon or hero image, read from disk once.
    func image(_ name: String?) -> NSImage? {
        guard let name, let file = LinkPreviewCache.file(name) else { return nil }
        if let image = images.object(forKey: name as NSString) { return image }
        guard let image = NSImage(contentsOf: file) else { return nil }
        images.setObject(image, forKey: name as NSString)
        return image
    }
}

/// Chips under a message for the links in it: favicon, page title, chevron. Click for the card.
struct LinkChipRow: View {
    let urls: [URL]
    var trailing = false

    var body: some View {
        if trailing {
            HStack(spacing: 6) { chips }
        } else {
            FlowLayout { chips }
        }
    }

    private var chips: some View {
        ForEach(urls, id: \.self) { LinkChip(url: $0) }
    }
}

struct LinkChip: View {
    let url: URL
    @ObservedObject private var previews = LinkPreviews.shared
    @State private var showing = false

    var body: some View {
        let preview = previews.preview(for: url)
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                LinkFavicon(preview: preview, size: 14)
                Text(preview?.displayTitle ?? LinkPreview.domain(of: url))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .tavernFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .popover(isPresented: $showing, arrowEdge: .bottom) { LinkCard(url: url) }
        .onAppear { previews.request(url) }
    }
}

/// The site icon, or a globe while it loads or when the site has none.
struct LinkFavicon: View {
    let preview: LinkPreview?
    var size: CGFloat = 14

    var body: some View {
        if let icon = LinkPreviews.shared.image(preview?.iconFile) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 5))
        } else {
            Image(systemName: "globe").frame(width: size, height: size)
        }
    }
}

/// A link's card, as in the Apple Bots app: hero image, domain, title, description, actions.
struct LinkCard: View {
    let url: URL
    @ObservedObject private var previews = LinkPreviews.shared

    var body: some View {
        let preview = previews.preview(for: url)
        VStack(alignment: .leading, spacing: 0) {
            if let hero = previews.image(preview?.imageFile) {
                Image(nsImage: hero)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 340, height: 170)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    LinkFavicon(preview: preview, size: 16)
                    Text(preview?.siteName ?? LinkPreview.domain(of: url)).lineLimit(1)
                    if previews.isLoading(url) { ProgressView().controlSize(.mini) }
                }
                .tavernFont(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                Text(preview?.displayTitle ?? url.absoluteString)
                    .tavernFont(.headline, weight: .semibold)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = preview?.summary {
                    Text(summary)
                        .tavernFont(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "safari") }
                        .keyboardShortcut(.defaultAction)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(14)
        }
        .frame(width: 340, alignment: .leading)
        .onAppear { previews.request(url) }
    }
}

/// The inspector's Links tab: every link in the agent's thread, newest first, once each.
struct LinksSection: View {
    @ObservedObject var session: PiAgentSession
    var agentName: String

    var body: some View {
        let links = Self.links(in: session.transcript)
        VStack(alignment: .leading, spacing: 10) {
            Text("Links").tavernFont(.caption, weight: .semibold).foregroundStyle(.secondary)
            if links.isEmpty {
                Text("No links in this thread yet.").tavernFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(links, id: \.url) { link in
                LinkListRow(url: link.url, from: link.fromUser ? "You" : agentName, date: link.date)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Link {
        var url: URL
        var fromUser: Bool
        var date: Date
    }

    /// Newest message first; a link sent twice shows once, where it was last sent.
    static func links(in transcript: [TranscriptItem], limit: Int = 100) -> [Link] {
        var seen = Set<URL>()
        var result: [Link] = []
        for item in transcript.reversed() where item.role == .user || item.role == .assistant {
            let text = item.role == .user ? AttachmentCache.split(item.text).text : item.text
            for url in LinkPreviewPolicy.previewable(in: text, limit: 20) where seen.insert(url).inserted {
                result.append(Link(url: url, fromUser: item.role == .user, date: item.date))
            }
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }
}

private struct LinkListRow: View {
    let url: URL
    let from: String
    let date: Date
    @ObservedObject private var previews = LinkPreviews.shared
    @State private var showing = false

    var body: some View {
        let preview = previews.preview(for: url)
        Button { showing.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                thumbnail(preview)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.displayTitle ?? LinkPreview.domain(of: url))
                        .tavernFont(.callout, weight: .semibold).lineLimit(2)
                    Text(LinkPreview.domain(of: url)).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let summary = preview?.summary {
                        Text(summary).tavernFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("\(from) · \(date.formatted(.relative(presentation: .named)))")
                        .tavernFont(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .popover(isPresented: $showing, arrowEdge: .leading) { LinkCard(url: url) }
        .onAppear { previews.request(url) }
    }

    @ViewBuilder
    private func thumbnail(_ preview: LinkPreview?) -> some View {
        Group {
            if let image = previews.image(preview?.imageFile) ?? previews.image(preview?.iconFile) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "globe").imageScale(.large).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
