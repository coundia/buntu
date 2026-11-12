//
//  RemotePlaybackCoordinator.swift
//  CndIptvKit
//
//  Cross-device playback coordinator ("Lire sur...", PRD-42).
//  Two-phase handoff, single stream enforcement, remote control, state reporting.
//
//  Safe by default: a request is refused unless this device is free, the content exists,
//  the active profile allows it and the access policy allows it. Devices of the same household trust
//  each other: a running playback is replaced without asking (the policy `alwaysAsk`, off by default,
//  still uses `onPromptRequest`; with no prompt handler it is refused).
//
//  Note: the protocol rules mirror `cnd-domain::remote::handoff` (Rust). The state machine itself is
//  not exported through UniFFI yet, so these rules are repeated here and must follow the Rust tests.
//

import Foundation
import Observation
import CndCoreBridge

public struct ActiveRemoteControlSession: Identifiable, Sendable {
    public var id: String { targetPeerId }
    public var targetPeerId: String
    public var targetPeerName: String
    public var contentKey: String
    public var title: String
    public var state: String
    public var positionMs: UInt64
    public var durationMs: UInt64
    public var lastUpdate: Date
}

/// Who may start a playback on this device (PRD-42 § 5.3).
public enum RemoteAccessPolicy: String, Sendable {
    case open
    case alwaysAsk = "always_ask"
    case disabled
}

/// What the local player reports, so the position is measured, never guessed.
public struct LocalPlaybackSnapshot: Sendable {
    public var state: String       // "loading" | "playing" | "paused"
    public var positionMs: UInt64
    public var durationMs: UInt64
    public init(state: String, positionMs: UInt64, durationMs: UInt64) {
        self.state = state
        self.positionMs = positionMs
        self.durationMs = durationMs
    }
}

@Observable
public final class RemotePlaybackCoordinator: @unchecked Sendable {
    public static let shared = RemotePlaybackCoordinator()

    public private(set) var activeRemoteSession: ActiveRemoteControlSession?
    public private(set) var isInitiatingHandoff: Bool = false
    public private(set) var handoffStatusMessage: String?

    // Hooks to the app's player (set once at start-up). Called on the main thread.
    public var onStreamInterruptedByPeer: (@Sendable (_ sourceKey: String) -> Void)?
    public var onRequestLocalPlay: (@Sendable (_ item: IptvItemRecord, _ positionMs: UInt64) -> Void)?
    public var onStopLocalPlay: (@Sendable () -> Void)?
    /// Measured state of the local player (position at the very moment of the call).
    public var localPlaybackSnapshot: (@Sendable () -> LocalPlaybackSnapshot?)?
    /// `false` when the active profile (Kids) must not play this item.
    public var isItemAllowedForActiveProfile: (@Sendable (_ item: IptvItemRecord) -> Bool)?
    /// Asks the user of THIS device. Calls `answer(true)` to accept, `answer(false)` to decline.
    /// Without a handler, every request that needs an answer is refused.
    public var onPromptRequest: (@Sendable (_ title: String?, _ senderName: String, _ answer: @escaping @Sendable (Bool) -> Void) -> Void)?
    /// Remote control orders received while playing here (pause, seek, stop…).
    public var onRemoteControl: (@Sendable (_ action: String, _ value: Int64?) -> Void)?
    public var accessPolicy: RemoteAccessPolicy = .open

    private var localSync: LocalSyncService?
    private var engine: CndEngine?

    // Origin side
    private var pendingRequestId: String?
    private var pendingTargetPeerId: String?
    private var pendingContentKey: String?
    /// Position asked by the caller: used when nothing plays here (menu "Lire sur un autre appareil").
    private var pendingPositionMs: UInt64 = 0
    private var handedOffTargetId: String?
    private var handedOffContentKey: String?
    private var handedOffPositionMs: UInt64 = 0
    private var handedOffAt: Date?
    private var handoffTimer: Timer?
    private var pullRequestId: String?

    // Target side
    private struct IncomingReservation {
        var requestId: String
        var item: IptvItemRecord
        var sourceKey: String?
        var senderId: String
        var reservedAt: Date
    }
    private var reservation: IncomingReservation?
    private var lastRequestAtBySender: [String: Date] = [:]
    private var stateSubscriberId: String?

    // Local playback tracking
    private var currentLocalContentKey: String?
    private var currentLocalSourceKey: String?
    private var currentLocalTitle: String?
    private var stateBroadcastTimer: Timer?

