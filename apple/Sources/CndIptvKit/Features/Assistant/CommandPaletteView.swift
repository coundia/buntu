import SwiftUI
import CndCoreBridge

/// Command palette (⌘K on macOS, a sheet from the ✨ button on iOS): type or dictate what to watch.
struct CommandPaletteView: View {
    @Bindable var model: AssistantModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            scopePicker
            Divider()
            content
            inactiveProviderNote
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

    /// Films, series and TV are searched apart; the screen the palette was opened from picks one.
    @ViewBuilder
    private var scopePicker: some View {
        if model.backend.supportsPromptSearch {
            Picker("Chercher dans", selection: $model.scope) {
                ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .accessibilityLabel("Chercher dans")
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.tint).font(.title3)
            TextField(model.scope.placeholder, text: $model.input)
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
            // Closes the palette (a sheet on iPhone has no other obvious way out; esc does it on a Mac).
            Button { model.onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(6)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            #if !os(tvOS)
            .keyboardShortcut(.cancelAction)
            #endif
            .accessibilityLabel("Fermer l'assistant")
            .help("Fermer (échap)")
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
        } else if !model.liveHits.isEmpty {
            // While the assistant works the local results stay on screen: it refines them, never replaces them.
            searchResultsView(model.searchResponse)
        } else if model.isResolving {
            message("Recherche en cours…", systemImage: "hourglass", tint: .secondary)
        } else if let response = model.searchResponse, !response.missingTitles.isEmpty {
            searchResultsView(response)
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

    // MARK: Prompt search results (PRD 33)

    private static let kindOrder: [SearchKind] = [.program, .live, .movie, .series]

    private func title(of kind: SearchKind) -> String {
        switch kind {
        case .program: return "Programmes"
        case .live: return "Chaînes en direct"
        case .movie: return "Films"
        case .series: return "Séries"
        }
    }

    private func sections(_ hits: [SearchHit]) -> [(kind: SearchKind, hits: [SearchHit])] {
        // The kind of the best result first, then the others in their usual order.
        let bestFirst = hits.first?.kind
        let order = Self.kindOrder.sorted { a, b in
            if a == bestFirst { return b != bestFirst }
            if b == bestFirst { return false }
            return (Self.kindOrder.firstIndex(of: a) ?? 0) < (Self.kindOrder.firstIndex(of: b) ?? 0)
        }
        return order.compactMap { kind in
            let group = hits.filter { $0.kind == kind }
            return group.isEmpty ? nil : (kind, group)
        }
    }

    private func searchResultsView(_ response: SearchResponse?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            searchHeader(response)
            List {
                ForEach(sections(model.liveHits), id: \.kind) { section in
                    Section(title(of: section.kind)) {
                        ForEach(Array(section.hits.enumerated()), id: \.offset) { _, hit in
                            hitRow(hit)
                        }
                    }
                }
                if let missing = response?.missingTitles, !missing.isEmpty {
                    Section {
                        Label(
                            "\(missing.count) titre\(missing.count > 1 ? "s" : "") connu\(missing.count > 1 ? "s" : "") absent\(missing.count > 1 ? "s" : "") de vos sources : \(missing.prefix(4).joined(separator: ", "))\(missing.count > 4 ? "…" : "")",
                            systemImage: "tray"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func searchHeader(_ response: SearchResponse?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let response {
                if !response.reply.isEmpty { Text(response.reply).font(.headline) }
                HStack(spacing: 6) {
                    Text(response.resolvedBy == "local" ? "Recherche locale" : "Classés par l'assistant (\(response.resolvedBy))")
                    Text("· \(response.latencyMs) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = response.fallbackReason {
                    Label("Assistant indisponible, résultats locaux : \(reason)", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if model.isResolving || model.isRefining {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Résultats locaux · l'assistant affine…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, response == nil && !model.isResolving && !model.isRefining ? 0 : 10)
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        Button { model.choose(hit) } label: {
            HStack(spacing: 10) {
                ThumbnailImageView(
                    urlString: hit.series?.posterUrl ?? hit.item?.logoUrl,
                    size: hit.kind == .movie || hit.kind == .series ? .poster : .tvLogo
                )
                .frame(width: 32, height: hit.kind == .movie || hit.kind == .series ? 48 : 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(SearchHitText.title(hit)).lineLimit(1)
                        if hit.fromAssistant {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.tint)
                                .accessibilityLabel("Proposé par l'assistant")
                        }
                    }
                    if !hit.reason.isEmpty {
                        Text(hit.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: SearchHitText.actionSymbol(hit)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SearchHitText.accessibilityLabel(hit))
        .accessibilityHint(SearchHitText.actionLabel(hit))
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
                ForEach(model.scope.examples, id: \.self) { example in
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

    /// A provider is chosen but not used: say why, and offer the one click that fixes the usual cause.
    @ViewBuilder
    private var inactiveProviderNote: some View {
        if model.settings.choice.isRemote, let blocker = model.settings.blocker {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(model.settings.choice.title) n'est pas utilisé : \(blocker)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !model.settings.needsConsentOnly {
                    Button("Réglages") {
                        model.onDismiss()
                        model.onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if model.settings.needsConsentOnly {
                    Button("Autoriser") {
                        model.settings.consent = true
                        model.providerDidChange()
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint("Autorise l'envoi de vos recherches à \(model.settings.choice.title)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    /// Which AI answers, and a way to change it without leaving the palette.
    private var providerMenu: some View {
        Menu {
            ForEach(AssistantModel.selectableProviders) { provider in
                Button {
                    model.select(provider: provider)
                } label: {
                    if provider == model.settings.choice {
                        Label(provider.title, systemImage: "checkmark")
                    } else {
                        Text(provider.title)
                    }
                }
            }
            Divider()
            Button("Réglages de l'assistant…") {
                model.onDismiss()
                model.onOpenSettings()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.settings.isRemoteReady ? "network" : "internaldrive")
                Text(model.settings.summary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Changer d'IA")
        .accessibilityLabel("Changer d'IA")
        .accessibilityValue(model.settings.summary)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            providerMenu
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
