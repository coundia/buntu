import Foundation
import CndCoreBridge

/// What a prompt-search result says about itself: its title, the action it leads to, and the sentence
/// a screen reader speaks (PRD 33 and PRD 31).
enum SearchHitText {
    static func title(_ hit: SearchHit) -> String {
        if let program = hit.program { return program.title }
        if let series = hit.series { return series.title }
        return hit.item?.nameClean.isEmpty == false && hit.kind == .movie ? (hit.item?.nameClean ?? "") : (hit.item?.name ?? "")
    }

    /// The verb of the row: what a tap does.
    static func actionLabel(_ hit: SearchHit, now: Date = Date()) -> String {
        switch hit.kind {
        case .live: return "Lire la chaîne"
        case .program: return isOnAir(hit, now: now) ? "Lire la chaîne" : "Voir le guide de la chaîne"
        case .movie: return "Ouvrir la fiche du film"
        case .series: return "Ouvrir la série"
        }
    }

    static func actionSymbol(_ hit: SearchHit, now: Date = Date()) -> String {
        switch hit.kind {
        case .live: return "play.fill"
        case .program: return isOnAir(hit, now: now) ? "play.fill" : "calendar"
        case .movie: return "film"
        case .series: return "play.tv"
        }
    }

    static func isOnAir(_ hit: SearchHit, now: Date) -> Bool {
        guard let program = hit.program else { return false }
        let t = Int64(now.timeIntervalSince1970)
        return t >= program.startTs && t < program.endTs
    }

    /// « Ligue 1 : PSG - Marseille. Aujourd'hui 21:00 · beIN Sports 1. Proposé par l'assistant »
    static func accessibilityLabel(_ hit: SearchHit) -> String {
        var parts = [title(hit)]
        if !hit.reason.isEmpty { parts.append(hit.reason) }
        if hit.fromAssistant { parts.append("Proposé par l'assistant") }
        return parts.joined(separator: ". ")
    }
}
