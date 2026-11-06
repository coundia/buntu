package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.EpisodeItem
import com.pcoundia.buntu.core.domain.model.MediaDetail
import javax.inject.Inject

/**
 * Single responsibility: pick the primary episode to watch or resume on a series detail page
 * ("Reprendre S01E03" or "Épisode suivant" or "Regarder S01E01").
 */
class NextEpisodeUseCase @Inject constructor() {
    operator fun invoke(detail: MediaDetail): EpisodeItem? {
        detail.nextEpisode?.let { return it }
        val inProgress = detail.episodes.firstOrNull { ep ->
            ep.watchPositionMs >= 30_000L &&
                (ep.watchDurationMs <= 0L || ep.watchPositionMs.toFloat() / ep.watchDurationMs < 0.92f)
        }
        if (inProgress != null) return inProgress

        val lastCompletedIdx = detail.episodes.indexOfLast { ep ->
            ep.watchDurationMs > 0L && ep.watchPositionMs.toFloat() / ep.watchDurationMs >= 0.92f
        }
        if (lastCompletedIdx in 0 until (detail.episodes.size - 1)) {
            return detail.episodes[lastCompletedIdx + 1]
        }
        return detail.episodes.firstOrNull()
    }
}

