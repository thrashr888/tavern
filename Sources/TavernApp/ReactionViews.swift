import SwiftUI
import TavernCore

/// Reactions under a message: one chip per emoji with a count, yours outlined.
struct ReactionChips: View {
    let reactions: [Reaction]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        let grouped = Dictionary(grouping: reactions, by: \.emoji)
        let order = reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { emoji in
                let all = grouped[emoji] ?? []
                let mine = all.contains(where: \.fromMe)
                Button { onTap?(emoji) } label: {
                    HStack(spacing: 3) {
                        Text(emoji)
                        if all.count > 1 { Text("\(all.count)").tavernFont(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(mine ? Color.tavernAccent : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .help(mine ? "You reacted \(emoji)" : "Reacted \(emoji)")
            }
        }
    }
}

/// The quick reactions Tavern offers, GitHub's set.
enum QuickReactions {
    static let emoji = ["👍", "👎", "😄", "🎉", "😕", "❤️", "🚀", "👀"]
}

/// A composer button that puts one of the quick reactions into the draft. For iMessage this is
/// how you react: Messages can't take a tapback from another app, so the emoji goes as a message.
struct EmojiDraftButton: View {
    @Binding var draft: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "face.smiling").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add a reaction")
        .popover(isPresented: $open, arrowEdge: .top) {
            HStack(spacing: 6) {
                ForEach(QuickReactions.emoji, id: \.self) { emoji in
                    Button(emoji) {
                        draft += (draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ") + emoji
                        open = false
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                }
            }
            .padding(10)
            .themedSurface()
        }
    }
}

/// A small "add reaction" button that opens the quick reactions.
struct AddReactionButton: View {
    let onPick: (String) -> Void
    @Binding var open: Bool

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "face.smiling").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("React")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                ForEach(QuickReactions.emoji, id: \.self) { emoji in
                    Button(emoji) {
                        onPick(emoji)
                        open = false
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                }
            }
            .padding(10)
            .themedSurface()
        }
    }
}