    public init() {}

    /// `true` once the household sync is running on this device (the menu entry is hidden otherwise).
    public var isHouseholdActive: Bool { localSync != nil }

    /// Household devices that can play and are reachable right now.
    public var availablePeers: [DiscoveredPeer] {
        (localSync?.activePeers ?? []).filter { $0.canPlay }
    }

    public func configure(localSync: LocalSyncService, engine: CndEngine?) {
        self.localSync = localSync
        self.engine = engine
        setupCallbacks(localSync)
    }

    private func setupCallbacks(_ sync: LocalSyncService) {
        sync.onPlayReady = { [weak self] reqId in self?.handlePlayReady(reqId) }
        sync.onPlayRefused = { [weak self] reqId, reason in self?.handlePlayRefused(reqId, reason: reason) }
        sync.onPlayRequest = { [weak self] req, sender in self?.handleIncomingPlayRequest(req, senderId: sender) }
        sync.onPlayGo = { [weak self] reqId, pos in self?.handleIncomingPlayGo(reqId, positionMs: pos) }
        sync.onPlaybackState = { [weak self] state in self?.handleIncomingPlaybackState(state) }
        sync.onPlaybackControl = { [weak self] action, value in self?.onRemoteControl?(action, value) }
        sync.onReleaseStream = { [weak self] sourceKey in self?.handleReleaseStream(sourceKey) }
        sync.onReleaseRequest = { [weak self] reqId, sender in self?.handleReleaseRequest(reqId, senderId: sender) }
        sync.onReleaseDone = { [weak self] reqId, contentKey, pos in
            self?.handleReleaseDone(reqId, contentKey: contentKey, positionMs: pos)
        }
    }

    // MARK: - Tracking of local playback

    public func setLocalPlaybackActive(item: IptvItemRecord?, sourceKey: String?) {
        setLocalPlaybackActive(contentKey: item?.stableHash, title: item?.name, sourceKey: sourceKey)
    }

    /// Tells the coordinator what this device plays (`contentKey` nil = nothing), so that it can report
    /// the state, answer "rends-moi la lecture" and apply the one-stream-per-account rule.
    public func setLocalPlaybackActive(contentKey: String?, title: String?, sourceKey: String?) {
        if let contentKey {
            currentLocalContentKey = contentKey
            currentLocalSourceKey = sourceKey
            currentLocalTitle = title
            if stateSubscriberId != nil { startStateBroadcast() }
        } else {
            let hadSubscriber = stateSubscriberId
            let key = currentLocalContentKey
            let title = currentLocalTitle
            currentLocalContentKey = nil
            currentLocalSourceKey = nil
            currentLocalTitle = nil
            stopStateBroadcast()
            // Tell the controller that the playback is over (it would otherwise wait forever).
            if let hadSubscriber, let key {
                sendState(to: hadSubscriber, contentKey: key, title: title, state: "ended", position: 0, duration: 0)
            }
            stateSubscriberId = nil
        }
    }

    // MARK: - Origin: "Lire sur…"

    public func startRemotePlayback(
        targetPeer: DiscoveredPeer,
        item: IptvItemRecord,
        positionMs: UInt64,
        sourceKey: String?
    ) {
        // The target does not know this device's item hash (it depends on the local account id): it finds
        // the item by the provider's stream id in the account named by its key (PRD-42 § 6).
        let providerRef = URL(string: item.streamUrl).flatMap(Self.providerRef(from:))
        let send: @Sendable (String?) -> Void = { [weak self] key in
            guard let coordinator = self else { return }
            coordinator.onMain {
                coordinator.startRemotePlayback(
                    targetPeer: targetPeer, contentKey: item.stableHash, kind: item.kind,
                    title: item.name, positionMs: positionMs, sourceKey: key, providerRef: providerRef
                )
            }
        }
        if let sourceKey {
            send(sourceKey)
        } else {
            // Reading the accounts is a database call: off the main thread (AGENTS.md § 3.4).
            let engine = self.engine
            let sourceId = item.sourceId
            Task.detached(priority: .userInitiated) { send(Self.accountKey(engine: engine, sourceId: sourceId)) }
        }
    }

