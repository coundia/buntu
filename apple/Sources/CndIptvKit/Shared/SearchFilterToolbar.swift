import Foundation
import Observation
import SwiftUI
import CndCoreBridge

extension SortField {
    var displayName: String {
        switch self {
        case .name: return "Nom"
        case .group: return "Groupe"
        case .host: return "Serveur"
        case .rating: return "Note"
        case .recentlyAdded: return "Ajout récent"
        case .channelNumber: return "Numéro"
        case .custom: return "Personnalisé"
        }
    }
}

/// Search + filter state shared by the catalog screens. `text` follows the keyboard; `query` only
/// changes once typing has paused for `debounce`, so a burst of keystrokes triggers one query.
@Observable
@MainActor
final class SearchFilterState {
    var text = "" { didSet { if text != oldValue { scheduleDebounce() } } }
    private(set) var query = ""
    var group: String?
    var host: String?
    var showBroken = false
    var sort: SortField
    var ascending = true

    @ObservationIgnored let debounce: Duration
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(sort: SortField = .name, debounce: Duration = .milliseconds(120)) {
        self.sort = sort
        self.debounce = debounce
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.query = self.text
        }
    }

    /// Skips the debounce, e.g. when the user submits the search.
    func commit() {
        debounceTask?.cancel()
        query = text
    }

    func resetFilters() {
        group = nil
        host = nil
        showBroken = false
    }

    var hasActiveFilter: Bool { group != nil || host != nil || showBroken }

    /// Changes whenever the catalog query must be re-run (used as a `.task(id:)` key).
    var signature: String {
        "\(query)|\(group ?? "")|\(host ?? "")|\(sort)|\(ascending)|\(showBroken)"
    }
}

struct SearchFilterToolbarModifier: ViewModifier {
    @Bindable var state: SearchFilterState
    var groups: [FacetCount]
    var hosts: [FacetCount]
    var sortOptions: [SortField]
    var prompt: String

    /// On iPhone the field stays visible under the title instead of hiding until the list is pulled down.
    @ViewBuilder
    private func searchField(_ content: Content) -> some View {
        #if os(iOS)
        content.searchable(text: $state.text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        content.searchable(text: $state.text, prompt: Text(prompt))
        #endif
    }

    func body(content: Content) -> some View {
        searchField(content)
            .onSubmit(of: .search) { state.commit() }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Trier par", selection: $state.sort) {
                            ForEach(sortOptions, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("Ordre", selection: $state.ascending) {
                            Label("Croissant", systemImage: "arrow.up").tag(true)
                            Label("Décroissant", systemImage: "arrow.down").tag(false)
                        }
                        if !groups.isEmpty {
                            Picker("Groupe", selection: $state.group) {
                                Text("Tous les groupes").tag(String?.none)
                                ForEach(groups, id: \.value) { Text("\($0.value) (\($0.count))").tag(String?.some($0.value)) }
                            }
                        }
                        if hosts.count > 1 {
                            Picker("Serveur", selection: $state.host) {
                                Text("Tous les serveurs").tag(String?.none)
                                ForEach(hosts, id: \.value) { Text("\($0.value) (\($0.count))").tag(String?.some($0.value)) }
                            }
                        }
                        Divider()
                        Toggle(isOn: $state.showBroken) {
                            Label("Afficher les contenus en panne", systemImage: "exclamationmark.triangle")
                        }
                        if state.hasActiveFilter {
                            Divider()
                            Button("Réinitialiser les filtres", systemImage: "xmark.circle") { state.resetFilters() }
                        }
                    } label: {
                        Label("Filtres", systemImage: state.hasActiveFilter
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
    }
}

extension View {
    func searchFilterToolbar(
        state: SearchFilterState,
        groups: [FacetCount] = [],
        hosts: [FacetCount] = [],
        sortOptions: [SortField] = [.name, .group, .host],
        prompt: String = "Rechercher"
    ) -> some View {
        modifier(SearchFilterToolbarModifier(
            state: state, groups: groups, hosts: hosts, sortOptions: sortOptions, prompt: prompt
        ))
    }
}
