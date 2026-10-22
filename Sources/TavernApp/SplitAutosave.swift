import AppKit
import SwiftUI

/// Keeps a split's dividers where the user dragged them, across pages and launches. SwiftUI's
/// split views don't save through `NSSplitView.autosaveName`, so this finds the nearest enclosing
/// `NSSplitView` (HSplitView, the inspector's split), puts its dividers back where they were last
/// left, and saves them whenever they move.
private struct SplitAutosaveView: NSViewRepresentable {
    let name: String

    func makeCoordinator() -> SplitMemory { SplitMemory(name: name) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let memory = context.coordinator
        DispatchQueue.main.async {
            var node = view.superview
            while let current = node, !(current is NSSplitView) { node = current.superview }
            guard let split = node as? NSSplitView else { return }
            memory.attach(to: split)
        }
    }
}

@MainActor
final class SplitMemory {
    let name: String
    private weak var split: NSSplitView?
    private var observer: NSObjectProtocol?
    private var restoring = false
    private var key: String { "tavern.split.\(name)" }

    init(name: String) { self.name = name }

    func attach(to split: NSSplitView) {
        guard self.split !== split else { return }
        self.split = split
        if let observer { NotificationCenter.default.removeObserver(observer) }
        restore(split)
        observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Divider positions, left to right; only saved when the user moved one (not window resizes
    /// or our own restore).
    private func save() {
        guard !restoring, let split, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let positions = split.arrangedSubviews.dropLast().map { split.isVertical ? Double($0.frame.maxX) : Double($0.frame.maxY) }
        UserDefaults.standard.set(positions, forKey: key)
    }

    private func restore(_ split: NSSplitView) {
        guard let positions = UserDefaults.standard.array(forKey: key) as? [Double],
              positions.count == split.arrangedSubviews.count - 1 else { return }
        // After SwiftUI's first layout, so its ideal widths don't win.
        DispatchQueue.main.async {
            self.restoring = true
            for (index, position) in positions.enumerated() { split.setPosition(CGFloat(position), ofDividerAt: index) }
            self.restoring = false
        }
    }
}

extension View {
    /// Remembers the widths of the split this view sits in, under `name`.
    func splitAutosave(_ name: String) -> some View { background(SplitAutosaveView(name: name)) }
}
