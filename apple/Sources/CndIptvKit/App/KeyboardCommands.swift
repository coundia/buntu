import SwiftUI
import Observation

/// Bridge between the macOS menu bar and the shell: the menu calls these closures, the shell fills them in.
@Observable
@MainActor
public final class AppCommandCenter {
    @ObservationIgnored var addSource: () -> Void = {}
    @ObservationIgnored var importPlaylist: () -> Void = {}
    @ObservationIgnored var importShare: () -> Void = {}
    @ObservationIgnored var refreshAllSources: () -> Void = {}
    @ObservationIgnored var toggleNetworkConsole: () -> Void = {}
    @ObservationIgnored var zap: (Int) -> Void = { _ in }
    @ObservationIgnored var togglePlayPause: () -> Void = {}
    @ObservationIgnored var toggleMute: () -> Void = {}
    @ObservationIgnored var togglePictureInPicture: () -> Void = {}
    @ObservationIgnored var toggleMultiView: () -> Void = {}
    @ObservationIgnored var openAssistant: () -> Void = {}
    @ObservationIgnored var toggleFavorite: () -> Void = {}
    /// Enables the player menu items; set by the shell while something is playing.
    var hasMedia = false
    var isFavorite = false

    public init() {}
}

#if !os(tvOS)
/// macOS menu bar. Plain-letter shortcuts (Space, M, F, arrows) are handled by the player view
/// itself while it has focus: as menu key equivalents they would swallow typing in search fields.
public struct KeyboardCommands: Commands {
    let center: AppCommandCenter

    public init(center: AppCommandCenter) {
        self.center = center
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ajouter une source…") { center.addSource() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Importer un fichier M3U…") { center.importPlaylist() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Importer un partage…") { center.importShare() }
            Divider()
            Button("Actualiser toutes les sources") { center.refreshAllSources() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Console réseau") { center.toggleNetworkConsole() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Lecteur") {
            Button("Assistant de chaînes…") { center.openAssistant() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button(center.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { center.toggleFavorite() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!center.hasMedia)
            Button("Lecture / Pause") { center.togglePlayPause() }
                .disabled(!center.hasMedia)
            Button("Couper / rétablir le son") { center.toggleMute() }
                .disabled(!center.hasMedia)
            Divider()
            Button("Chaîne ou épisode suivant") { center.zap(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!center.hasMedia)
            Button("Chaîne ou épisode précédent") { center.zap(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!center.hasMedia)
            Divider()
            Button("Image dans l'image") { center.togglePictureInPicture() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!center.hasMedia)
            Button("Mosaïque Multi-View") { center.toggleMultiView() }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
#endif
