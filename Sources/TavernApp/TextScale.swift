import SwiftUI

/// Tavern's type ramp. macOS doesn't scale SwiftUI text styles with Dynamic Type, and its defaults
/// (13pt body, 10–11pt captions) read small, so Tavern sets its own sizes and multiplies them by a
/// user-chosen scale (View > Bigger / Smaller / Actual Size, remembered across launches).
enum TavernTextStyle {
    case largeTitle, title, title2, title3, headline, body, callout, caption

    /// Sizes at scale 1.0: two steps above the SwiftUI macOS defaults.
    var baseSize: CGFloat {
        switch self {
        case .largeTitle: return 32
        case .title: return 26
        case .title2: return 21
        case .title3: return 18
        case .headline: return 15
        case .body: return 15
        case .callout: return 14
        case .caption: return 12.5
        }
    }

    var defaultWeight: Font.Weight {
        self == .headline ? .semibold : .regular
    }
}

enum TextScale {
    static let storageKey = "tavern.textScale"
    static let steps: [Double] = [0.85, 0.92, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7]
    static let standard = 1.0

    static func bigger(than scale: Double) -> Double {
        steps.first { $0 > scale + 0.001 } ?? steps.last!
    }

    static func smaller(than scale: Double) -> Double {
        steps.last { $0 < scale - 0.001 } ?? steps.first!
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = TextScale.standard
}

extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct TavernFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: TavernTextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: style.baseSize * scale, weight: weight ?? style.defaultWeight))
    }
}

extension View {
    /// A Tavern text style, scaled by the user's text size.
    func tavernFont(_ style: TavernTextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(TavernFont(style: style, weight: weight))
    }
}

/// View menu items: Bigger (⌘+ / ⌘=), Smaller (⌘−), Actual Size (⌘0).
struct TextSizeCommands: Commands {
    @AppStorage(TextScale.storageKey) private var scale = TextScale.standard

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger") { scale = TextScale.bigger(than: scale) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(scale >= TextScale.steps.last!)
            Button("Smaller") { scale = TextScale.smaller(than: scale) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= TextScale.steps.first!)
            Button("Actual Size") { scale = TextScale.standard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(scale == TextScale.standard)
        }
    }
}
