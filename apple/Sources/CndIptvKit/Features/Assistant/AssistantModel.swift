import Foundation
import Observation
import CndCoreBridge

/// The slice of `CndEngine` the assistant uses; scripted in tests.
protocol AssistantBackend: AnyObject, Sendable {
    func aiResolveCommand(command: String, context: AiCommandContext, config: AiProviderConfig) async throws -> AiCommandResult
    func aiTestProvider(config: AiProviderConfig) async throws -> AiProviderStatus
    func getItemById(itemId: Int64) throws -> IptvItemRecord?
    /// Prompt search (PRD 33): films, series, programmes and channels from a sentence.
    var supportsPromptSearch: Bool { get }
    func searchLocal(text: String, context: SearchContext) -> SearchResponse
    func searchWithAi(text: String, context: SearchContext, config: AiProviderConfig) async throws -> SearchResponse
}

extension AssistantBackend {
    var supportsPromptSearch: Bool { false }

    func searchLocal(text: String, context: SearchContext) -> SearchResponse {
        SearchResponse(command: nil, hits: [], missingTitles: [], reply: "", resolvedBy: "local", latencyMs: 0, fallbackReason: nil)
    }

    func searchWithAi(text: String, context: SearchContext, config: AiProviderConfig) async throws -> SearchResponse {
        throw CndError.Internal(message: "La recherche par prompt n'est pas disponible.")
    }
}

extension CndEngine: AssistantBackend {
    var supportsPromptSearch: Bool { true }
}

/// What the assistant can do to the app; filled in by the shell.
struct AssistantActions {
    var play: (IptvItemRecord) -> Void = { _ in }
    var showGuide: (IptvItemRecord) -> Void = { _ in }
    var next: () -> Void = {}
    var previous: () -> Void = {}
    var search: (String) -> Void = { _ in }
    var multiView: ([IptvItemRecord]) -> Void = { _ in }
    /// Shows a film's page (PRD 33): the search finds films and series, not only channels.
    var openMovie: (IptvItemRecord) -> Void = { _ in }
    var openSeries: (SeriesRecord) -> Void = { _ in }
}

/// State of the command palette: typed phrase, live local suggestions, the resolved action and the
/// local history. Engine calls run off the main actor and a generation counter drops stale answers.
@Observable
@MainActor
final class AssistantModel {
    nonisolated static var historyLimit: Int { 20 }
    nonisolated static var historyKey: String { "assistant.history" }

    let backend: AssistantBackend
    let settings: AiProviderSettings
    private let defaults: UserDefaults
    private let suggestionDelay: Duration

    @ObservationIgnored var actions = AssistantActions()
    @ObservationIgnored var playingStableHash: () -> String? = { nil }
    @ObservationIgnored var currentGroup: () -> String? = { nil }
    @ObservationIgnored var onDismiss: () -> Void = {}

    var input = "" { didSet { if input != oldValue { inputChanged() } } }
    private(set) var suggestions: [IptvItemRecord] = []
    private(set) var result: AiCommandResult?
    /// Results of the prompt search while typing (local, instant) and after Enter (with the assistant).
    private(set) var liveHits: [SearchHit] = []
    private(set) var searchResponse: SearchResponse?
    private(set) var isResolving = false
    private(set) var errorMessage: String?
    private(set) var history: [String]

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suggestionGeneration = 0
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var isRecalling = false

