import SwiftUI

/// Honours the system's accessibility display settings for the whole interface (PRD 31 § 6).
/// Materials already turn opaque with "Reduce transparency"; this adds "Reduce motion".
private struct SystemAccessibilityPreferences: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            // No slide, spring or fade-driven motion: state changes just happen.
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

extension View {
    func systemAccessibilityPreferences() -> some View { modifier(SystemAccessibilityPreferences()) }
}

/// A status that is not told by colour alone: with "Differentiate without colour" the dot becomes a
/// symbol with a distinct shape.
struct StatusDot: View {
    enum Kind {
        case ok, slow, failing, broken

        var color: Color {
            switch self {
            case .ok: return .green
            case .slow, .failing: return .orange
            case .broken: return .red
            }
        }

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .slow: return "tortoise.fill"
            case .failing: return "exclamationmark.circle.fill"
            case .broken: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    let kind: Kind
    let description: String

    var body: some View {
        Group {
            if differentiate {
                Image(systemName: kind.symbol).font(.caption2).foregroundStyle(kind.color)
            } else {
                Circle().fill(kind.color).frame(width: 8, height: 8) // lint:ui-ignore decorative status dot
            }
        }
        .help(description)
        .accessibilityLabel(description)
    }
}
