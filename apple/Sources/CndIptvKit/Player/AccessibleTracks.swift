import Foundation
import MediaAccessibility

/// What the user asked the system for (Réglages Système > Accessibilité): subtitles for the deaf and
/// hard of hearing, and audio description (PRD 31 § 5).
struct AccessibleTrackPreferences: Equatable, Sendable {
    var wantsHearingImpairedSubtitles = false
    var wantsAudioDescription = false
    /// Preferred languages, most wanted first (`fr-FR`, `en`…).
    var languages: [String] = []

    /// Read from MediaAccessibility; nothing is requested unless the user turned it on.
    static func current() -> AccessibleTrackPreferences {
        var prefs = AccessibleTrackPreferences()
        prefs.languages = Locale.preferredLanguages
        let captionsAlwaysOn = MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
        let captionCharacteristics = characteristics(MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(.user))
        prefs.wantsHearingImpairedSubtitles = captionsAlwaysOn
            && (captionCharacteristics.contains("public.accessibility.describes-music-and-sound")
                || captionCharacteristics.contains("public.accessibility.transcribes-spoken-dialog"))
        prefs.wantsAudioDescription = characteristics(MAAudibleMediaCopyPreferredCharacteristics())
            .contains("public.accessibility.describes-video")
        return prefs
    }

    private static func characteristics(_ array: Unmanaged<CFArray>?) -> Set<String> {
        guard let array else { return [] }
        return Set((array.takeRetainedValue() as? [String]) ?? [])
    }
}

/// Picks the accessible tracks the system settings call for. AVPlayer applies those settings by
/// itself; this serves the engines that do not (mpv).
enum AccessibleTrackPolicy {
    /// The subtitle track to turn on for « SDH », or `nil` to leave the current choice alone.
    static func subtitle(in tracks: [MediaTrack], preferences: AccessibleTrackPreferences) -> String? {
        guard preferences.wantsHearingImpairedSubtitles else { return nil }
        return pick(tracks.filter(\.isHearingImpaired), languages: preferences.languages)
    }

    /// The audio track to turn on for audio description.
    static func audio(in tracks: [MediaTrack], preferences: AccessibleTrackPreferences) -> String? {
        guard preferences.wantsAudioDescription else { return nil }
        return pick(tracks.filter(\.isAudioDescription), languages: preferences.languages)
    }

    private static func pick(_ candidates: [MediaTrack], languages: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        for language in languages {
            let code = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
            if let match = candidates.first(where: { languageCode($0.language) == code }) {
                return match.isSelected ? nil : match.id
            }
        }
        // No language match: the first accessible track still serves the user better than none.
        return candidates.contains(where: \.isSelected) ? nil : candidates.first?.id
    }

    /// « fra », « fre », « fr-FR » all mean French; mpv reports ISO 639-2 codes.
    static func languageCode(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        let two: [String: String] = ["fra": "fr", "fre": "fr", "eng": "en", "spa": "es", "deu": "de", "ger": "de", "ita": "it", "por": "pt", "ara": "ar"]
        let base = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        return two[base] ?? base
    }
}
