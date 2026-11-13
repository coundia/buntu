package com.pcoundia.buntu.core.domain.usecase

/**
 * PRD-27: when the player shows the end-of-playback card, with the same values as Apple
 * (`UpNextModel.onPlaybackProgress` and `startCountdown` in `apple/.../Recommendations/UpNextModel.swift`).
 *
 * Only display timing lives here. The choice of the next title is made in Rust (`CndEngine.next_up`).
 */
object NextUpTiming {
    /** The card appears in the last 3 % of the title, at most 4 minutes before the end. */
    private const val MAX_LEAD_MS = 240_000L
    private const val LEAD_FRACTION = 0.03

    /** After this many titles chained without a touch, the player asks "Êtes-vous toujours là ?". */
    const val MAX_AUTO_CHAIN = 3

    /** Playback speeds offered by the player menu (same list as Apple `CndVideoPlayerView.speeds`). */
    val PLAYBACK_SPEEDS: List<Float> = listOf(0.5f, 1.0f, 1.25f, 1.5f, 2.0f)

    fun isNearEnd(positionMs: Long, durationMs: Long): Boolean {
        if (durationMs <= 0L) return false
        val remainingMs = (durationMs - positionMs).coerceAtLeast(0L)
        val thresholdMs = minOf(MAX_LEAD_MS, (durationMs * LEAD_FRACTION).toLong())
        return remainingMs <= thresholdMs
    }

    /** "1x", "1.25x"… as on Apple. */
    fun speedLabel(speed: Float): String =
        if (speed == speed.toInt().toFloat()) "${speed.toInt()}x" else "${speed}x"
}
