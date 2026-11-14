import Foundation
import Observation

/// Supported UI languages for Buntu Apple apps.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case fr
    case en

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fr: return "Français"
        case .en: return "English"
        }
    }
}

/// Observable store holding the active UI language, persisted in `UserDefaults`.
@Observable
@MainActor
public final class AppLanguageStore {
    public static let shared = AppLanguageStore()
    public static let defaultsKey = "buntu.appLanguage"

    public var language: AppLanguage {
        didSet {
            if language != oldValue {
                defaults.set(language.rawValue, forKey: Self.defaultsKey)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .fr
    }

    /// Returns the localized string for `key`, falling back to French then the key itself.
    public func t(_ key: String) -> String {
        switch language {
        case .fr:
            return AppStringsFR.strings[key] ?? key
        case .en:
            return AppStringsEN.strings[key] ?? AppStringsFR.strings[key] ?? key
        }
    }

    /// Returns a formatted localized string for `key`.
    public func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}
