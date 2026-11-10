package com.pcoundia.buntu.core.domain.repository

import com.pcoundia.buntu.core.domain.model.ActiveRemoteControlSession
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.IncomingPlayInstruction
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Cross-device playback coordinator ("Lire sur un autre appareil", PRD-42 & PRD-44).
 * Enforces two-phase handoff (play_request -> play_ready -> play_go), single stream per account rule,
 * and remote control.
 */
interface RemotePlaybackRepository {
    val availablePeers: StateFlow<List<DiscoveredPeer>>
    val isHouseholdActive: StateFlow<Boolean>
    val activeHandoffStatus: StateFlow<String?>
    val activeRemoteSession: StateFlow<ActiveRemoteControlSession?>
    val incomingPlayInstructions: SharedFlow<IncomingPlayInstruction>
    val streamInterruptedByPeer: SharedFlow<String>

    suspend fun startHandoff(
        targetPeerId: String,
        contentKey: String,
        sourceKey: String?,
        itemKind: String,
        providerRef: String?,
        title: String?,
        positionMs: Long,
    ): Boolean

    /**
     * Context menu « Lire sur un autre appareil » (PRD-44 § 2.2): sends a local item by id; a movie or an
     * episode starts at its resume position, a channel live. `false` when refused, unreachable or not playable.
     */
    /** Forgets the last handoff message (before opening the device list again). */
    fun clearHandoffStatus()

    suspend fun startHandoffForItem(targetPeerId: String, itemId: Long): Boolean

    /** `source_key` of the account of [itemId] (computed in Rust), `null` if unknown. */
    suspend fun sourceKeyForItem(itemId: Long): String?

    suspend fun sendPlaybackControl(targetPeerId: String, action: String, value: Long?)
    fun setLocalPlaybackActive(contentKey: String?, title: String?, sourceKey: String?)
    fun onLocalPlaybackStopped()
}

