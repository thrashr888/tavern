import AppKit
import SwiftUI

/// Keeps a split's divider where the user dragged it, across pages and launches: names the
/// nearest enclosing `NSSplitView` (HSplitView, the inspector's split) so AppKit saves and
/// restores its divider positions.
private struct SplitAutosaveView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var node = view.superview
            while let current = node, !(current is NSSplitView) { node = current.superview }
            // The first name a split gets stays (a page's inspector and the sidebar can share one).
            guard let split = node as? NSSplitView, (split.autosaveName ?? "").isEmpty else { return }
            split.autosaveName = "tavern.split.\(name)"
        }
    }
}

extension View {
    /// Remembers the widths of the split this view sits in, under `name`.
    func splitAutosave(_ name: String) -> some View { background(SplitAutosaveView(name: name)) }
}
