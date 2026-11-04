import Foundation
import Observation
import CndCoreBridge

/// Manages recommendations, "Up Next" shelf data, and the end-of-playback "Next Up" card.
@Observable
@MainActor
public final class UpNextModel {
    public private(set) var recommendations: [Recommendation] = []
    public private(set) var nextUp: Recommendation?
    public private(set) var sagaInfo: SagaInfo?
    public private(set) var isNextUpCardPresented: Bool = false
    public private(set) var isDismissedForCredits: Bool = false
    public private(set) var countdownSecondsRemaining: Int = 10
    public private(set) var autoChainCount: Int = 0
    public private(set) var isPromptingStillWatching: Bool = false
    public private(set) var isLoading: Bool = false

    // Settings
    public var isUpNextShelfEnabled: Bool {
        didSet { UserDefaults.standard.set(isUpNextShelfEnabled, forKey: "upnext.shelf.enabled") }
    }
    public var isNextUpCardEnabled: Bool {
        didSet { UserDefaults.standard.set(isNextUpCardEnabled, forKey: "upnext.card.enabled") }
    }
    public var isAutoPlayNextEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoPlayNextEnabled, forKey: "upnext.autoplay.enabled") }
    }
    public var countdownDuration: Int {
        didSet { UserDefaults.standard.set(countdownDuration, forKey: "upnext.countdown.seconds") }
    }
    public var sagaOrderPreference: SagaOrderPreference {
        didSet { UserDefaults.standard.set(sagaOrderPreference == .storyChronology ? "story" : "release", forKey: "upnext.saga.order") }
    }
    public var useAiForSagas: Bool {
        didSet { UserDefaults.standard.set(useAiForSagas, forKey: "upnext.ai.enabled") }
    }

    @ObservationIgnored private var engineProvider: () -> CndEngine?
    @ObservationIgnored private var playHandler: ((PlayableMedia) -> Void)?
    @ObservationIgnored private var aiConfigProvider: (() -> AiProviderConfig)?
    @ObservationIgnored private var countdownTimer: Task<Void, Never>?
    @ObservationIgnored private var aiSagaTask: Task<Void, Never>?
    @ObservationIgnored private var currentMediaId: Int64?

    public init(
        engineProvider: @escaping () -> CndEngine?,
        playHandler: ((PlayableMedia) -> Void)? = nil,
        aiConfigProvider: (() -> AiProviderConfig)? = nil
    ) {
        self.engineProvider = engineProvider
        self.playHandler = playHandler
        self.aiConfigProvider = aiConfigProvider

        self.isUpNextShelfEnabled = UserDefaults.standard.object(forKey: "upnext.shelf.enabled") as? Bool ?? true
        self.isNextUpCardEnabled = UserDefaults.standard.object(forKey: "upnext.card.enabled") as? Bool ?? true
        self.isAutoPlayNextEnabled = UserDefaults.standard.object(forKey: "upnext.autoplay.enabled") as? Bool ?? true
        self.countdownDuration = UserDefaults.standard.object(forKey: "upnext.countdown.seconds") as? Int ?? 10
        let orderRaw = UserDefaults.standard.string(forKey: "upnext.saga.order") ?? "story"
        self.sagaOrderPreference = orderRaw == "release" ? .releaseOrder : .storyChronology
        self.useAiForSagas = UserDefaults.standard.object(forKey: "upnext.ai.enabled") as? Bool ?? true
    }

    public var fallbackNextHandler: (() -> Void)?

    public func setEngineProvider(_ provider: @escaping () -> CndEngine?) {
        self.engineProvider = provider
    }

    public func setPlayHandler(_ handler: @escaping (PlayableMedia) -> Void) {
        self.playHandler = handler
    }

    public func setAiConfigProvider(_ provider: @escaping () -> AiProviderConfig) {
        self.aiConfigProvider = provider
    }

    // MARK: - Playback Events

    /// Loads recommendations and checks saga when a new media starts playing.
    public func onMediaChanged(_ media: PlayableMedia?) {
        countdownTimer?.cancel()
        countdownTimer = nil
        aiSagaTask?.cancel()
        aiSagaTask = nil

        isNextUpCardPresented = false
        isDismissedForCredits = false
        isPromptingStillWatching = false
        countdownSecondsRemaining = countdownDuration

        guard let media, let itemId = media.itemId else {
            recommendations = []
            nextUp = nil
            sagaInfo = nil
            currentMediaId = nil
            return
        }

        currentMediaId = itemId
        loadRecommendations(itemId: itemId, context: media.kind == .live ? .live : .playing)

        // If playing movie and AI enabled, schedule saga probe after 2 seconds
        if media.kind == .movie, useAiForSagas, let aiConfig = aiConfigProvider?(), aiConfig.kind != .localOnly {
            aiSagaTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.currentMediaId == itemId else { return }
                guard let engine = self.engineProvider() else { return }
                if let newSaga = try? await engine.resolveSagaWithAi(itemId: itemId, config: aiConfig) {
                    self.sagaInfo = newSaga
                    self.loadRecommendations(itemId: itemId, context: .playing)
                }
            }
        }
    }

    /// Evaluates proximity to the end of the film (<= 3% or <= 4 minutes).
    public func onPlaybackProgress(positionMs: Int64, durationMs: Int64) {
        guard isNextUpCardEnabled, !isDismissedForCredits, !isNextUpCardPresented else { return }
        guard durationMs > 0, nextUp != nil else { return }

        let remainingMs = max(durationMs - positionMs, 0)

        // Threshold: less than 3% or less than 4 minutes (240s = 240,000ms), whichever is shorter
        let thresholdMs: Int64 = min(240_000, Int64(Double(durationMs) * 0.03))
        if remainingMs <= thresholdMs {
            isNextUpCardPresented = true
        }
    }

    /// Triggers the automatic countdown only once the video has reached its actual end.
    public func onPlaybackEnded() {
        guard let _ = nextUp else {
            fallbackNextHandler?()
            return
        }
        isNextUpCardPresented = true
        isDismissedForCredits = false

        if isAutoPlayNextEnabled {
            startCountdown()
        }
    }

    // MARK: - Actions

    /// Hides the Next Up card until actual playback end ("Regarder le générique").
    public func dismissForCredits() {
        isDismissedForCredits = true
        isNextUpCardPresented = false
        countdownTimer?.cancel()
        countdownTimer = nil
    }

    /// Plays the Next Up item immediately.
    public func playNextUp() {
        countdownTimer?.cancel()
        countdownTimer = nil
        isNextUpCardPresented = false
        isPromptingStillWatching = false

        guard let next = nextUp, let playable = PlayableMedia(item: next.item) else { return }
        autoChainCount += 1
        playHandler?(playable)
    }

    /// User confirms they are still watching after the 3-chain safety pause.
    public func confirmStillWatchingAndPlay() {
        autoChainCount = 0
        isPromptingStillWatching = false
        playNextUp()
    }

    /// Cancels countdown and auto-advance.
    public func cancelAutoPlay() {
        countdownTimer?.cancel()
        countdownTimer = nil
        autoChainCount = 0
        isPromptingStillWatching = false
    }

    #if DEBUG
    public func setNextUpForTesting(_ rec: Recommendation?, recommendations: [Recommendation] = []) {
        self.nextUp = rec
        self.recommendations = recommendations
    }

    public func setAutoChainCountForTesting(_ count: Int) {
        self.autoChainCount = count
    }
    #endif

    /// Marks an item as "Pas intéressé" and removes it from current recommendations.
    public func dismissItem(stableHash: String) {
        if let engine = engineProvider() {
            try? engine.dismissRecommendation(stableHash: stableHash)
        }
        recommendations.removeAll { $0.item.stableHash == stableHash }
        if nextUp?.item.stableHash == stableHash {
            nextUp = recommendations.first
        }
    }

    /// Resets all dismissed recommendations for the active profile.
    public func resetDismissed() {
        guard let engine = engineProvider() else { return }
        try? engine.resetDismissedRecommendations()
        if let id = currentMediaId {
            loadRecommendations(itemId: id, context: .playing)
        }
    }

    // MARK: - Internal Loading

    private func loadRecommendations(itemId: Int64, context: RecommendationContext) {
        guard let engine = engineProvider() else { return }
        isLoading = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }

            let recs = (try? engine.recommendationsFor(itemId: itemId, context: context, limit: 12)) ?? []
            let next = (try? engine.nextUp(itemId: itemId)) ?? recs.first
            let saga = try? engine.sagaFor(itemId: itemId)

            self.recommendations = recs
            self.nextUp = next
            self.sagaInfo = saga
        }
    }

    private func startCountdown() {
        countdownTimer?.cancel()
        countdownSecondsRemaining = countdownDuration

        if autoChainCount >= 3 {
            isPromptingStillWatching = true
            return
        }

        countdownTimer = Task { @MainActor [weak self] in
            while let self = self, self.countdownSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.countdownSecondsRemaining -= 1
            }
            guard !Task.isCancelled, let self = self else { return }
            self.playNextUp()
        }
    }
}
