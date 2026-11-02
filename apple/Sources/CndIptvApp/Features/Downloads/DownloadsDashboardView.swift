import SwiftUI
import CndCoreBridge

struct DownloadsDashboardView: View {
    @Bindable var model: DownloadsModel
    let directory: DownloadDirectoryManager
    let onPlay: (DownloadTaskRecord) -> Void

    @State private var showingAdd = false
    @State private var logsTarget: LogsTarget?
    @State private var pendingRemoval: DownloadTaskRecord?

    /// Grid from this width, single column list below.
    static let wideLayoutThreshold: CGFloat = 900

    var body: some View {
        GeometryReader { geo in
            content(wide: geo.size.width >= Self.wideLayoutThreshold)
        }
        .navigationTitle("Téléchargements")
        .searchable(text: $model.query, prompt: "Rechercher un téléchargement")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Filtre", selection: $model.stateFilter) {
                    ForEach(DownloadStateFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: { Label("Ajouter des liens", systemImage: "plus") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { statsBar }
        .sheet(isPresented: $showingAdd) {
            AddUrlsSheet(model: model, directory: directory) { showingAdd = false }
        }
        .sheet(item: $logsTarget) { target in
            TaskLogsSheet(model: model, task: target.task) { logsTarget = nil }
        }
        .confirmationDialog(
            "Supprimer ce téléchargement ?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { task in
            Button("Supprimer la tâche") { Task { await model.remove(task, deleteFile: false) } }
            Button("Supprimer la tâche et le fichier", role: .destructive) { Task { await model.remove(task, deleteFile: true) } }
        } message: { task in
            Text(task.fileName)
        }
        .task {
            await model.refresh()
            if model.hasActive { model.ensurePolling() }
        }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        if model.tasks.isEmpty {
            ContentUnavailableView {
                Label("Aucun téléchargement", systemImage: "arrow.down.circle")
            } description: {
                Text("Téléchargez un film ou un épisode, ou collez des liens HTTP(S).")
            } actions: {
                Button("Ajouter des liens") { showingAdd = true }.buttonStyle(.borderedProminent)
            }
        } else if model.visibleTasks.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            ScrollView {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding([.horizontal, .top])
                }
                if wide {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12)], spacing: 12) { cards }.padding()
                } else {
                    LazyVStack(spacing: 12) { cards }.padding()
                }
            }
        }
    }

    private var cards: some View {
        ForEach(model.visibleTasks, id: \.id) { task in
            DownloadTaskCard(task: task, actions: DownloadTaskActions(
                start: { Task { await model.start(task) } },
                pause: { Task { await model.pause(task) } },
                retry: { Task { await model.retry(task) } },
                play: { onPlay(task) },
                showLogs: { logsTarget = LogsTarget(task: task) },
                remove: { pendingRemoval = task }
            ))
        }
    }

    // MARK: Bottom bar

    private var statsBar: some View {
        let stats = model.stats
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { statsText(stats); Spacer(); bulkButtons(stats) }
            VStack(alignment: .leading, spacing: 6) { statsText(stats); bulkButtons(stats) }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func statsText(_ stats: DownloadStats) -> some View {
        HStack(spacing: 6) {
            Text("Total \(stats.total)")
            Text("•"); Text("En cours \(stats.running)")
            Text("•"); Text("En file \(stats.queued)")
            Text("•"); Text("Erreurs \(stats.errors)").foregroundStyle(stats.errors > 0 ? Color.red : Color.secondary)
            Text("•"); Text(DownloadFormat.speed(stats.speedBps)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func bulkButtons(_ stats: DownloadStats) -> some View {
        HStack(spacing: 10) {
            Button("Tout démarrer") { Task { await model.startAll() } }
                .disabled(stats.paused + stats.queued == 0)
            Button("Tout mettre en pause") { Task { await model.pauseAll() } }
                .disabled(stats.running + stats.queued == 0)
            Button("Relancer les erreurs") { Task { await model.retryErrors() } }
                .disabled(stats.errors == 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
