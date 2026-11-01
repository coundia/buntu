import SwiftUI
import CndCoreBridge

public struct ContentView: View {
    @Bindable var state: AppState
    @State private var showingAddSourceSheet = false
    @State private var newSourceName = ""
    @State private var newSourceUrl = ""
    @State private var selectedItem: IptvItemRecord?
    
    public init(state: AppState) {
        self.state = state
    }
    
    public var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .searchable(text: $state.searchQuery, prompt: "Search channels, movies, series (FTS5)...")
        .sheet(isPresented: $showingAddSourceSheet) {
            addSourceSheet
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingAddSourceSheet = true }) {
                    Label("Add Source", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { state.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
    
    // MARK: - Sidebar
    private var sidebarView: some View {
        List {
            Section("Moteur Natif Rust") {
                HStack {
                    Circle()
                        .fill(state.engine != nil ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("CndCore Engine")
                        .font(.headline)
                    Spacer()
                    if let version = state.engine?.version() {
                        Text(version)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                
                if let stats = state.stats {
                    VStack(alignment: .leading, spacing: 4) {
                        statRow(label: "SQLite Mode", value: "WAL + FTS5")
                        statRow(label: "Sources actives", value: "\(stats.totalSources)")
                        statRow(label: "Chaînes Live", value: "\(stats.totalLiveChannels)")
                        statRow(label: "Films VOD", value: "\(stats.totalMovies)")
                        statRow(label: "Séries", value: "\(stats.totalSeries)")
                        statRow(label: "Favoris", value: "\(stats.totalFavorites)")
                        statRow(label: "Taille DB", value: "\(stats.dbSizeBytes / 1024) KB")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            
            Section("Catalogue") {
                categoryRow(id: "live", title: "Live TV", icon: "tv")
                categoryRow(id: "movie", title: "Films", icon: "film")
                categoryRow(id: "episode", title: "Séries", icon: "play.tv")
            }
            
            Section("Playlists & Sources (\(state.sources.count))") {
                if state.sources.isEmpty {
                    Text("Aucune source IPTV")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button("Ajouter source démo") {
                        state.addSampleSource()
                    }
                    .font(.caption)
                } else {
                    ForEach(state.sources, id: \.id) { src in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(src.sourceType.uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("CND IPTV")
    }
    
    // MARK: - Detail View
    private var detailView: some View {
        VStack(spacing: 0) {
            if let error = state.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button("OK") { state.errorMessage = nil }
                }
                .padding()
                .background(Color.yellow.opacity(0.15))
            }
            
            if state.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Aucun élément")
                        .font(.headline)
                    Text("Ajoutez une source IPTV ou lancez une recherche.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button("Ajouter une source M3U / Xtream") {
                        showingAddSourceSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.items, id: \.id, selection: $selectedItem) { item in
                    itemRow(item: item)
                }
            }
        }
        .navigationTitle(state.selectedCategory.capitalized)
    }
    
    // MARK: - Item Row
    private func itemRow(item: IptvItemRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == "live" ? "tv" : "film")
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name)
                        .font(.body)
                        .fontWeight(.semibold)
                    if let rating = item.imdbRating, rating > 0 {
                        Text(String(format: "★ %.1f", rating))
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                
                HStack(spacing: 8) {
                    if let grp = item.groupTitle, !grp.isEmpty {
                        Text(grp)
                    }
                    Text("•")
                    Text(item.host)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { state.toggleFavorite(item: item) }) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Add Source Sheet
    private var addSourceSheet: some View {
        NavigationStack {
            Form {
                Section("Informations de la source") {
                    TextField("Nom de la playlist (ex: Mon IPTV)", text: $newSourceName)
                    TextField("URL du fichier M3U / M3U8", text: $newSourceUrl)
                }
            }
            .navigationTitle("Nouvelle Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showingAddSourceSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        if !newSourceName.isEmpty && !newSourceUrl.isEmpty {
                            Task {
                                _ = try? state.engine?.addSource(
                                    name: newSourceName,
                                    sourceType: "m3u",
                                    url: newSourceUrl,
                                    server: nil,
                                    username: nil,
                                    passwordRef: nil
                                )
                                state.refresh()
                            }
                            showingAddSourceSheet = false
                            newSourceName = ""
                            newSourceUrl = ""
                        }
                    }
                    .disabled(newSourceName.isEmpty || newSourceUrl.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 250)
        #endif
    }
    
    private func categoryRow(id: String, title: String, icon: String) -> some View {
        Button(action: {
            state.selectedCategory = id
            state.performSearch()
        }) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if state.selectedCategory == id {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(state.selectedCategory == id ? Color.accentColor : Color.primary)
    }
    
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
    }
}

