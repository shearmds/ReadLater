import SwiftUI

// Shared visual language for the ReadLater iOS app, adapted from QuickNote:
// a rounded system font scaled by a user-chosen text size, a press-response
// button style, and small helpers that let the selected AppTheme drive the
// app's accents (card spines, buttons, focus) rather than a single fixed brand.

// MARK: - Text sizing

/// User-selectable text size, expressed as a scale multiplier applied on top of
/// each text style's natural (Dynamic Type) size. Mirrors QuickNote so the two
/// apps share one text-scaling model.
enum NoteTextSize: Int, CaseIterable, Identifiable {
    case small, standard, large, xLarge, xxLarge

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .small:    return "Small"
        case .standard: return "Default"
        case .large:    return "Large"
        case .xLarge:   return "Extra Large"
        case .xxLarge:  return "Huge"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:    return 0.85
        case .standard: return 1.0
        case .large:    return 1.2
        case .xLarge:   return 1.4
        case .xxLarge:  return 1.7
        }
    }
}

private struct NoteTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier applied to text by `scaledFont(_:)`.
    var noteTextScale: CGFloat {
        get { self[NoteTextScaleKey.self] }
        set { self[NoteTextScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// The natural point size of this text style on iOS, which already reflects
    /// the user's system text-size setting.
    var platformPointSize: CGFloat {
        let uiStyle: UIFont.TextStyle
        switch self {
        case .largeTitle:  uiStyle = .largeTitle
        case .title:       uiStyle = .title1
        case .title2:      uiStyle = .title2
        case .title3:      uiStyle = .title3
        case .headline:    uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .callout:     uiStyle = .callout
        case .footnote:    uiStyle = .footnote
        case .caption:     uiStyle = .caption1
        case .caption2:    uiStyle = .caption2
        default:           uiStyle = .body
        }
        return UIFont.preferredFont(forTextStyle: uiStyle).pointSize
    }
}

private struct ScaledRoundedFont: ViewModifier {
    @Environment(\.noteTextScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: style.platformPointSize * scale,
                             weight: weight ?? .regular,
                             design: .rounded))
    }
}

extension View {
    /// A rounded font for `style`, scaled by the user's chosen text size.
    /// Use in place of `.font(.system(style, design: .rounded))` on content text.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledRoundedFont(style: style, weight: weight))
    }
}

// MARK: - Interaction

extension View {
    /// Strips a `List` row's stock chrome (separator, background, insets) so the
    /// row's own card styling shows through on the app's warm background, with a
    /// small vertical gap between cards.
    func cardRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Gives buttons a subtle press-down response without changing their look.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Theme-driven surfaces

extension AppTheme {
    /// A whisper of the theme's color behind the content: near-white fading to a
    /// faint tint of the theme's start color. The ReadLater equivalent of
    /// QuickNote's indigo-tinted background gradient.
    var appBackground: LinearGradient {
        LinearGradient(
            colors: [Color.white, start.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension Color {
    /// The color as a `#RRGGBB` string, for handing a theme color to embedded
    /// web content (e.g. the offline reader's WKWebView CSS).
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
