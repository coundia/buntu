import SwiftUI
import Foundation
import CndCoreBridge

/// The French sentences VoiceOver reads (PRD 31 § 7): natural durations, no abbreviations, and never a
/// stream address or a server name.
enum A11yText {
    static let locale = Locale(identifier: "fr_FR")

    private static func spokenFormatter() -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }

    /// « 1 heure, 48 minutes » (seconds only under a minute).
    static func duration(milliseconds: Int64) -> String {
        let seconds = max(0, Int(milliseconds / 1000))
        let formatter = spokenFormatter()
        formatter.allowedUnits = seconds >= 60 ? [.hour, .minute] : [.second]
        let text = formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) secondes"
        // Non-breaking spaces are for layout; a screen reader just needs spaces.
        return text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// « 12 minutes sur 1 heure, 48 minutes »
    static func position(milliseconds: Int64, durationMs: Int64) -> String {
        guard durationMs > 0 else { return duration(milliseconds: milliseconds) }
        return "\(duration(milliseconds: milliseconds)) sur \(duration(milliseconds: durationMs))"
    }

    /// « 40 pour cent »
    static func percent(_ ratio: Double) -> String {
        "\(Int((min(max(ratio, 0), 1) * 100).rounded())) pour cent"
    }

    /// « 7,5 sur 10 »
    static func rating(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return "\(text) sur 10"
    }

    /// « 1,5 fois » for a playback speed.
    static func speed(_ rate: Float) -> String {
        let text = Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return "vitesse \(text)"
    }

    /// « vu à 40 pour cent »
    static func watched(_ ratio: Double) -> String { "vu à \(percent(ratio))" }

    /// Words for the abbreviations that would be spelled out letter by letter.
    static func spoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: "i/s", with: "images par seconde")
            .replacingOccurrences(of: "VOSTFR", with: "version originale sous-titrée")
            .replacingOccurrences(of: "SDH", with: "pour sourds et malentendants")
    }

    /// « Journal, 20:00 – 20:45, en cours »
    static func program(_ program: EpgProgramRecord, isLive: Bool) -> String {
        var text = "\(program.title), \(EpgProgress.timeRange(program))"
        if isLive { text += ", en cours" }
        return text
    }

    /// A programme on a channel: « TF1, chaîne 1, en cours de lecture, favori, en panne. En ce moment : Journal, 20:00 – 20:45 »
    static func channel(
        name: String, number: UInt32?, isPlaying: Bool, isFavorite: Bool, isBroken: Bool,
        nowTitle: String?, timeRange: String?
    ) -> String {
        var parts = [name]
        if let number, number > 0 { parts.append("chaîne \(number)") }
        if isPlaying { parts.append("en cours de lecture") }
        if isFavorite { parts.append("favori") }
        if isBroken { parts.append("en panne") }
        var text = parts.joined(separator: ", ")
        if let nowTitle, !nowTitle.isEmpty {
            text += ". En ce moment : \(nowTitle)"
            if let timeRange, !timeRange.isEmpty { text += ", \(timeRange)" }
        }
        return text
    }
}

extension View {
    /// A tap that is also a real control for VoiceOver, Voice Control and the keyboard: announced as a
    /// button, activated by the screen reader's default action, focusable with Return / Space on a Mac.
    /// Use it instead of a bare `onTapGesture` on anything the user can act on (PRD 31 § 2).
    func accessibleTap(_ label: String? = nil, hint: String? = nil, perform action: @escaping () -> Void) -> some View {
        modifier(AccessibleTap(label: label, hint: hint, action: action))
    }
}

private struct AccessibleTap: ViewModifier {
    let label: String?
    let hint: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        let base = content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
        let labelled = Group {
            if let label { base.accessibilityLabel(label) } else { base }
        }
        let hinted = Group {
            if let hint { labelled.accessibilityHint(hint) } else { labelled }
        }
        #if os(macOS)
        hinted
            .focusable()
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
        #else
        hinted
        #endif
    }
}
