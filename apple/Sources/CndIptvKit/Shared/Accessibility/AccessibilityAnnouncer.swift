import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Whether the screen reader is running (HUD and countdowns wait for the user then, PRD 31 § 3.4).
enum ScreenReader {
    @MainActor
    static var isRunning: Bool {
        #if os(macOS)
        NSWorkspace.shared.isVoiceOverEnabled
        #else
        UIAccessibility.isVoiceOverRunning
        #endif
    }
}

enum AnnouncementPriority: Sendable {
    case low, normal, high
}

/// Speaks changes of state to VoiceOver. The same text is not repeated within `repeatWindow`, so a
/// reconnection that keeps failing is announced once, not in a loop (PRD 31 § 10).
@MainActor
final class AccessibilityAnnouncer {
    static let shared = AccessibilityAnnouncer()

    /// What actually speaks; replaced in tests.
    var sink: @MainActor (_ text: String, _ priority: AnnouncementPriority) -> Void = AccessibilityAnnouncer.post
    var now: () -> Date = Date.init
    let repeatWindow: TimeInterval

    private var lastSpoken: [String: Date] = [:]

    init(repeatWindow: TimeInterval = 30) {
        self.repeatWindow = repeatWindow
    }

    /// Returns whether the text was handed to the screen reader.
    @discardableResult
    func announce(_ text: String, priority: AnnouncementPriority = .normal, force: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let moment = now()
        if !force, let last = lastSpoken[trimmed], moment.timeIntervalSince(last) < repeatWindow { return false }
        lastSpoken[trimmed] = moment
        if lastSpoken.count > 64 { lastSpoken = lastSpoken.filter { moment.timeIntervalSince($0.value) < repeatWindow } }
        sink(trimmed, priority)
        return true
    }

    private static func post(_ text: String, _ priority: AnnouncementPriority) {
        var spoken = AttributedString(text)
        switch priority {
        case .low: spoken.accessibilitySpeechAnnouncementPriority = .low
        case .normal: break
        case .high: spoken.accessibilitySpeechAnnouncementPriority = .high
        }
        AccessibilityNotification.Announcement(spoken).post()
    }
}
