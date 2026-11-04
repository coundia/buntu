import SwiftUI

/// Sizes of the interface, in one place (PRD 30). Each value is a base size times the scale,
/// rounded to a whole point; views read them from the environment (`@Environment(\.uiMetrics)`)
/// instead of writing numbers.
struct UIMetrics: Equatable, Sendable {
    let scale: CGFloat

    init(scale: CGFloat) { self.scale = UIScale.clamped(scale) }

    func value(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }

    // MARK: Icons

    var iconXS: CGFloat { value(10) }
    var iconS: CGFloat { value(14) }
    var iconM: CGFloat { value(18) }
    var iconL: CGFloat { value(22) }
    var iconXL: CGFloat { value(44) }

    // MARK: Logos and posters (2:3)

    var channelLogo: CGFloat { value(44) }
    var posterThumbWidth: CGFloat { value(44) }
    var posterCompactWidth: CGFloat { value(96) }
    var posterDetailWidth: CGFloat { value(150) }
    func posterHeight(forWidth width: CGFloat) -> CGFloat { (width * 1.5).rounded() }

    // MARK: Cards and grids

    var channelCardMinWidth: CGFloat { value(240) }
    var channelCardMaxWidth: CGFloat { value(340) }
    var channelCardMinHeight: CGFloat { value(92) }
    var shelfChannelCardWidth: CGFloat { value(280) }
    var posterGridMinWidth: CGFloat { value(155) }
    var posterGridMaxWidth: CGFloat { value(210) }
    var shelfPosterWidth: CGFloat { value(150) }
    var downloadCardMinWidth: CGFloat { value(420) }

    // MARK: Columns

    var sidebarMinWidth: CGFloat { value(180) }
    var sidebarIdealWidth: CGFloat { value(210) }
    var sidebarMaxWidth: CGFloat { value(280) }
    var categoryColumnNarrow: CGFloat { value(190) }
    var categoryColumnWide: CGFloat { value(250) }

    // MARK: Spacing

    var spacingS: CGFloat { value(8) }
    var spacingM: CGFloat { value(12) }
    var spacingL: CGFloat { value(16) }

    // MARK: Hit target

    /// Smallest comfortable size of a control: 44 pt for a finger, 28 pt for a pointer, a larger focus
    /// area on Apple TV, 60 pt on Vision Pro. It also grows with the scale.
    var minHitTarget: CGFloat {
        #if os(iOS)
        return value(44)
        #elseif os(tvOS)
        return value(66)
        #elseif os(visionOS)
        return value(60)
        #else
        return value(28)
        #endif
    }

    // MARK: Text

    /// A text style at the interface scale. On macOS (no Dynamic Type) the size is computed; elsewhere
    /// the system style already follows the user's text size.
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        #if os(macOS)
        let base: CGFloat
        switch style {
        case .largeTitle: base = 26
        case .title: base = 22
        case .title2: base = 17
        case .title3: base = 15
        case .headline: base = 13
        case .subheadline: base = 11
        case .callout: base = 12
        case .footnote: base = 10
        case .caption: base = 10
        case .caption2: base = 10
        default: base = 13
        }
        let size = (base * scale).rounded()
        return .system(size: max(size, Self.minimumTextSize), weight: weight ?? (style == .headline ? .semibold : .regular))
        #else
        return weight.map { .system(style).weight($0) } ?? .system(style)
        #endif
    }

    /// Nothing informative is set below this at the default scale (PRD 30 § 6).
    static var minimumTextSize: CGFloat { 10 }
}

/// Seuils de largeur communs. They grow with the scale: at a large interface size, the category
/// column gives way to chips earlier.
struct Breakpoints: Equatable, Sendable {
    let scale: CGFloat

    /// Width from which a permanent column of categories fits (macOS keeps it in small windows).
    var categoryColumn: CGFloat {
        #if os(macOS)
        (520 * scale).rounded()
        #else
        (900 * scale).rounded()
        #endif
    }

    /// Width from which the category column is the wide one.
    var categoryColumnWide: CGFloat { (900 * scale).rounded() }
}

extension UIMetrics {
    var breakpoints: Breakpoints { Breakpoints(scale: scale) }
}

extension View {
    /// Fixed-looking frame whose size follows the interface scale.
    func tokenFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        frame(width: width, height: height, alignment: alignment)
    }

    /// Makes sure a small icon button still has a comfortable tappable area.
    func minHitTarget(_ metrics: UIMetrics) -> some View {
        frame(minWidth: metrics.minHitTarget, minHeight: metrics.minHitTarget)
            .contentShape(Rectangle())
    }
}