    init(
        backend: AssistantBackend,
        settings: AiProviderSettings,
        defaults: UserDefaults = .standard,
        suggestionDelay: Duration = .milliseconds(150)
    ) {
        self.backend = backend
        self.settings = settings
        self.defaults = defaults
        self.suggestionDelay = suggestionDelay
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    nonisolated static var localConfig: AiProviderConfig {
        AiProviderConfig(kind: .localOnly, model: "", baseUrl: nil, apiKey: nil, timeoutMs: AiProviderSettings.timeoutMs)
    }

    private var searchContext: SearchContext {
        SearchContext(
            playingStableHash: playingStableHash(),
            groupTitle: currentGroup(),
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            utcOffsetMinutes: Int32(TimeZone.current.secondsFromGMT() / 60)
        )
    }

    private var context: AiCommandContext {
        AiCommandContext(
            playingStableHash: playingStableHash(),
            groupTitle: currentGroup(),
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        )
    }

    // MARK: Live local suggestions

    private func inputChanged() {
        if !isRecalling { historyIndex = nil }
        result = nil
        searchResponse = nil
        errorMessage = nil
        suggestionTask?.cancel()
        suggestionGeneration += 1
        let gen = suggestionGeneration
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            suggestions = []
            liveHits = []
            return
        }
        let delay = suggestionDelay
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.refreshSuggestions(for: text, generation: gen)
        }
    }

    /// Uses the engine's own local resolution (no network): the same fillers, numbers and
    /// synonyms as a real command, so what is suggested is what pressing Enter would find.
    private func refreshSuggestions(for text: String, generation gen: Int) async {
        let backend = self.backend
        if backend.supportsPromptSearch {
            // The prompt search answers every keystroke from the catalog, without any network.
            let searchContext = self.searchContext
            let local = await Task.detached { backend.searchLocal(text: text, context: searchContext) }.value
            guard gen == suggestionGeneration else { return }
            liveHits = local.hits
            return
        }
        let ctx = context
        guard let local = try? await backend.aiResolveCommand(command: text, context: ctx, config: Self.localConfig) else { return }
        guard gen == suggestionGeneration else { return }
        switch local.action {
        case .playChannel(let itemId), .showGuide(let itemId):
            if let item = try? backend.getItemById(itemId: itemId) { suggestions = [item] } else { suggestions = [] }
        default:
            suggestions = local.alternatives
        }
    }

    // MARK: Submitting

    func submit() async {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isResolving else { return }
        suggestionTask?.cancel()
        generation += 1
        let gen = generation
        isResolving = true
        errorMessage = nil
        result = nil
        searchResponse = nil
        if backend.supportsPromptSearch {
            await submitSearch(command, generation: gen)
            return
        }
        let config = settings.providerConfig()
        let ctx = context
        let backend = self.backend
        do {
            let resolved = try await backend.aiResolveCommand(command: command, context: ctx, config: config)
            guard gen == generation else { return }
            remember(command)
            perform(resolved)
        } catch {
            guard gen == generation else { return }
            errorMessage = settings.explaining(userMessage(for: error))
        }
        if gen == generation { isResolving = false }
    }

    /// Prompt search with the user's provider: a direct command is performed, anything else shows results.
    private func submitSearch(_ command: String, generation gen: Int) async {
        let backend = self.backend
        let config = settings.providerConfig()
        let ctx = searchContext
        do {
            let response = try await backend.searchWithAi(text: command, context: ctx, config: config)
            guard gen == generation else { return }
            remember(command)
            if let action = response.command {
                perform(AiCommandResult(
                    action: action, alternatives: [], reply: response.reply, resolvedBy: response.resolvedBy,
                    latencyMs: response.latencyMs, fallbackReason: response.fallbackReason
                ))
            } else if response.hits.isEmpty && response.missingTitles.isEmpty {
                // Nothing in the sources: hand the words to the catalog search, as before.
                actions.search(command)
                onDismiss()
            } else {
                searchResponse = response
                liveHits = response.hits
            }
        } catch {
            guard gen == generation else { return }
            errorMessage = settings.explaining(userMessage(for: error))
        }
        if gen == generation { isResolving = false }
    }

    func cancel() {
        generation += 1
        isResolving = false
    }

    /// The user picked one of the proposed channels.
    func choose(_ item: IptvItemRecord) {
        actions.play(item)
        onDismiss()
    }

    /// The user picked a result of the prompt search: what happens depends on what it is.
    /// A programme on the air plays its channel; a later or past one opens the channel's guide.
    func choose(_ hit: SearchHit, now: Date = Date()) {
        switch hit.kind {
        case .live:
            if let item = hit.item { actions.play(item) }
        case .program:
            guard let channel = hit.item else { return }
            if let program = hit.program,
               Int64(now.timeIntervalSince1970) >= program.startTs, Int64(now.timeIntervalSince1970) < program.endTs {
                actions.play(channel)
            } else {
                actions.showGuide(channel)
            }
        case .movie:
            if let item = hit.item { actions.openMovie(item) }
        case .series:
            if let series = hit.series { actions.openSeries(series) }
        }
        onDismiss()
    }

    private func perform(_ resolved: AiCommandResult) {
        result = resolved
        switch resolved.action {
        case .playChannel(let itemId):
            if let item = item(itemId) { actions.play(item); onDismiss() }
        case .showGuide(let itemId):
            if let item = item(itemId) { actions.showGuide(item); onDismiss() }
        case .nextChannel:
            actions.next()
            onDismiss()
        case .previousChannel:
            actions.previous()
            onDismiss()
        case .search(let query):
            actions.search(query)
            onDismiss()
        case .multiView(let itemIds):
            let items = itemIds.compactMap { item($0) }
            if !items.isEmpty {
                actions.multiView(items)
                onDismiss()
            }
        case .none:
            break // the palette stays open to show the reply or the proposed channels
        }
    }

    private func item(_ id: Int64) -> IptvItemRecord? {
        if let found = try? backend.getItemById(itemId: id) { return found }
        errorMessage = "Cette chaîne n'existe plus dans le catalogue."
        return nil
    }

    // MARK: Provider test

    func testProvider() async -> AiProviderStatus {
        do {
            return try await backend.aiTestProvider(config: settings.testConfig())
        } catch {
            return AiProviderStatus(ok: false, latencyMs: 0, model: "", message: settings.explaining(userMessage(for: error)))
        }
    }

    // MARK: Local history (never sent anywhere)

    private func remember(_ command: String) {
        history.removeAll { $0.caseInsensitiveCompare(command) == .orderedSame }
        history.insert(command, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        defaults.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
    }

    /// Arrow up / down in the field walks through earlier commands.
    func recallOlder() {
        guard !history.isEmpty else { return }
        let next = min((historyIndex ?? -1) + 1, history.count - 1)
        recall(index: next)
    }

    func recallNewer() {
        guard let index = historyIndex else { return }
        if index == 0 {
            historyIndex = nil
            isRecalling = true
            input = ""
            isRecalling = false
        } else {
            recall(index: index - 1)
        }
    }

    private func recall(index: Int) {
        historyIndex = index
        isRecalling = true
        input = history[index]
        isRecalling = false
    }
}
