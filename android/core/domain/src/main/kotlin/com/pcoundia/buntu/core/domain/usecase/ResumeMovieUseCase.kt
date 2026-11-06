package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.PlayableStream
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import javax.inject.Inject

/**
 * Single responsibility: start or resume a VOD film through the Rust single-connection relay
 * and coordinate single-connection download pausing.
 */
class ResumeMovieUseCase @Inject constructor(
    private val catalogRepository: CatalogRepository,
    private val settingsRepository: SettingsRepository,
    private val downloadsRepository: DownloadsRepository,
) {
    suspend operator fun invoke(movie: MovieItem, fromBeginning: Boolean = false): PlayableStream? {
        val resumeMs = if (!fromBeginning && movie.hasResumePoint) movie.watchPositionMs else 0L
        return launchById(movie.id, resumeMs)
    }

    suspend fun launchById(itemId: Long, startPositionMs: Long = 0L): PlayableStream? {
        val stream = catalogRepository.resolvePlayableStream(itemId, startPositionMs)
            ?: return null
        val prefs = settingsRepository.currentPreferences()
        if (minOf(prefs.assumedMaxConnections, stream.maxConnectionsForSource) <= 1) {
            downloadsRepository.pauseAllForPlayback()
        }
        return stream
    }
}

