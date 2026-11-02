import Foundation
import Observation
import CndCoreBridge
#if canImport(UIKit)
import UIKit
#endif

public struct MultiViewSlot: Identifiable {
    public let id: UUID
    public var channel: IptvItemRecord
    public let controller: CndPlayerController

    public init(id: UUID = UUID(), channel: IptvItemRecord, controller: CndPlayerController) {
        self.id = id
        self.channel = channel
        self.controller = controller
    }
}

@Observable
@MainActor
public final class MultiViewController {
    public private(set) var slots: [MultiViewSlot] = []
    public private(set) var activeIndex: Int = 0
    public var layoutKind: MultiViewLayoutKind = .auto
    public var isPresented: Bool = false
    public var errorMessage: String? = nil

    private let persistenceKey = "multiview.saved_channel_hashes"

    public init() {}

    public var count: Int { slots.count }

    public var maxAllowedSlots: Int {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return 2
        }
        #endif
        return 4
    }

    public var activeSlot: MultiViewSlot? {
        guard slots.indices.contains(activeIndex) else { return nil }
        return slots[activeIndex]
    }

    public var activeController: CndPlayerController? {
        activeSlot?.controller
    }

    // MARK: - Capacity & Connection Guardrails

    public func canAdd(channel: IptvItemRecord, sources: [IptvSourceRecord] = []) -> (allowed: Bool, reason: String?) {
        if slots.count >= maxAllowedSlots {
            return (false, "La mosaïque est limitée à \(maxAllowedSlots) flux simultanés.")
        }

        if slots.contains(where: { $0.channel.id == channel.id }) {
            return (false, "Cette chaîne est déjà présente dans la mosaïque.")
        }

        if let source = sources.first(where: { $0.id == channel.sourceId }) {
            if let maxCons = source.maxConnections, maxCons > 0 {
                let currentFromSource = slots.filter { $0.channel.sourceId == channel.sourceId }.count
                if currentFromSource >= Int(maxCons) {
                    let name = source.name.isEmpty ? "Fournisseur" : source.name
                    return (false, "Votre abonnement « \(name) » autorise \(maxCons) connexion(s) simultanée(s).")
                }
            }
        }

        return (true, nil)
    }

    // MARK: - Slot Management

    @discardableResult
    public func addChannel(_ channel: IptvItemRecord, sources: [IptvSourceRecord] = [], makeActive: Bool = false) -> Bool {
        let (allowed, reason) = canAdd(channel: channel, sources: sources)
        guard allowed else {
            errorMessage = reason
            return false
        }

        guard let media = PlayableMedia(item: channel) else {
            errorMessage = "L'URL de « \(channel.name) » est invalide."
            return false
        }

        let controller = CndPlayerController()
        let shouldBeMuted = !slots.isEmpty && !makeActive
        controller.isMuted = shouldBeMuted
        controller.open(media)

        let slot = MultiViewSlot(channel: channel, controller: controller)
        slots.append(slot)

        if makeActive || slots.count == 1 {
            setActiveIndex(slots.count - 1)
        }

        isPresented = true
        errorMessage = nil
        saveConfiguration()
        return true
    }

    public func removeSlot(at index: Int) {
        guard slots.indices.contains(index) else { return }

        let removed = slots.remove(at: index)
        removed.controller.close()

        if slots.isEmpty {
            isPresented = false
            activeIndex = 0
            saveConfiguration()
            return
        }

        if activeIndex >= slots.count {
            activeIndex = slots.count - 1
        }
        applyAudioExclusivity()
        saveConfiguration()
    }

    public func setActiveIndex(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        activeIndex = index
        applyAudioExclusivity()
    }

    public func swapSlots(from: Int, to: Int) {
        guard slots.indices.contains(from), slots.indices.contains(to), from != to else { return }
        slots.swapAt(from, to)
        if activeIndex == from {
            activeIndex = to
        } else if activeIndex == to {
            activeIndex = from
        }
        applyAudioExclusivity()
        saveConfiguration()
    }

    @discardableResult
    public func replaceChannel(at index: Int, with newChannel: IptvItemRecord, sources: [IptvSourceRecord] = []) -> Bool {
        guard slots.indices.contains(index) else { return false }

        // If replacing with the same channel, nothing to do
        if slots[index].channel.id == newChannel.id { return true }

        // Check if other slots have this channel
        if slots.indices.contains(where: { $0 != index && slots[$0].channel.id == newChannel.id }) {
            errorMessage = "Cette chaîne est déjà présente dans la mosaïque."
            return false
        }

        // Check source connections (excluding the current slot if from same source)
        if let source = sources.first(where: { $0.id == newChannel.sourceId }), let maxCons = source.maxConnections, maxCons > 0 {
            let otherFromSource = slots.indices
                .filter { $0 != index && slots[$0].channel.sourceId == newChannel.sourceId }
                .count
            if otherFromSource + 1 > Int(maxCons) {
                let name = source.name.isEmpty ? "Fournisseur" : source.name
                errorMessage = "Votre abonnement « \(name) » autorise \(maxCons) connexion(s) simultanée(s)."
                return false
            }
        }

        guard let media = PlayableMedia(item: newChannel) else {
            errorMessage = "L'URL de « \(newChannel.name) » est invalide."
            return false
        }

        slots[index].channel = newChannel
        slots[index].controller.open(media)
        errorMessage = nil
        saveConfiguration()
        return true
    }

    public func closeAll() {
        for slot in slots {
            slot.controller.close()
        }
        slots.removeAll()
        isPresented = false
        activeIndex = 0
    }

    /// Pops the active channel and closes all other streams, returning the active channel for the main player.
    public func popActiveToSinglePlayer() -> IptvItemRecord? {
        guard let active = activeSlot else {
            closeAll()
            return nil
        }
        let channel = active.channel
        closeAll()
        return channel
    }

    // MARK: - Audio Exclusivity

    private func applyAudioExclusivity() {
        for (i, slot) in slots.enumerated() {
            let shouldBeMuted = (i != activeIndex)
            if slot.controller.isMuted != shouldBeMuted {
                slot.controller.isMuted = shouldBeMuted
            }
        }
    }

    // MARK: - Persistence & Restoration

    public func saveConfiguration() {
        let hashes = slots.map { $0.channel.stableHash }
        UserDefaults.standard.set(hashes, forKey: persistenceKey)
    }

    public func hasSavedConfiguration() -> Bool {
        let hashes = UserDefaults.standard.stringArray(forKey: persistenceKey) ?? []
        return !hashes.isEmpty
    }

    public func restoreLastConfiguration(engine: CndEngine, sources: [IptvSourceRecord] = []) async -> Int {
        guard let hashes = UserDefaults.standard.stringArray(forKey: persistenceKey), !hashes.isEmpty else {
            return 0
        }

        var restoredCount = 0
        for hash in hashes.prefix(maxAllowedSlots) {
            let filter = CatalogFilter(
                kind: "live",
                sourceId: nil,
                query: "",
                groupTitle: nil,
                host: nil,
                favoritesOnly: false,
                includeBroken: false,
                includeHidden: false,
                sortBy: .channelNumber,
                sortAsc: true,
                limit: 100,
                offset: 0
            )

            // Look up by querying catalog
            if let items = try? await Task.detached(priority: .userInitiated, operation: {
                try engine.queryCatalog(filter: filter)
            }).value, let matched = items.first(where: { $0.stableHash == hash }) {
                if addChannel(matched, sources: sources) {
                    restoredCount += 1
                }
            }
        }

        return restoredCount
    }
}
