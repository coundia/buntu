import Foundation
import Observation
import CndCoreBridge

/// What the « Pour vous » shelves need from the engine (PRD 34). A seam so tests need no database.
protocol ForYouBackend: Sendable {
    func localShelves(kind: RecoKind, limit: UInt32, utcOffsetMinutes: Int32) throws -> [RecoShelf]
    func refinedShelves(
        kind: RecoKind, config: AiProviderConfig, limit: UInt32, sendRecentTitles: Bool,
        locale: String, utcOffsetMinutes: Int32
    ) async -> [RecoShelf]
    func dismiss(stableHash: String) throws
    func lessLikeThis(kind: RecoKind, stableHash: String) throws
    func resetTaste(kind: RecoKind) throws
    /// Lot 34.5: the two steps of a re-rank by the model of Apple (the engine builds and validates, Swift asks).
    func prepareAppleRerank(kind: RecoKind, limitPerShelf: UInt32, locale: String, utcOffsetMinutes: Int32) throws -> AppleRerankStart
    func finishAppleRerank(request: AppleRerankRequest, answer: String) throws -> [RecoShelf]
}

extension CndEngine: ForYouBackend {
    func localShelves(kind: RecoKind, limit: UInt32, utcOffsetMinutes: Int32) throws -> [RecoShelf] {
        try recommendationShelves(kind: kind, limitPerShelf: limit, utcOffsetMinutes: utcOffsetMinutes)
    }

    func refinedShelves(
        kind: RecoKind, config: AiProviderConfig, limit: UInt32, sendRecentTitles: Bool,
        locale: String, utcOffsetMinutes: Int32
    ) async -> [RecoShelf] {
        (try? await refineShelvesWithAi(
            kind: kind, config: config, limitPerShelf: limit, sendRecentTitles: sendRecentTitles,
            locale: locale, utcOffsetMinutes: utcOffsetMinutes
        )) ?? []
    }

    func dismiss(stableHash: String) throws { try dismissRecommendation(stableHash: stableHash) }
}

/// The settings of the « Pour vous » rows, shared by the three screens.
@Observable
@MainActor
final class ForYouHub {
    static let moviesKey = "reco.foryou.movies"
    static let seriesKey = "reco.foryou.series"
    static let liveKey = "reco.foryou.live"
    static let aiRefineKey = "reco.ai.refine"
    static let sendRecentKey = "reco.ai.sendRecent"
    static let onDeviceKey = "reco.ai.onDevice"

    @ObservationIgnored private let defaults: UserDefaults
    let ai: AiProviderSettings
    /// The model of Apple, when this device has it (lot 34.5).
    let onDevice: OnDeviceTextModel

