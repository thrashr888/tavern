import SwiftUI

extension Notification.Name {
    /// Edit > Find (⌘F), Find Next (⌘G) and Find Previous (⇧⌘G), for the open conversation.
    static let tavernFind = Notification.Name("tavern.find")
    static let tavernFindNext = Notification.Name("tavern.findNext")
    static let tavernFindPrevious = Notification.Name("tavern.findPrevious")
}

/// A find bar over a conversation: the query, "3 of 12", previous and next, Done.
/// The owner computes `matches` (row ids, oldest first) and scrolls to `current`.
struct FindBar: View {
    @Binding var query: String
    @Binding var current: Int
    let matchCount: Int
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in conversation", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { step(-1) }
                .onExitCommand(perform: close)
            if !query.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(current + 1) of \(matchCount)")
                    .tavernFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(matchCount == 0).help("Previous match, older (⇧⌘G or Return)")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).disabled(matchCount == 0).help("Next match, newer (⌘G)")
            Button("Done", action: close).buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFind)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFindNext)) { _ in step(1) }
        .onReceive(NotificationCenter.default.publisher(for: .tavernFindPrevious)) { _ in step(-1) }
    }

    /// Moves through matches, wrapping; -1 goes to older messages.
    private func step(_ delta: Int) {
        guard matchCount > 0 else { return }
        current = (current + delta + matchCount) % matchCount
    }
}

/// Whether a message matches a find query (case and diacritic insensitive).
func findMatches(_ text: String, _ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces)
    return !needle.isEmpty && text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

extension View {
    /// Outlines a row that matches the find query; the current match more strongly.
    func findHighlight(matched: Bool, current: Bool) -> some View {
        padding(matched ? 4 : 0)
            .background(matched ? Color.yellow.opacity(current ? 0.22 : 0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(current ? Color.yellow.opacity(0.8) : Color.clear, lineWidth: 1.5))
    }
}
