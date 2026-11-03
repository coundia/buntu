import SwiftUI
import CndCoreBridge

public struct RecordingsView: View {
    @Bindable var model: RecordingsModel
    let onPlay: (RecordingRecord) -> Void

    public init(model: RecordingsModel, onPlay: @escaping (RecordingRecord) -> Void) {
        self.model = model
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Sur iOS, l'enregistrement fonctionne tant que l'application reste active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            #endif

            Picker("Filtre", selection: $model.filter) {
                ForEach(RecordingFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            if model.filter == .rules {
                seriesRulesList
            } else {
                recordingsList
            }
        }
        .navigationTitle("Enregistrements")
        .searchable(text: $model.searchText, prompt: "Rechercher un enregistrement")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.loadAll()
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private var recordingsList: some View {
        let items = model.filteredRecordings
        if items.isEmpty {
            ContentUnavailableView {
                Label("Aucun enregistrement", systemImage: "recordingtape")
            } description: {
                Text(emptyDescription)
            }
        } else {
            List {
                ForEach(items) { recording in
                    RecordingRowView(
                        recording: recording,
                        onPlay: { onPlay(recording) },
                        onCancel: { model.cancel(id: recording.id) },
                        onDelete: { model.delete(id: recording.id, deleteFile: true) }
                    )
                }
            }
            #if os(tvOS)
            .listStyle(.plain)
            #else
            .listStyle(.inset)
            #endif
        }
    }

    @ViewBuilder
    private var seriesRulesList: some View {
        if model.seriesRules.isEmpty {
            ContentUnavailableView {
                Label("Aucune règle Series-Link", systemImage: "repeat")
            } description: {
                Text("Créez une règle depuis le Guide TV pour enregistrer automatiquement tous les épisodes d'une série.")
            }
        } else {
            List {
                ForEach(model.seriesRules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.titleKey.capitalized)
                                .font(.headline)
                            if let ch = rule.channelTvgId, !ch.isEmpty {
                                Text("Chaîne : \(ch)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Toutes les chaînes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.removeSeriesRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Supprimer cette règle")
                    }
                    .padding(.vertical, 4)
                }
            }
            #if os(tvOS)
            .listStyle(.plain)
            #else
            .listStyle(.inset)
            #endif
        }
    }

    private var emptyDescription: String {
        switch model.filter {
        case .all:
            return "Vous n'avez aucun enregistrement pour le moment. Planifiez-en depuis le Guide TV."
        case .recording:
            return "Aucun enregistrement en cours."
        case .scheduled:
            return "Aucun enregistrement planifié."
        case .completed:
            return "Aucun enregistrement terminé."
        case .rules:
            return ""
        }
    }
}

private struct RecordingRowView: View {
    let recording: RecordingRecord
    let onPlay: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recording.channelName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                    Text(recording.title)
                        .font(.headline)

                    statusBadge
                }

                if let subtitle = recording.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Label(formattedDateRange, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if recording.bytesWritten > 0 {
                        Label(formattedBytes, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let err = recording.error, !err.isEmpty {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if recording.state == "completed" || recording.state == "partial" {
                    Button(action: onPlay) {
                        Label("Lire", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Supprimer l'enregistrement")
                } else if recording.state == "recording" || recording.state == "scheduled" {
                    Button(role: .destructive, action: onCancel) {
                        Label("Annuler", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Supprimer l'entrée")
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.state {
        case "recording":
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("EN COURS")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12), in: Capsule())

        case "scheduled":
            Text("Planifié")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())

        case "completed":
            Text("Terminé")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12), in: Capsule())

        case "partial":
            Text("Partiel")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())

        case "failed":
            Text("Échec")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12), in: Capsule())

        case "cancelled":
            Text("Annulé")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())

        default:
            EmptyView()
        }
    }

    private var formattedDateRange: String {
        let start = Date(timeIntervalSince1970: TimeInterval(recording.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(recording.endTs))
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM HH:mm"
        let endFmt = DateFormatter()
        endFmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: start)) – \(endFmt.string(from: end))"
    }

    private var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(recording.bytesWritten), countStyle: .file)
    }
}

