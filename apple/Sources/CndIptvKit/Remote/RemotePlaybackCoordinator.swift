//
//  RemotePlaybackCoordinator.swift
//  CndIptvKit
//
//  Cross-device playback coordinator ("Lire sur...", PRD-42).
//  Implements two-phase handoff, single stream enforcement, remote control, and state broadcasting.
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

@Observable
public final class RemotePlaybackCoordinator: @unchecked Sendable {
    public static let shared = RemotePlaybackCoordinator()

    public private(set) var activeRemoteSession: ActiveRemoteControlSession?
    public private(set) var isInitiatingHandoff: Bool = false
    public private(set) var handoffStatusMessage: String?
    public var onStreamInterruptedByPeer: (@Sendable (_ sourceKey: String) -> Void)?
    public var onRequestLocalPlay: (@Sendable (_ item: IptvItemRecord, _ positionMs: UInt64) -> Void)?
    public var onStopLocalPlay: (@Sendable () -> Void)?

    private var localSync: LocalSyncService?
    private var engine: CndEngine?
    private var pendingRequestId: String?
    private var pendingTargetPeerId: String?
    private var pendingHandoffPositionMs: UInt64 = 0
    private var handoffTimer: Timer?

    private var currentLocalContentKey: String?
    private var currentLocalSourceKey: String?
    private var currentLocalTitle: String?
    private var stateBroadcastTimer: Timer?

    public init() {}

    public func configure(localSync: LocalSyncService, engine: CndEngine?) {
        self.localSync = localSync
        self.engine = engine
        setupCallbacks(localSync)
    }

    private func setupCallbacks(_ sync: LocalSyncService) {
        sync.onPlayReady = { [weak self] reqId in
            self?.handlePlayReady(reqId)
        }

        sync.onPlayRefused = { [weak self] reqId, reason in
            self?.handlePlayRefused(reqId, reason: reason)
        }

        sync.onPlayRequest = { [weak self] req in
            self?.handleIncomingPlayRequest(req)
        }

        sync.onPlayGo = { [weak self] reqId, pos in
            self?.handleIncomingPlayGo(reqId, positionMs: pos)
        }

        sync.onPlaybackState = { [weak self] state in
            self?.handleIncomingPlaybackState(state)
        }

        sync.onReleaseStream = { [weak self] sourceKey in
            self?.handleReleaseStream(sourceKey)
        }

        sync.onReleaseRequest = { [weak self] reqId in
            self?.handleReleaseRequest(reqId)
        }

        sync.onReleaseDone = { [weak self] reqId, contentKey, pos in
            self?.handleReleaseDone(reqId, contentKey: contentKey, positionMs: pos)
        }
    }

    // MARK: - State & Tracking of Local Playback

    public func setLocalPlaybackActive(item: IptvItemRecord?, sourceKey: String?) {
        if let item {
            currentLocalContentKey = item.stableHash
            currentLocalSourceKey = sourceKey
            currentLocalTitle = item.name
            startStateBroadcast()
        } else {
            currentLocalContentKey = nil
            currentLocalSourceKey = nil
            currentLocalTitle = nil
            stopStateBroadcast()
        }
    }

    // MARK: - Origin Handoff ("Lire sur...")

