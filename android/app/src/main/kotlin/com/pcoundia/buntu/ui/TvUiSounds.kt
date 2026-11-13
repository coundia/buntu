package com.pcoundia.buntu.ui

import android.view.KeyEvent
import android.view.SoundEffectConstants

/**
 * Navigation sounds of the Android TV app: the system's own sound effects (`View.playSoundEffect`), not sound
 * files. The system plays them only when the user left « Sons de navigation » on in the TV settings, so there is
 * nothing to load or decode and no setting of our own to keep.
 */
class TvUiSounds(
    private val playEffect: (Int) -> Unit,
    private val uptimeMillis: () -> Long,
) {
    private var lastPlayedAt = Long.MIN_VALUE

    /** The sound effect of a remote key, or `null` for a key that makes none (Back, media keys, digits…). */
    fun effectFor(keyCode: Int): Int? = when (keyCode) {
        KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> SoundEffectConstants.CLICK
        KeyEvent.KEYCODE_DPAD_UP -> SoundEffectConstants.NAVIGATION_UP
        KeyEvent.KEYCODE_DPAD_DOWN -> SoundEffectConstants.NAVIGATION_DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> SoundEffectConstants.NAVIGATION_LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> SoundEffectConstants.NAVIGATION_RIGHT
        else -> null
    }

    /** Called for each key press; a held arrow repeats several times a second, so sounds are spaced out. */
    fun onKeyDown(keyCode: Int) {
        val effect = effectFor(keyCode) ?: return
        val now = uptimeMillis()
        val gap = now - lastPlayedAt
        if (lastPlayedAt != Long.MIN_VALUE && gap in 0 until MIN_GAP_MS) return
        lastPlayedAt = now
        runCatching { playEffect(effect) }
    }

    companion object {
        const val MIN_GAP_MS = 80L
    }
}
