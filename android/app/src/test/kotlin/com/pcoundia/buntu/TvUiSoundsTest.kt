package com.pcoundia.buntu

import android.view.KeyEvent
import android.view.SoundEffectConstants
import com.pcoundia.buntu.ui.TvUiSounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TvUiSoundsTest {
    private val played = mutableListOf<Int>()
    private var now = 1_000L
    private fun sounds(playEffect: (Int) -> Unit = { played += it }) = TvUiSounds(playEffect, { now })

    @Test
    fun `OK clicks and each arrow has its navigation effect`() {
        val s = sounds()
        assertEquals(SoundEffectConstants.CLICK, s.effectFor(KeyEvent.KEYCODE_DPAD_CENTER))
        assertEquals(SoundEffectConstants.CLICK, s.effectFor(KeyEvent.KEYCODE_ENTER))
        assertEquals(SoundEffectConstants.NAVIGATION_UP, s.effectFor(KeyEvent.KEYCODE_DPAD_UP))
        assertEquals(SoundEffectConstants.NAVIGATION_DOWN, s.effectFor(KeyEvent.KEYCODE_DPAD_DOWN))
        assertEquals(SoundEffectConstants.NAVIGATION_LEFT, s.effectFor(KeyEvent.KEYCODE_DPAD_LEFT))
        assertEquals(SoundEffectConstants.NAVIGATION_RIGHT, s.effectFor(KeyEvent.KEYCODE_DPAD_RIGHT))
    }

    @Test
    fun `keys without a sound stay silent`() {
        val s = sounds()
        assertNull(s.effectFor(KeyEvent.KEYCODE_BACK))
        assertNull(s.effectFor(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertNull(s.effectFor(KeyEvent.KEYCODE_5))
        s.onKeyDown(KeyEvent.KEYCODE_BACK)
        assertEquals(emptyList<Int>(), played)
    }

    @Test
    fun `a held arrow does not stack sounds`() {
        val s = sounds()
        s.onKeyDown(KeyEvent.KEYCODE_DPAD_RIGHT)
        now += 30
        s.onKeyDown(KeyEvent.KEYCODE_DPAD_RIGHT)
        now += 30
        s.onKeyDown(KeyEvent.KEYCODE_DPAD_RIGHT)
        now += 40
        s.onKeyDown(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals(2, played.size)
    }

    @Test
    fun `a refused sound never breaks the key press`() {
        val s = sounds { error("no audio") }
        s.onKeyDown(KeyEvent.KEYCODE_DPAD_CENTER)
    }
}
