import SwiftUI
// SwiftPM builds the Kit as its own module; the Xcode targets compile both folders into one.
#if canImport(CndIptvKit)
import CndIptvKit
#endif

#if os(macOS)
/// A click on the Dock icon brings the window back, whether it is minimized or was closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let windows = sender.windows.filter { $0.canBecomeMain }
        if let minimized = windows.first(where: { $0.isMiniaturized }) {
            minimized.deminiaturize(nil)
            sender.activate(ignoringOtherApps: true)
            return false
        }
        if let hidden = windows.first(where: { !$0.isVisible }) {
            hidden.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return false
        }
        return !flag
    }
}
#endif

@main
struct CndIptvApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var appState = AppState()
    @State private var commandCenter = AppCommandCenter()
    
    var body: some Scene {
        WindowGroup {
            AppShellView(state: appState, commands: commandCenter)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 500)
                #endif
        }
        #if !os(tvOS)
        .commands { KeyboardCommands(center: commandCenter) }
        #endif
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        #endif
    }
}
