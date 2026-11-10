package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.playbackTargets
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import javax.inject.Inject

/**
 * Context menu « Lire sur un autre appareil » of the catalog cards (PRD-44 § 2.2, lot 44.5), shared by
 * the movies, series, live and recommendations screens. The protocol itself lives in
 * [RemotePlaybackRepository] (two-phase handoff, one stream per account).
 */
class PlayOnAnotherDeviceUseCase @Inject constructor(
    private val remotePlayback: RemotePlaybackRepository,
) {
    /** Household devices that can receive a playback now. */
    val devices: Flow<List<DiscoveredPeer>> = remotePlayback.availablePeers.map { it.playbackTargets() }

    /** "Connexion à …", "Refusé : …", or `null`. */
    val status: StateFlow<String?> = remotePlayback.activeHandoffStatus

    fun reset() = remotePlayback.clearHandoffStatus()

    /** `true` once the target accepted and was told to start. */
    suspend operator fun invoke(targetDeviceId: String, itemId: Long): Boolean =
        remotePlayback.startHandoffForItem(targetDeviceId, itemId)
}
