import SwiftUI
import CndCoreBridge
#if os(macOS)
import AppKit
#endif

struct DownloadTaskActions {
    var start: () -> Void
    var pause: () -> Void
    var retry: () -> Void
    var play: () -> Void
    var showLogs: () -> Void
    var remove: () -> Void
}

/// One bar per parallel segment, each filled by its own progress: the live signature of the
/// multi-segment engine.
struct SegmentedProgressBar: View {
    let parts: [DownloadPartRecord]
    let fraction: Double?
    var height: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let track = Color.secondary.opacity(0.2)
            if parts.count > 1 {
                for bar in SegmentGeometry.bars(parts: parts, width: size.width) {
                    let rect = CGRect(x: bar.x, y: 0, width: bar.width, height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(track))
                    let filled = CGRect(x: bar.x, y: 0, width: bar.width * bar.fill, height: size.height)
                    context.fill(Path(roundedRect: filled, cornerRadius: 2), with: .color(bar.fill >= 1 ? .green : .accentColor))
                }
            } else {
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(track))
                let filled = CGRect(x: 0, y: 0, width: size.width * (fraction ?? 0), height: size.height)
                context.fill(Path(roundedRect: filled, cornerRadius: 3), with: .color(.accentColor))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progression")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) %" } ?? "inconnue")
    }
}

struct DownloadTaskCard: View {
    let task: DownloadTaskRecord
    let actions: DownloadTaskActions

    private var fraction: Double? { DownloadFormat.percent(task) }
    private var isRunning: Bool { task.state == "running" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(task.fileName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(stateLabel).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: Capsule())
                    .foregroundStyle(tint)
            }

            SegmentedProgressBar(parts: task.parts, fraction: fraction)

            HStack(spacing: 10) {
                Text(fraction.map { String(format: "%.0f %%", $0 * 100) } ?? "—").font(.caption.monospacedDigit().weight(.semibold))
                Text(sizeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if isRunning {
                    Text(DownloadFormat.speed(task.speedBps)).font(.caption.monospacedDigit())
                    if task.etaSeconds > 0 {
                        Text("reste " + DownloadFormat.eta(seconds: task.etaSeconds)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if task.parts.count > 1 {
                    Text("\(task.parts.count) segments").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) { buttons }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu { menu }
    }

    // MARK: Pieces

    private var icon: String {
        switch task.state {
        case "completed": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "paused": return "pause.circle.fill"
        case "queued": return "clock.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch task.state {
        case "completed": return .green
        case "error": return .red
        case "paused": return .orange
        case "queued": return .secondary
        default: return .accentColor
        }
    }

    private var stateLabel: String {
        switch task.state {
        case "completed": return "Terminé"
        case "error": return "Erreur"
        case "paused": return "En pause"
        case "queued": return "En file"
        case "running": return "En cours"
        default: return task.state
        }
    }

    private var sizeLabel: String {
        task.totalBytes > 0
            ? "\(DownloadFormat.bytes(task.downloadedBytes)) / \(DownloadFormat.bytes(task.totalBytes))"
            : DownloadFormat.bytes(task.downloadedBytes)
    }

    @ViewBuilder
    private var buttons: some View {
        switch task.state {
        case "running", "queued":
            Button(action: actions.pause) { Label("Pause", systemImage: "pause.fill") }
        case "paused":
            Button(action: actions.start) { Label("Reprendre", systemImage: "play.fill") }
        case "error":
            Button(action: actions.retry) { Label("Réessayer", systemImage: "arrow.clockwise") }
        case "completed":
            Button(action: actions.play) { Label("Lire", systemImage: "play.rectangle.fill") }
            fileActions
        default:
            EmptyView()
        }
        Button(action: actions.showLogs) { Label("Journaux", systemImage: "doc.text.magnifyingglass") }
        Spacer()
        Button(role: .destructive, action: actions.remove) { Label("Supprimer", systemImage: "trash") }
    }

    @ViewBuilder
    private var fileActions: some View {
        #if os(macOS)
        Button(action: reveal) { Label("Afficher dans le Finder", systemImage: "folder") }
        #else
        ShareLink(item: URL(fileURLWithPath: task.savePath)) { Label("Partager", systemImage: "square.and.arrow.up") }
        #endif
    }

    @ViewBuilder
    private var menu: some View {
        switch task.state {
        case "running", "queued": Button("Mettre en pause", systemImage: "pause.fill", action: actions.pause)
        case "paused": Button("Reprendre", systemImage: "play.fill", action: actions.start)
        case "error": Button("Réessayer", systemImage: "arrow.clockwise", action: actions.retry)
        case "completed":
            Button("Lire", systemImage: "play.rectangle.fill", action: actions.play)
            #if os(macOS)
            Button("Afficher dans le Finder", systemImage: "folder", action: reveal)
            #endif
        default: EmptyView()
        }
        Button("Voir les journaux", systemImage: "doc.text.magnifyingglass", action: actions.showLogs)
        Button("Copier l'URL source", systemImage: "link") { Clipboard.copy(task.url) }
        Divider()
        Button("Supprimer…", systemImage: "trash", role: .destructive, action: actions.remove)
    }

    #if os(macOS)
    private func reveal() {
        let file = URL(fileURLWithPath: task.savePath)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }
    #endif
}
