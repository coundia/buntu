package com.pcoundia.buntu.core.domain.model

/**
 * PRD-27: what the player asks the engine for. The choice of titles and their order is made in Rust
 * (`CndEngine.recommendations_for`, `next_up`); Kotlin only displays the result.
 */
enum class UpNextContext {
    PLAYING,
    ENDING,
    LIVE,
}

/** Why the engine proposes a title (mirrors `RecommendationReasonKind` in `cnd-core`). */
enum class UpNextReason {
    SAGA_NEXT,
    SAGA_MEMBER,
    NEXT_EPISODE,
    SAME_DIRECTOR,
    SAME_ACTOR,
    SIMILAR_GENRE,
    RESUME,
    LIVE_NOW,
}

/** One title of the "À suivre" row or of the end-of-playback card. */
data class UpNextItem(
    val itemId: Long,
    val stableHash: String,
    val kind: StreamKind,
    val title: String,
    /** "S01E02", the year of a film, or the channel group. */
    val subtitle: String?,
    val posterUrl: String?,
    val reason: UpNextReason,
    /** Sentence written by the engine, shown as is ("Épisode suivant", "Film 3 sur 5 de la saga"…). */
    val reasonText: String,
    val alreadyWatched: Boolean,
    val resumePositionMs: Long,
    val durationMs: Long,
) {
    /** Share of the title already watched, for the card's progress bar. */
    val progressFraction: Float
        get() = if (!alreadyWatched && durationMs > 0L) {
            (resumePositionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
        } else {
            0f
        }
}

/** User choices for the player, like the "À suivre" section of the Apple settings. */
data class UpNextPreferences(
    /** "Afficher « À suivre » sous le lecteur". */
    val shelfEnabled: Boolean = true,
    /** "Carte « Film suivant » en fin de lecture". */
    val nextUpCardEnabled: Boolean = true,
    /** "Lecture automatique" after the countdown. */
    val autoPlayNext: Boolean = true,
    /** "Compte à rebours", in seconds. */
    val countdownSeconds: Int = DEFAULT_COUNTDOWN_SECONDS,
) {
    companion object {
        const val DEFAULT_COUNTDOWN_SECONDS = 10
        val COUNTDOWN_CHOICES = listOf(5, 10, 15, 20, 30)
    }
}
