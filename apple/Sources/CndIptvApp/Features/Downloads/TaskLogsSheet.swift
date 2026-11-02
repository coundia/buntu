import SwiftUI
import CndCoreBridge

/// Sheet payload (the generated record is not `Identifiable`).
struct LogsTarget: Identifiable {
    let task: DownloadTaskRecord
    var id: Int64 { task.id }
}

enum DownloadLogFormatter {
    static func line(_ log: DownloadLogRecord) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(log.timestamp)).formatted(date: .abbreviated, time: .standard)
        return "[\(time)] \(log.level.uppercased()) \(log.message)"
    }

    static func text(_ logs: [DownloadLogRecord]) -> String {
        logs.map(line).joined(separator: "\n")
    }
}

struct TaskLogsSheet: View {
    let model: DownloadsModel
    let task: DownloadTaskRecord
    var onClose: () -> Void

    @State private var logs: [DownloadLogRecord] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty && !isLoading {
                    ContentUnavailableView("Aucun journal", systemImage: "doc.text", description: Text("Cette tâche n'a rien enregistré pour l'instant."))
                } else {
                    List(logs, id: \.id) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(log.level.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(color(log.level))
                                Text(Date(timeIntervalSince1970: TimeInterval(log.timestamp)).formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(log.message).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle(task.fileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                    Button { Clipboard.copy(DownloadLogFormatter.text(logs)) } label: { Label("Copier", systemImage: "doc.on.doc") }
                        .disabled(logs.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 380)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        logs = await model.logs(for: task)
        isLoading = false
    }

    private func color(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": return .red
        case "warn", "warning": return .orange
        default: return .secondary
        }
    }
}
