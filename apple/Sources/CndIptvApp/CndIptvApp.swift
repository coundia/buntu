import SwiftUI
// SwiftPM builds the Kit as its own module; the Xcode targets compile both folders into one.
#if canImport(CndIptvKit)
import CndIptvKit
#endif

@main
struct CndIptvApp: App {
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
