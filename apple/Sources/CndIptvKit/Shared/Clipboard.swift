import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #elseif os(tvOS)
        // tvOS has no general UIPasteboard
        #endif
    }
}
