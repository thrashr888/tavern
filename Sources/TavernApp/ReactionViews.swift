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
                    .overlay(Capsule().strokeBorder(mine ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .help(mine ? "You reacted \(emoji)" : "Reacted \(emoji)")
            }
        }
    }
}

/// The quick reactions offered on a Pi reply: Tavern's own, not iMessage's six.
enum QuickReactions {
    static let emoji = ["👍", "❤️", "😂", "🎉", "👀", "🤔", "👎"]
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
        }
    }
}
