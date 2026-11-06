package com.pcoundia.buntu.core.player

import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * PRD-37 § 6 (37.6) & § 8:
 * Exposes a `MediaSession` for lock-screen controls, notifications, Bluetooth headsets,
 * and Android TV hardware media keys.
 */
@AndroidEntryPoint
class BuntuPlaybackService : MediaSessionService() {

    @Inject
    lateinit var exoEngine: ExoPlayerVideoEngine

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        mediaSession = MediaSession.Builder(this, exoEngine.exoPlayer).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onDestroy() {
        mediaSession?.run {
            release()
            mediaSession = null
        }
        super.onDestroy()
    }
}

