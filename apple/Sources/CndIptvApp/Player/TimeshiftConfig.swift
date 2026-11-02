import Foundation

public enum TimeshiftDuration: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case halfHour
    case oneHour
    case twoHours

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: return "Désactivé"
        case .halfHour: return "30 minutes (~1 Go)"
        case .oneHour: return "1 heure (~2 Go) — Recommandé"
        case .twoHours: return "2 heures (~4 Go)"
        }
    }

    public var maxBackBytes: String {
        switch self {
        case .disabled: return "0"
        case .halfHour: return "1024MiB"
        case .oneHour: return "2048MiB"
        case .twoHours: return "4096MiB"
        }
    }

    public var maxBytes: String {
        switch self {
        case .disabled: return "64MiB"
        case .halfHour: return "1536MiB"
        case .oneHour: return "2560MiB"
        case .twoHours: return "4608MiB"
        }
    }

    public var isEnabled: Bool { self != .disabled }
}

public enum TimeshiftCacheManager {
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CndTimeshift", isDirectory: true)
    }

    public static func ensureCacheDirectory() -> String {
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    public static func cleanCacheDirectory() {
        let dir = cacheDirectory
        try? FileManager.default.removeItem(at: dir)
    }
}

