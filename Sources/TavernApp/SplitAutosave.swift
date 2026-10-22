import AppKit
import SwiftUI

/// A fixed-width pane beside the rest, with a divider the user drags. The width is Tavern's own
/// setting (`tavern.column.<name>`), so it stays where it was left across pages and launches;
/// SwiftUI's split views never kept it.
struct ResizablePane<Pane: View, Rest: View>: View {
    let name: String
    let range: ClosedRange<CGFloat>
    @ViewBuilder let pane: () -> Pane
    @ViewBuilder let rest: () -> Rest
    @AppStorage private var width: Double
    @State private var dragStart: Double?

    init(_ name: String, ideal: CGFloat, range: ClosedRange<CGFloat>,
         @ViewBuilder pane: @escaping () -> Pane, @ViewBuilder rest: @escaping () -> Rest) {
        self.name = name
        self.range = range
        self.pane = pane
        self.rest = rest
        _width = AppStorage(wrappedValue: Double(ideal), "tavern.column.\(name)")
    }

    var body: some View {
        HStack(spacing: 0) {
            pane().frame(width: clamped)
            Divider()
                .overlay {
                    // A wider grab area than the line itself.
                    Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStart ?? Double(clamped)
                                    dragStart = start
                                    width = Double(min(max(CGFloat(start) + drag.translation.width, range.lowerBound), range.upperBound))
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            rest().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var clamped: CGFloat { min(max(CGFloat(width), range.lowerBound), range.upperBound) }
}

/// The inspector's width, kept across pages and launches: SwiftUI reads `ideal` when the panel
/// appears, so the width the user left it at becomes the ideal next time.
private struct InspectorWidth: ViewModifier {
    let range: ClosedRange<CGFloat>
    @AppStorage("tavern.column.inspector") private var width: Double = 310

    func body(content: Content) -> some View {
        content
            .inspectorColumnWidth(min: range.lowerBound, ideal: min(max(CGFloat(width), range.lowerBound), range.upperBound), max: range.upperBound)
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width) { _, new in
                        // Only the user's drag changes it; ignore the first, laid-out-at-ideal size.
                        if new >= range.lowerBound, new <= range.upperBound, abs(new - CGFloat(width)) > 1 { width = Double(new) }
                    }
                }
            }
    }
}

extension View {
    /// The inspector at the width the user last left it, between `range`'s bounds.
    func rememberedInspectorWidth(_ range: ClosedRange<CGFloat>) -> some View { modifier(InspectorWidth(range: range)) }
}