    /// Sends what is playing here to `targetPeer`. Nothing is stopped here until the target answers
    /// `play_ready`; then this device stops (one stream at the provider) and the target starts at the
    /// position measured at that very moment.
    public func startRemotePlayback(
        targetPeer: DiscoveredPeer,
        contentKey: String,
        kind: String,
        title: String,
        positionMs: UInt64,
        sourceKey: String?,
        providerRef: String? = nil
    ) {
        guard let localSync, !isInitiatingHandoff else { return }

        let reqId = "req_\(UUID().uuidString.prefix(8))"
        pendingRequestId = reqId
        pendingTargetPeerId = targetPeer.id
        pendingContentKey = contentKey
        pendingPositionMs = positionMs
        isInitiatingHandoff = true
        handoffStatusMessage = "Connexion à \(targetPeer.name)…"

        var dict: [String: Any] = [
            "type": "play_request",
            "target_device_id": targetPeer.id,
            "request_id": reqId,
            "content_key": contentKey,
            "item_kind": kind,
            "title": title,
            "position_ms": positionMs,
            "replace": true
        ]
        if let sourceKey { dict["source_key"] = sourceKey }
        if let providerRef { dict["provider_ref"] = providerRef }

        guard let json = Self.json(dict), localSync.sendToPeer(peerId: targetPeer.id, messageJson: json) else {
            clearPending()
            handoffStatusMessage = "\(targetPeer.name) n'est pas joignable"
            return
        }

        // 5-second timeout (PRD-42 § 3.2): the local playback is untouched until `play_ready`.
        onMain {
            self.handoffTimer?.invalidate()
            self.handoffTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.handleHandoffTimeout()
            }
        }
    }

    private func handlePlayReady(_ requestId: String) {
        guard requestId == pendingRequestId, let peerId = pendingTargetPeerId, let localSync else { return }
        onMain { self.handoffTimer?.invalidate() }

        // Position measured NOW, just before the local stream is stopped (PRD-42 § 3.2).
        let snapshot = localPlaybackSnapshot?()
        let finalPosition = snapshot?.positionMs ?? pendingPositionMs
        let key = pendingContentKey

        // One single stream at the provider: stop here BEFORE telling the target to go.
        onStopLocalPlay?()

        let goDict: [String: Any] = [
            "type": "play_go",
            "request_id": requestId,
            "position_ms": finalPosition
        ]
        if let json = Self.json(goDict) {
            localSync.sendToPeer(peerId: peerId, messageJson: json)
        }

        handedOffTargetId = peerId
        handedOffContentKey = key
        handedOffPositionMs = finalPosition
        handedOffAt = Date()
        clearPending()
        handoffStatusMessage = nil
    }

    private func handlePlayRefused(_ requestId: String, reason: String) {
        guard requestId == pendingRequestId else { return }
        onMain { self.handoffTimer?.invalidate() }
        clearPending()
        handoffStatusMessage = Self.refusalMessage(reason)
    }

    private func handleHandoffTimeout() {
        guard isInitiatingHandoff else { return }
        clearPending()
        handoffStatusMessage = "Délai dépassé : l'appareil cible n'a pas répondu"
    }

    private func clearPending() {
        pendingRequestId = nil
        pendingTargetPeerId = nil
        pendingContentKey = nil
        isInitiatingHandoff = false
    }

    // MARK: - Target: incoming request

    private func handleIncomingPlayRequest(_ req: PlayRequestDTO, senderId: String) {
        guard let engine else { return }

        func refuse(_ reason: String) { sendRefused(req.request_id, reason: reason, to: senderId) }

        // Rate limit: 1 request every 2 s per sender (PRD-42 § 5.2).
        let now = Date()
        if let last = lastRequestAtBySender[senderId], now.timeIntervalSince(last) < 2.0 {
            refuse("rate_limited")
            return
        }
        lastRequestAtBySender[senderId] = now

        if accessPolicy == .disabled { refuse("not_allowed"); return }

        // A pending handoff of someone else must not be stolen.
        if let held = reservation, held.requestId != req.request_id, now.timeIntervalSince(held.reservedAt) <= 10 {
            refuse("busy")
            return
        }

        let item = try? engine.itemByContentKey(
            contentKey: req.content_key,
            sourceKey: req.source_key,
            providerRef: req.provider_ref,
            itemKind: req.item_kind
        )
        guard let resolved = item else { refuse("unknown_content"); return }

        if let allowed = isItemAllowedForActiveProfile, !allowed(resolved) {
            refuse("kids_restricted")
            return
        }

        let senderName = localSync?.activePeers.first(where: { $0.id == senderId })?.name ?? "Un appareil du foyer"
        // Same household: the current stream is stopped and replaced without a confirmation.
        let needsAnswer = accessPolicy == .alwaysAsk

        if needsAnswer {
            guard let prompt = onPromptRequest else {
                refuse("not_allowed")
                return
            }
            prompt(req.title, senderName) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.reserve(requestId: req.request_id, item: resolved, sourceKey: req.source_key, senderId: senderId)
                } else {
                    self.sendRefused(req.request_id, reason: "declined_by_user", to: senderId)
                }
            }
            return
        }

        reserve(requestId: req.request_id, item: resolved, sourceKey: req.source_key, senderId: senderId)
    }

    private func reserve(requestId: String, item: IptvItemRecord, sourceKey: String?, senderId: String) {
        reservation = IncomingReservation(
            requestId: requestId, item: item, sourceKey: sourceKey, senderId: senderId, reservedAt: Date()
        )
        if let json = Self.json(["type": "play_ready", "request_id": requestId]) {
            localSync?.sendToPeer(peerId: senderId, messageJson: json)
        }
    }

    private func sendRefused(_ requestId: String, reason: String, to senderId: String) {
        if let json = Self.json(["type": "play_refused", "request_id": requestId, "reason": reason]) {
            localSync?.sendToPeer(peerId: senderId, messageJson: json)
        }
    }

    private func handleIncomingPlayGo(_ requestId: String, positionMs: UInt64) {
        guard let held = reservation, held.requestId == requestId, let localSync else { return }
        reservation = nil
        // The reservation lives 10 s; after that the origin had given up.
        guard Date().timeIntervalSince(held.reservedAt) <= 10 else { return }

        // Everybody else stops streaming THIS account (PRD-42 § 3.4): the key is the incoming one,
        // not the one of whatever this device was playing before.
        if let sourceKey = held.sourceKey, let json = Self.json(["type": "release_stream", "source_key": sourceKey]) {
            localSync.broadcastMessage(json)
        }

        stateSubscriberId = held.senderId
        onRequestLocalPlay?(held.item, positionMs)
        startStateBroadcast()
    }

    // MARK: - Single stream rule

    private func handleReleaseStream(_ sourceKey: String) {
        guard let current = currentLocalSourceKey else { return }
        let a = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.caseInsensitiveCompare(b) == .orderedSame {
            onStopLocalPlay?()
            onStreamInterruptedByPeer?(sourceKey)
        }
    }

    // MARK: - "Reprendre ici"

    public func pullPlaybackHere() {
        guard let session = activeRemoteSession, let localSync else { return }
        let reqId = "req_pull_\(UUID().uuidString.prefix(8))"
        pullRequestId = reqId
        let dict: [String: Any] = [
            "type": "release_request",
            "target_device_id": session.targetPeerId,
            "request_id": reqId
        ]
        if let json = Self.json(dict), !localSync.sendToPeer(peerId: session.targetPeerId, messageJson: json) {
            pullRequestId = nil
            handoffStatusMessage = "\(session.targetPeerName) n'est pas joignable"
        }
    }

    private func handleReleaseRequest(_ requestId: String, senderId: String) {
        // Measured position first, then stop.
        let snapshot = localPlaybackSnapshot?()
        let key = currentLocalContentKey
        onStopLocalPlay?()

        var dict: [String: Any] = [
            "type": "release_done",
            "request_id": requestId,
            "position_ms": snapshot?.positionMs ?? 0
        ]
        if let key { dict["content_key"] = key }
        if let json = Self.json(dict) {
            localSync?.sendToPeer(peerId: senderId, messageJson: json)
        }
    }

    private func handleReleaseDone(_ requestId: String, contentKey: String?, positionMs: UInt64) {
        guard requestId == pullRequestId, let session = activeRemoteSession, let engine else { return }
        pullRequestId = nil
        let key = contentKey ?? session.contentKey
        activeRemoteSession = nil
        handedOffTargetId = nil

        if let item = try? engine.itemByContentKey(contentKey: key, sourceKey: nil, providerRef: nil, itemKind: nil) {
            onRequestLocalPlay?(item, positionMs)
        } else {
            handoffStatusMessage = "Contenu introuvable sur cet appareil"
        }
    }

    // MARK: - Remote controls (controller side)

    public func sendPlaybackControl(action: String, value: Int64? = nil) {
        guard let session = activeRemoteSession, let localSync else { return }
        var dict: [String: Any] = [
            "type": "playback_control",
            "target_device_id": session.targetPeerId,
            "action": action
        ]
        if let value { dict["value"] = value }
        if let json = Self.json(dict) {
            localSync.sendToPeer(peerId: session.targetPeerId, messageJson: json)
        }
    }

    private func handleIncomingPlaybackState(_ state: PlaybackStateDTO) {
        // Only follow the device we handed the playback to, never any device that plays by itself.
        guard state.device_id == handedOffTargetId || state.device_id == activeRemoteSession?.targetPeerId else { return }

        Task { @MainActor in
            if state.state == "ended" {
                self.activeRemoteSession = nil
                self.handedOffTargetId = nil
                return
            }
            if state.state == "error" {
                // The target could not play: keep the session so "Reprendre ici" is one tap away.
                self.handoffStatusMessage = "La lecture a échoué sur l'autre appareil"
            }
            let name = self.localSync?.activePeers.first(where: { $0.id == state.device_id })?.name ?? "l'autre appareil"
            self.activeRemoteSession = ActiveRemoteControlSession(
                targetPeerId: state.device_id,
                targetPeerName: name,
                contentKey: state.content_key ?? self.handedOffContentKey ?? "",
                title: state.title ?? "Média distant",
                state: state.state,
                positionMs: state.position_ms,
                durationMs: state.duration_ms,
                lastUpdate: Date()
            )
        }
    }

    // MARK: - 1 s state report (target side → controller only)

    private func startStateBroadcast() {
        stopStateBroadcast()
        onMain {
            self.stateBroadcastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.reportState()
            }
        }
        reportState()
    }

    private func stopStateBroadcast() {
        onMain {
            self.stateBroadcastTimer?.invalidate()
            self.stateBroadcastTimer = nil
        }
    }

    private func reportState() {
        guard let subscriber = stateSubscriberId, let key = currentLocalContentKey else { return }
        let snap = localPlaybackSnapshot?()
        sendState(
            to: subscriber,
            contentKey: key,
            title: currentLocalTitle,
            state: snap?.state ?? "loading",
            position: snap?.positionMs ?? 0,
            duration: snap?.durationMs ?? 0
        )
    }

    private func sendState(to peerId: String, contentKey: String, title: String?, state: String, position: UInt64, duration: UInt64) {
        guard let localSync else { return }
        var dict: [String: Any] = [
            "type": "playback_state",
            "device_id": localSync.localDeviceId,
            "content_key": contentKey,
            "state": state,
            "position_ms": position,
            "duration_ms": duration,
            "controls": ["pause", "resume", "seek_to", "seek_by", "stop"]
        ]
        if let title { dict["title"] = title }
        if let json = Self.json(dict) {
            localSync.sendToPeer(peerId: peerId, messageJson: json)
        }
    }

    // MARK: - Helpers

    /// The provider's own id of a stream (`…/12345.mkv` → `12345`), so another device that added the same
    /// account by itself (its catalog ids differ) can find the content. Only this id leaves the device:
    /// never the URL, which carries the account's name and password. `nil` when it does not look like an id.
    /// `source_key` of a local account (PRD-41 identity, computed in Rust), `nil` when unknown.
    private static func accountKey(engine: CndEngine?, sourceId: Int64) -> String? {
        guard let source = (try? engine?.listSources())??.first(where: { $0.id == sourceId }) else { return nil }
        return syncComputeSourceKey(
            sourceType: source.sourceType, serverOrUrl: source.server ?? source.url ?? "", username: source.username
        )
    }

    public static func providerRef(from url: URL) -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let last = url.deletingPathExtension().lastPathComponent
        guard !last.isEmpty, last.count <= 40,
              last.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return last
    }

    private func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func json(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func refusalMessage(_ reason: String) -> String {
        switch reason {
        case "unknown_content": return "L'autre appareil n'a pas ce contenu (mettez à jour sa playlist)"
        case "source_missing": return "Le compte n'existe pas sur l'autre appareil"
        case "busy": return "L'autre appareil est déjà en lecture"
        case "kids_restricted": return "Contenu non autorisé pour le profil Enfants de l'autre appareil"
        case "declined_by_user": return "Refusé sur l'autre appareil"
        case "not_allowed": return "L'autre appareil n'accepte pas les lectures à distance"
        case "app_not_ready": return "Buntu démarre sur l'autre appareil, réessayez"
        case "rate_limited": return "Trop de demandes, réessayez dans un instant"
        default: return "Lecture refusée par l'autre appareil"
        }
    }
}
