import SwiftUI

/// The keyboard shortcuts of the app, listed in Aide > Raccourcis clavier (PRD 31 § 4.1). Kept in one
/// place so the list cannot drift from what the menus and the player do.
enum KeyboardShortcutsCatalog {
    struct Entry: Identifiable, Equatable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct Group: Identifiable, Equatable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Général", entries: [
            Entry(keys: "⌘N", action: "Ajouter une source"),
            Entry(keys: "⌘O", action: "Importer un fichier M3U"),
            Entry(keys: "⌘R", action: "Actualiser toutes les sources"),
            Entry(keys: "⌘K", action: "Assistant de chaînes"),
            Entry(keys: "⇧⌘C", action: "Console réseau"),
            Entry(keys: "⌘+  ⌘-  ⌘0", action: "Agrandir, réduire, rétablir la taille de l'interface"),
            Entry(keys: "Tab  ⇧Tab", action: "Passer au contrôle suivant ou précédent"),
            Entry(keys: "Entrée  Espace", action: "Activer le contrôle sélectionné (cartes, puces)"),
            Entry(keys: "Échap", action: "Fermer une feuille ou le lecteur agrandi"),
        ]),
        Group(title: "Lecteur", entries: [
            Entry(keys: "Espace", action: "Lecture / Pause"),
            Entry(keys: "F", action: "Plein écran"),
            Entry(keys: "M", action: "Couper ou rétablir le son"),
            Entry(keys: "← →", action: "Reculer ou avancer de quelques secondes"),
            Entry(keys: "↑ ↓", action: "Chaîne précédente ou suivante (direct)"),
            Entry(keys: "⌘↑  ⌘↓", action: "Chaîne ou épisode précédent, suivant"),
            Entry(keys: "⇧⌘S", action: "Ajouter aux favoris ou retirer"),
            Entry(keys: "⌥⌘P", action: "Image dans l'image"),
            Entry(keys: "⌥⌘M", action: "Mosaïque Multi-View"),
        ]),
        Group(title: "Fenêtre (Mac)", entries: [
            Entry(keys: "⌥⌘T", action: "Toujours au premier plan"),
            Entry(keys: "⌥⌘O", action: "Lecteur compact"),
        ]),
    ]
}

struct KeyboardShortcutsSheet: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(KeyboardShortcutsCatalog.groups) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            LabeledContent(entry.action) {
                                Text(entry.keys).font(.body.monospaced())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Raccourcis clavier")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}
