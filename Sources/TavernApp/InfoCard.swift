import AppKit
import SwiftUI

/// A titled card of label/value rows, after Orchard's detail panes: roomy, monospaced where the
/// value is an identifier, with Copy on the values people paste elsewhere.
struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tavernFont(.headline, weight: .semibold)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.8)))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false
    var link: URL?

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Group {
                if let link {
                    Link(destination: link) {
                        Text(value).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(value).font(monospaced ? .system(.callout, design: .monospaced) : nil)
                }
            }
            .textSelection(.enabled)
            // Identifiers stay on one line, truncated in the middle; Copy still gets all of it.
            .lineLimit(value.contains("\n") ? nil : (monospaced || copyable || link != nil ? 1 : 3))
            .truncationMode(.middle)
            .help(value)
            .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Copy \(label)")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .tavernFont(.callout)
    }
}
