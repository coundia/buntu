package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import javax.inject.Inject

/**
 * Single responsibility: zap to a target/adjacent/numbered Live TV channel,
 * persist last watched channel, and pause downloads if subscription is single-connection.
 */
class ZapToChannelUseCase @Inject constructor(
    private val catalogRepository: CatalogRepository,
    private val settingsRepository: SettingsRepository,
    private val downloadsRepository: DownloadsRepository,
) {
    suspend fun byId(channelId: Long): PlayableStream? {
        val stream = catalogRepository.resolvePlayableStream(channelId, startPositionMs = 0L)
            ?: return null
        onChannelActivated(channelId, stream.maxConnectionsForSource)
        return stream
    }

    suspend fun adjacent(currentChannelId: Long, delta: Int, groupName: String? = null): PlayableStream? {
        val next = catalogRepository.getAdjacentChannel(currentChannelId, delta, groupName)
            ?: return null
        return byId(next.id)
    }

    suspend fun byNumber(channelNumber: Int): PlayableStream? {
        val channel = catalogRepository.getChannelByNumber(channelNumber) ?: return null
        return byId(channel.id)
    }

    private suspend fun onChannelActivated(channelId: Long, maxConnections: Int) {
        settingsRepository.setLastChannelId(channelId)
        val prefs = settingsRepository.currentPreferences()
        if (minOf(prefs.assumedMaxConnections, maxConnections) <= 1) {
            downloadsRepository.pauseAllForPlayback()
        }
    }
}