    public func startRemotePlayback(
        targetPeer: DiscoveredPeer,
        item: IptvItemRecord,
        positionMs: UInt64,
        sourceKey: String?
    ) {
        guard let localSync else { return }

        let reqId = "req_\(UUID().uuidString.prefix(8))"
        pendingRequestId = reqId
        pendingTargetPeerId = targetPeer.id
        pendingHandoffPositionMs = positionMs
        isInitiatingHandoff = true
        handoffStatusMessage = "Connexion à \(targetPeer.name)..."

        let dict: [String: Any] = [
            "type": "play_request",
            "target_device_id": targetPeer.id,
            "request_id": reqId,
            "content_key": item.stableHash,
            "source_key": sourceKey as Any,
            "item_kind": item.kind,
            "title": item.name,
            "position_ms": positionMs,
            "replace": true
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            localSync.sendToPeer(peerId: targetPeer.id, messageJson: json)
        }

        // 5-second timeout (PRD-42 § 3.2)
        handoffTimer?.invalidate()
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.handleHandoffTimeout()
        }
    }

    private func handlePlayReady(_ requestId: String) {
        guard requestId == pendingRequestId, let peerId = pendingTargetPeerId, let localSync else { return }
        handoffTimer?.invalidate()

        // Stop local playback before sending PlayGo (PRD-42 § 3.2: 1 seul flux chez le fournisseur)
        onStopLocalPlay?()

        let goDict: [String: Any] = [
            "type": "play_go",
            "request_id": requestId,
            "position_ms": pendingHandoffPositionMs
        ]

        if let data = try? JSONSerialization.data(withJSONObject: goDict),
           let json = String(data: data, encoding: .utf8) {
            localSync.sendToPeer(peerId: peerId, messageJson: json)
        }

        isInitiatingHandoff = false
        handoffStatusMessage = nil
    }

    private func handlePlayRefused(_ requestId: String, reason: String) {
        guard requestId == pendingRequestId else { return }
        handoffTimer?.invalidate()
        isInitiatingHandoff = false
        handoffStatusMessage = "Lecture refusée par la cible (\(reason))"
    }

    private func handleHandoffTimeout() {
        guard isInitiatingHandoff else { return }
        isInitiatingHandoff = false
        handoffStatusMessage = "Délai dépassé : l'appareil cible n'a pas répondu"
    }

    // MARK: - Target Handoff (Receiving Request)

    private func handleIncomingPlayRequest(_ req: PlayRequestDTO) {
        guard let localSync, let engine else { return }

        // Find item in engine
        let item = try? engine.itemByContentKey(
            contentKey: req.content_key,
            sourceKey: req.source_key,
            providerRef: req.provider_ref
        )

        guard let resolved = item else {
            // Content not found
            let refDict: [String: Any] = [
                "type": "play_refused",
                "request_id": req.request_id,
                "reason": "unknown_content"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: refDict),
               let json = String(data: data, encoding: .utf8) {
                localSync.broadcastMessage(json)
            }
            return
        }

        // Ready
        let readyDict: [String: Any] = [
            "type": "play_ready",
            "request_id": req.request_id
        ]
        if let data = try? JSONSerialization.data(withJSONObject: readyDict),
           let json = String(data: data, encoding: .utf8) {
            localSync.broadcastMessage(json)
        }

        self.pendingIncomingItem = resolved
    }

    private var pendingIncomingItem: IptvItemRecord?

    private func handleIncomingPlayGo(_ requestId: String, positionMs: UInt64) {
        guard let item = pendingIncomingItem, let localSync else { return }
        pendingIncomingItem = nil

        // Broadcast release_stream so no other device continues streaming this source (PRD-42 § 3.4)
        if let sourceKey = currentLocalSourceKey {
            let relDict: [String: Any] = [
                "type": "release_stream",
                "source_key": sourceKey
            ]
            if let data = try? JSONSerialization.data(withJSONObject: relDict),
               let json = String(data: data, encoding: .utf8) {
                localSync.broadcastMessage(json)
            }
        }

        onRequestLocalPlay?(item, positionMs)
    }

    // MARK: - Single Stream Rule (release_stream)

    private func handleReleaseStream(_ sourceKey: String) {
        guard let current = currentLocalSourceKey else { return }
        if current.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            onStopLocalPlay?()
            onStreamInterruptedByPeer?(sourceKey)
        }
    }

    // MARK: - Rapatrier ("Reprendre ici")

    public func pullPlaybackHere() {
        guard let session = activeRemoteSession, let localSync else { return }

        let reqId = "req_pull_\(UUID().uuidString.prefix(8))"
        let dict: [String: Any] = [
            "type": "release_request",
            "target_device_id": session.targetPeerId,
            "request_id": reqId
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            localSync.sendToPeer(peerId: session.targetPeerId, messageJson: json)
        }
    }

    private func handleReleaseRequest(_ requestId: String) {
        guard let localSync else { return }
        onStopLocalPlay?()

        let doneDict: [String: Any] = [
            "type": "release_done",
            "request_id": requestId,
            "content_key": currentLocalContentKey as Any,
            "position_ms": 0 // current position can be hooked if local player provides it
        ]
        if let data = try? JSONSerialization.data(withJSONObject: doneDict),
           let json = String(data: data, encoding: .utf8) {
            localSync.broadcastMessage(json)
        }
    }

    private func handleReleaseDone(_ requestId: String, contentKey: String?, positionMs: UInt64) {
        guard let session = activeRemoteSession, let engine, let cKey = contentKey ?? session.contentKey as String? else { return }
        activeRemoteSession = nil

        if let item = try? engine.itemByContentKey(contentKey: cKey, sourceKey: nil, providerRef: nil) {
            onRequestLocalPlay?(item, positionMs)
        }
    }

    // MARK: - Remote Controls

    public func sendPlaybackControl(action: String, value: Int64? = nil) {
        guard let session = activeRemoteSession, let localSync else { return }

        var dict: [String: Any] = [
            "type": "playback_control",
            "target_device_id": session.targetPeerId,
            "action": action
        ]
        if let value { dict["value"] = value }

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            localSync.sendToPeer(peerId: session.targetPeerId, messageJson: json)
        }
    }

    private func handleIncomingPlaybackState(_ state: PlaybackStateDTO) {
        Task { @MainActor in
            self.activeRemoteSession = ActiveRemoteControlSession(
                targetPeerId: state.device_id,
                targetPeerName: "Salon TV",
                contentKey: state.content_key ?? "",
                title: state.title ?? "Média distant",
                state: state.state,
                positionMs: state.position_ms,
                durationMs: state.duration_ms,
                lastUpdate: Date()
            )
        }
    }

    // MARK: - 1s State Broadcast

    private func startStateBroadcast() {
        stopStateBroadcast()
        stateBroadcastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.broadcastState()
        }
    }

    private func stopStateBroadcast() {
        stateBroadcastTimer?.invalidate()
        stateBroadcastTimer = nil
    }

    private func broadcastState() {
        guard let localSync, let cKey = currentLocalContentKey else { return }

        let dict: [String: Any] = [
            "type": "playback_state",
            "device_id": localSync.activePeers.first?.id ?? "apple_device",
            "content_key": cKey,
            "title": currentLocalTitle as Any,
            "state": "playing",
            "position_ms": 0,
            "duration_ms": 0,
            "controls": ["pause", "resume", "seek_to", "seek_by", "stop"]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            localSync.broadcastMessage(json)
        }
    }
}