    var moviesEnabled: Bool { didSet { defaults.set(moviesEnabled, forKey: Self.moviesKey) } }
    var seriesEnabled: Bool { didSet { defaults.set(seriesEnabled, forKey: Self.seriesKey) } }
    var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: Self.liveKey) } }
    /// Let the assistant's provider re-rank « Pour vous » (only when that provider is ready).
    var aiRefine: Bool { didSet { defaults.set(aiRefine, forKey: Self.aiRefineKey) } }
    /// Send the titles last watched to a REMOTE provider (off by default; a model on this device always gets them).
    var sendRecentTitles: Bool { didSet { defaults.set(sendRecentTitles, forKey: Self.sendRecentKey) } }
    /// Re-rank with the model of Apple on this device instead of the assistant's provider. Off by default:
    /// its quality on this task is still to be measured (PRD 34 § 15).
    var preferOnDeviceModel: Bool { didSet { defaults.set(preferOnDeviceModel, forKey: Self.onDeviceKey) } }

    /// The model of Apple will answer: the user asked for it and the device has it.
    var usesOnDeviceModel: Bool { preferOnDeviceModel && onDevice.isAvailable }

    private(set) var movies: ForYouModel!
    private(set) var series: ForYouModel!
    private(set) var live: ForYouModel!

    /// Where the shelves come from (the engine; replaced by a fake in tests).
    @ObservationIgnored private var backendProvider: () -> ForYouBackend?

    init(
        ai: AiProviderSettings, defaults: UserDefaults = .standard,
        onDevice: OnDeviceTextModel = AppleOnDeviceModel.shared,
        backend: @escaping () -> ForYouBackend? = { nil }
    ) {
        self.ai = ai
        self.defaults = defaults
        self.onDevice = onDevice
        self.backendProvider = backend
        moviesEnabled = defaults.object(forKey: Self.moviesKey) as? Bool ?? true
        seriesEnabled = defaults.object(forKey: Self.seriesKey) as? Bool ?? true
        liveEnabled = defaults.object(forKey: Self.liveKey) as? Bool ?? true
        aiRefine = defaults.object(forKey: Self.aiRefineKey) as? Bool ?? true
        sendRecentTitles = defaults.object(forKey: Self.sendRecentKey) as? Bool ?? false
        preferOnDeviceModel = defaults.object(forKey: Self.onDeviceKey) as? Bool ?? false
        movies = ForYouModel(kind: .movies, hub: self)
        series = ForYouModel(kind: .series, hub: self)
        live = ForYouModel(kind: .live, hub: self)
    }

    func setBackend(_ provider: @escaping () -> ForYouBackend?) { backendProvider = provider }

    var backend: ForYouBackend? { backendProvider() }

    func isEnabled(_ kind: RecoKind) -> Bool {
        switch kind {
        case .movies: moviesEnabled
        case .series: seriesEnabled
        case .live: liveEnabled
        }
    }

    func model(for kind: RecoKind) -> ForYouModel {
        switch kind {
        case .movies: movies
        case .series: series
        case .live: live
        }
    }
}

/// The shelves of ONE kind. They show at once from the local engine; when the user's provider is
/// ready, the answer of the AI replaces them only if it comes back valid.
@Observable
@MainActor
final class ForYouModel {
    let kind: RecoKind
    private(set) var shelves: [RecoShelf] = []
    private(set) var isRefining = false

    @ObservationIgnored private unowned let hub: ForYouHub
    @ObservationIgnored private var generation = 0

    nonisolated static let shelfLimit: UInt32 = 12
    /// The model of Apple must answer within this many seconds (PRD 34: 8 s at most).
    nonisolated static let onDeviceDeadline: Double = 8

    init(kind: RecoKind, hub: ForYouHub) {
        self.kind = kind
        self.hub = hub
    }

    var isEnabled: Bool { hub.isEnabled(kind) }

    /// The provider that re-ranked the main shelf, if any.
    var refinedBy: String? { shelves.compactMap(\.refinedBy).first }

    /// Minutes east of UTC: the TV habits depend on the time of the week, local time.
    nonisolated static func utcOffsetMinutes(_ zone: TimeZone = .current, at date: Date = Date()) -> Int32 {
        Int32(zone.secondsFromGMT(for: date) / 60)
    }

    // MARK: The kind lock, third and last (the engine checks too)

    /// Whether a card belongs to a shelf of this kind: a film is never in a series row, nor a channel in a film row.
    nonisolated static func belongs(_ kind: RecoKind, _ card: RecoCard) -> Bool {
        switch kind {
        case .movies:
            return card.item?.kind == "movie" && card.series == nil && card.program == nil && card.nextEpisode == nil
        case .series:
            guard let series = card.series, card.item == nil, card.program == nil else { return false }
            guard let episode = card.nextEpisode else { return true }
            return episode.kind == "episode" && episode.seriesId == series.id
        case .live:
            guard let channel = card.item, channel.kind == "live", card.series == nil, card.nextEpisode == nil else { return false }
            guard let program = card.program else { return true }
            return channel.tvgId == program.channelTvgId
        }
    }

    nonisolated static func filtered(_ kind: RecoKind, _ shelves: [RecoShelf]) -> [RecoShelf] {
        shelves.compactMap { shelf in
            var copy = shelf
            copy.kind = kind
            copy.items = shelf.items.filter { belongs(kind, $0) }
            return copy.items.isEmpty && copy.shelf != .guideStale ? nil : copy
        }
    }

    nonisolated static func hash(of card: RecoCard) -> String {
        card.series?.stableHash ?? card.item?.stableHash ?? ""
    }

