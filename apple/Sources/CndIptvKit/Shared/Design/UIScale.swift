import SwiftUI
import Observation

/// The "Taille de l'interface" choice (PRD 30). On macOS it is the whole scale; elsewhere it sets a
/// minimum on top of the system's Dynamic Type, never reducing what the user chose there.
enum UIScaleSetting: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Petite"
        case .standard: return "Standard"
        case .large: return "Grande"
        case .extraLarge: return "Très grande"
        }
    }

    /// Scale applied on macOS, where there is no Dynamic Type.
    var macFactor: CGFloat {
        switch self {
        case .small: return 0.9
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// Minimum Dynamic Type size on the other platforms.
    var minimumTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .large
        case .large: return .xLarge
        case .extraLarge: return .xxxLarge
        }
    }

    var smaller: UIScaleSetting? { Self.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil } }
    var larger: UIScaleSetting? { Self.allCases.firstIndex(of: self).flatMap { $0 < Self.allCases.count - 1 ? Self.allCases[$0 + 1] : nil } }
}

/// Combines the app setting and the system's text size into one coefficient, bounded to 0.85...1.6.
enum UIScale {
    static let range: ClosedRange<CGFloat> = 0.85...1.6

    /// What each Dynamic Type size means for layout (`.large`, the system default, is 1.0).
    static func factor(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.85
        case .small: return 0.92
        case .medium: return 0.96
        case .large: return 1.0
        case .xLarge: return 1.15
        case .xxLarge: return 1.25
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.45
        case .accessibility2: return 1.5
        case .accessibility3: return 1.55
        case .accessibility4, .accessibility5: return 1.6
        @unknown default: return 1.0
        }
    }

    static func clamped(_ value: CGFloat) -> CGFloat { min(max(value, range.lowerBound), range.upperBound) }

    /// The coefficient to use. `systemSize` is ignored on macOS.
    static func coefficient(setting: UIScaleSetting, systemSize: DynamicTypeSize, isMac: Bool) -> CGFloat {
        if isMac { return clamped(setting.macFactor) }
        // The setting is a floor: a larger system size always wins.
        return clamped(max(factor(for: systemSize), factor(for: setting.minimumTypeSize)))
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// The user's choice, remembered per device (not synced: a Mac and an iPhone have different needs).
@Observable
@MainActor
final class UIScaleStore {
    static let shared = UIScaleStore()
    static let defaultsKey = "ui.scale"

    var setting: UIScaleSetting {
        didSet { if setting != oldValue { defaults.set(setting.rawValue, forKey: Self.defaultsKey) } }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        setting = defaults.string(forKey: Self.defaultsKey).flatMap(UIScaleSetting.init(rawValue:)) ?? .standard
    }

    func increase() { if let next = setting.larger { setting = next } }
    func decrease() { if let next = setting.smaller { setting = next } }
    func reset() { setting = .standard }
}

private struct UIMetricsKey: EnvironmentKey {
    static let defaultValue = UIMetrics(scale: 1)
}

extension EnvironmentValues {
    var uiMetrics: UIMetrics {
        get { self[UIMetricsKey.self] }
        set { self[UIMetricsKey.self] = newValue }
    }
}

/// Root modifier: computes the coefficient from the setting and the system text size, hands the
/// metrics to every view below, and on non-Mac platforms raises Dynamic Type to the chosen minimum.
private struct UIScaleRoot: ViewModifier {
    @Bindable var store: UIScaleStore
    @Environment(\.dynamicTypeSize) private var systemSize

    func body(content: Content) -> some View {
        let coefficient = UIScale.coefficient(setting: store.setting, systemSize: systemSize, isMac: UIScale.isMac)
        #if os(macOS)
        content.environment(\.uiMetrics, UIMetrics(scale: coefficient))
        #else
        content
            .dynamicTypeSize(max(systemSize, store.setting.minimumTypeSize)...)
            .environment(\.uiMetrics, UIMetrics(scale: coefficient))
        #endif
    }
}

extension View {
    /// Applies the interface scale to this view and everything below it.
    @MainActor
    func uiScaleRoot(_ store: UIScaleStore? = nil) -> some View {
        modifier(UIScaleRoot(store: store ?? .shared))
    }
}
