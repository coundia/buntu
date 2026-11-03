import Foundation

public enum DialogueBoostLevel: String, CaseIterable, Sendable, Identifiable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Désactivé"
        case .low: return "Faible (+3 dB)"
        case .medium: return "Moyen (+6 dB)"
        case .high: return "Fort (+9 dB)"
        }
    }

    public var gainDb: Int {
        switch self {
        case .off: return 0
        case .low: return 3
        case .medium: return 6
        case .high: return 9
        }
    }
}

public struct AudioEnhancementConfig: Equatable, Sendable {
    public var dialogueBoost: DialogueBoostLevel
    public var nightMode: Bool

    public init(dialogueBoost: DialogueBoostLevel = .off, nightMode: Bool = false) {
        self.dialogueBoost = dialogueBoost
        self.nightMode = nightMode
    }

    /// Pure function computing the libmpv audio filter (`af`) string.
    public var mpvFilterString: String {
        var filters: [String] = []

        if dialogueBoost != .off {
            let gain = dialogueBoost.gainDb
            filters.append("lavfi=[highpass=f=100,equalizer=f=2500:t=q:w=1.2:g=\(gain),dynaudnorm=f=200:g=15:p=0.9]")
        }

        if nightMode {
            filters.append("lavfi=[acompressor=threshold=-24dB:ratio=6:attack=5:release=200,loudnorm=I=-23:TP=-2]")
        }

        return filters.joined(separator: ",")
    }

    public var isActive: Bool {
        dialogueBoost != .off || nightMode
    }
}