    // MARK: Loading

    func reload(revision: Int = 0) async {
        generation += 1
        let mine = generation
        isRefining = false
        guard isEnabled, let backend = hub.backend else {
            shelves = []
            return
        }
        let kind = self.kind
        let offset = Self.utcOffsetMinutes()
        let local = await Task.detached(priority: .userInitiated) {
            (try? backend.localShelves(kind: kind, limit: Self.shelfLimit, utcOffsetMinutes: offset)) ?? []
        }.value
        guard mine == generation else { return }
        shelves = Self.filtered(kind, local)

        guard hub.aiRefine, !shelves.contains(where: { $0.shelf == .guideStale }) else { return }

        // The model of Apple, when the user chose it: nothing leaves the device.
        if hub.usesOnDeviceModel {
            isRefining = true
            let refined = await refineOnDevice(backend: backend, offset: offset)
            guard mine == generation else { return }
            isRefining = false
            if let refined { shelves = Self.filtered(kind, refined) }
            return
        }

        // The assistant's provider, only when the user switched it on and it is ready (key, consent).
        guard hub.ai.isAssistantEnabled, hub.ai.isRemoteReady else { return }
        let config = hub.ai.providerConfig()
        guard config.kind != .localOnly else { return }
        let sendRecent = hub.ai.endpointIsLocal || hub.sendRecentTitles
        isRefining = true
        let refined = await backend.refinedShelves(
            kind: kind, config: config, limit: Self.shelfLimit, sendRecentTitles: sendRecent,
            locale: Locale.current.identifier, utcOffsetMinutes: offset
        )
        guard mine == generation else { return }
        isRefining = false
        // A failed or rejected answer comes back as the local shelves (no `refinedBy`): keep what is shown.
        if refined.contains(where: { $0.refinedBy != nil }) {
            shelves = Self.filtered(kind, refined)
        }
    }

    /// The two steps of lot 34.5: the engine builds the question, the model of Apple answers, the engine
    /// validates. `nil` (keep the local shelves) at the first problem: no model, no answer, a bad answer.
    private func refineOnDevice(backend: ForYouBackend, offset: Int32) async -> [RecoShelf]? {
        let kind = self.kind
        let model = hub.onDevice
        let locale = Locale.current.identifier
        do {
            let start = try await Task.detached(priority: .userInitiated) {
                try backend.prepareAppleRerank(kind: kind, limitPerShelf: Self.shelfLimit, locale: locale, utcOffsetMinutes: offset)
            }.value
            let refined: [RecoShelf]
            switch start {
            case .skip:
                return nil
            case .cached(let cachedShelves):
                refined = cachedShelves
            case .ask(let request):
                let answer = try await withDeadline(seconds: Self.onDeviceDeadline) {
                    try await model.respond(system: request.system, user: request.user)
                }
                refined = try await Task.detached(priority: .userInitiated) {
                    try backend.finishAppleRerank(request: request, answer: answer)
                }.value
            }
            return refined.contains(where: { $0.refinedBy != nil }) ? refined : nil
        } catch {
            return nil
        }
    }

    // MARK: Feedback

    /// « Pas intéressé »: the card disappears now and never comes back.
    func dismiss(_ card: RecoCard) {
        let hash = Self.hash(of: card)
        guard !hash.isEmpty else { return }
        try? hub.backend?.dismiss(stableHash: hash)
        remove(hash: hash)
    }

    /// « Moins de ce genre »: lowers its main genre for this kind only, and hides it.
    func lessLikeThis(_ card: RecoCard) {
        let hash = Self.hash(of: card)
        guard !hash.isEmpty else { return }
        try? hub.backend?.lessLikeThis(kind: kind, stableHash: hash)
        remove(hash: hash)
    }

    func resetTaste() {
        try? hub.backend?.resetTaste(kind: kind)
    }

    private func remove(hash: String) {
        shelves = shelves.compactMap { shelf in
            var copy = shelf
            copy.items.removeAll { Self.hash(of: $0) == hash }
            return copy.items.isEmpty && copy.shelf != .guideStale ? nil : copy
        }
    }
}
