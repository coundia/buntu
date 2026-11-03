import SwiftUI
import CndCoreBridge

/// Command palette (⌘K on macOS, a sheet from the ✨ button on iOS): type or dictate what to watch.
struct CommandPaletteView: View {
    @Bindable var model: AssistantModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            Divider()
            content
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
        .task { fieldFocused = true }
        #if os(macOS)
        .onExitCommand { model.onDismiss() }
        #endif
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint).font(.title3)
            TextField("Quelle chaîne voulez-vous ? (« France 2 », « le match du PSG »…)", text: $model.input)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .disabled(model.isResolving)
                .onSubmit { Task { await model.submit() } }
                #if os(macOS)
                .onKeyPress(.upArrow) { model.recallOlder(); return .handled }
                .onKeyPress(.downArrow) { model.recallNewer(); return .handled }
                #else
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if model.isResolving {
                ProgressView().controlSize(.small)
                Button("Annuler") { model.cancel() }.buttonStyle(.borderless)
            } else if !model.input.isEmpty {
                Button { model.input = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Effacer")
            }
        }
        .padding(14)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            message(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else if let result = model.result {
            resultView(result)
        } else if model.isResolving {
            message("Recherche de la chaîne…", systemImage: "hourglass", tint: .secondary)
        } else if !model.suggestions.isEmpty {
            channelList(model.suggestions, title: "Suggestions")
        } else if model.input.trimmingCharacters(in: .whitespaces).isEmpty {
            idleView
        } else {
            message("Appuyez sur Entrée pour lancer la recherche.", systemImage: "return", tint: .secondary)
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title).foregroundStyle(tint)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: AiCommandResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.reply).font(.headline)
                HStack(spacing: 6) {
                    Text(result.resolvedBy == "local" ? "Résolu localement" : "Résolu par \(result.resolvedBy)")
                    Text("· \(result.latencyMs) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = result.fallbackReason {
                    Label("Repli sur la résolution locale : \(reason)", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            if !result.alternatives.isEmpty {
                channelList(result.alternatives, title: "Choisissez une chaîne")
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func channelList(_ items: [IptvItemRecord], title: String) -> some View {
        List {
            Section(title) {
                ForEach(items, id: \.id) { item in
                    Button { model.choose(item) } label: {
                        HStack(spacing: 10) {
                            ThumbnailImageView(urlString: item.logoUrl, size: .tvLogo).frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                if let group = item.groupTitle, !group.isEmpty {
                                    Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let number = item.chno { Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.history.isEmpty {
                Text("Exemples").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(["France 2", "chaîne 6", "mets le match du PSG", "une chaîne d'info en anglais", "suivante"], id: \.self) { example in
                    suggestionButton(example)
                }
            } else {
                HStack {
                    Text("Récent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Effacer l'historique") { model.clearHistory() }.buttonStyle(.borderless).font(.caption)
                }
                ForEach(model.history.prefix(6), id: \.self) { entry in
                    suggestionButton(entry)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionButton(_ text: String) -> some View {
        Button { model.input = text } label: {
            Text(text).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.settings.isRemoteReady ? "network" : "internaldrive")
            Text(model.settings.summary)
            Spacer()
            #if os(macOS)
            Text("↩︎ lancer · ↑↓ historique · esc fermer")
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
