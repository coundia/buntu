import SwiftUI
import UniformTypeIdentifiers
import CndCoreBridge

enum SourceFilter: String, CaseIterable, Identifiable {
    case all
    case m3u
    case xtream

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Toutes"
        case .m3u: return "M3U"
        case .xtream: return "Xtream"
        }
    }

    static func apply(_ filter: SourceFilter, query: String, to sources: [IptvSourceRecord]) -> [IptvSourceRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources.filter { source in
            switch filter {
            case .all: break
            case .m3u: if source.sourceType == "xtream" { return false }
            case .xtream: if source.sourceType != "xtream" { return false }
            }
            guard !needle.isEmpty else { return true }
            return source.name.localizedCaseInsensitiveContains(needle)
                || (source.url ?? "").localizedCaseInsensitiveContains(needle)
                || (source.server ?? "").localizedCaseInsensitiveContains(needle)
        }
    }
}

private enum SourceEditorTarget: Identifiable {
    case new
    case edit(IptvSourceRecord)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let source): return "edit-\(source.id)"
        }
    }
}

struct SourcesListView: View {
    let engine: CndEngine
    let sources: [IptvSourceRecord]
    @Bindable var model: SourcesModel

    @State private var filter: SourceFilter = .all
    @State private var query = ""
    @State private var editor: SourceEditorTarget?
    @State private var pendingDelete: IptvSourceRecord?
    @State private var showingImporter = false

    private var visibleSources: [IptvSourceRecord] {
        SourceFilter.apply(filter, query: query, to: sources)
    }

    private static let playlistTypes: [UTType] =
        ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) } + [.plainText]

    var body: some View {
        VStack(spacing: 0) {
            if sources.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Sources")
        .searchable(text: $query, prompt: "Rechercher une source")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.syncAll(sources) }
                } label: {
                    Label("Tout synchroniser", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sources.isEmpty || model.isSyncingAll)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Ajouter une source…", systemImage: "plus") { editor = .new }
                    Button("Importer un fichier M3U…", systemImage: "doc.badge.plus") { showingImporter = true }
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
            }
        }
        .onAppear { consumePendingAction() }
        .onChange(of: model.pendingAction) { _, _ in consumePendingAction() }
        .sheet(item: $editor) { target in
            SourceFormSheet(
                engine: engine,
                keychain: model.keychain,
                editing: editingRecord(target),
                onSaved: { id in
                    let isNew = editingRecord(target) == nil
                    editor = nil
                    model.onChange()
                    if isNew { Task { await model.syncSource(id: id) } }
                },
                onCancel: { editor = nil }
            )
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.playlistTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await model.importM3u(from: url) } }
        }
        .confirmationDialog(
            "Supprimer cette source ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { source in
            Button("Supprimer « \(source.name) »", role: .destructive) { model.delete(source) }
        } message: { source in
            Text("Les \(source.itemCount) éléments importés depuis cette source seront retirés du catalogue.")
        }
    }

    private func consumePendingAction() {
        guard let action = model.pendingAction else { return }
        model.pendingAction = nil
        switch action {
        case .addSource: editor = .new
        case .importPlaylist: showingImporter = true
        }
    }

    private func editingRecord(_ target: SourceEditorTarget) -> IptvSourceRecord? {
        if case .edit(let source) = target { return source }
        return nil
    }

    // MARK: Content

    private var list: some View {
        List {
            Picker("Type", selection: $filter) {
                ForEach(SourceFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowSeparator(.hidden)

            ForEach(visibleSources, id: \.id) { source in
                SourceRowView(source: source, state: model.state(for: source), onSync: {
                    Task { await model.sync(source) }
                })
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Synchroniser", systemImage: "arrow.clockwise") { Task { await model.sync(source) } }
                    Button("Modifier…", systemImage: "pencil") { editor = .edit(source) }
                    Divider()
                    Button("Supprimer…", systemImage: "trash", role: .destructive) { pendingDelete = source }
                }
                #if os(iOS)
                .swipeActions(edge: .trailing) {
                    Button("Supprimer", systemImage: "trash", role: .destructive) { pendingDelete = source }
                    Button("Modifier", systemImage: "pencil") { editor = .edit(source) }.tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button("Synchroniser", systemImage: "arrow.clockwise") { Task { await model.sync(source) } }
                        .tint(.green)
                }
                #endif
            }
            if visibleSources.isEmpty {
                Text("Aucune source ne correspond.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Aucune source IPTV", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("Ajoutez une playlist M3U, un compte Xtream Codes, ou déposez un fichier .m3u sur la fenêtre.")
        } actions: {
            Button("Ajouter une source") { editor = .new }
                .buttonStyle(.borderedProminent)
            Button("Importer un fichier M3U…") { showingImporter = true }
        }
    }
}

struct SourcesBannerView: View {
    let banner: SourcesBanner
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .yellow : .green)
            Text(banner.text).font(.callout).lineLimit(3)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer")
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SourceRowView: View {
    let source: IptvSourceRecord
    let state: SyncState
    var onSync: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.sourceType == "xtream" ? "server.rack" : "list.bullet.rectangle")
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(source.sourceType == "xtream" ? "XTREAM" : "M3U")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                statusLine
            }
            Spacer()
            if case .syncing = state {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onSync) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Synchroniser \(source.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private var detailLine: String {
        var parts = ["\(source.itemCount) éléments"]
        if source.sourceType == "xtream" {
            if let status = source.accountStatus, !status.isEmpty { parts.append(status.capitalized) }
            if let exp = source.expDate {
                parts.append("expire le " + Date(timeIntervalSince1970: TimeInterval(exp)).formatted(date: .abbreviated, time: .omitted))
            }
        }
        if source.updatedAt > 0 {
            parts.append("maj " + Date(timeIntervalSince1970: TimeInterval(source.updatedAt)).formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .syncing:
            Text("Synchronisation en cours…").font(.caption).foregroundStyle(.blue)
        case .done(let report):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(SyncSummaryFormatter.text(report.summary))
                if report.epgPending {
                    Text("· guide…")
                } else if let epg = report.epgPrograms, epg > 0 {
                    Text("· \(epg) programmes")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }
}
