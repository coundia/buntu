package com.pcoundia.buntu

import com.pcoundia.buntu.navigation.BuntuRoutes
import com.pcoundia.buntu.ui.TvHomeModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TvHomeModelTest {
    @Test
    fun `the home offers Live, Films and Series then the shortcuts, like the Samsung TV`() {
        assertEquals(listOf("Live", "Films", "Séries"), TvHomeModel.Section.entries.map { it.title })
        assertEquals(
            listOf(BuntuRoutes.LIVE, BuntuRoutes.MOVIES, BuntuRoutes.SERIES),
            TvHomeModel.Section.entries.map { it.route },
        )
        assertEquals(listOf("Sources", "Appareils", "Réglages", "Quitter"), TvHomeModel.Shortcut.entries.map { it.title })
        assertNull(TvHomeModel.Shortcut.EXIT.route)
        assertTrue(TvHomeModel.Shortcut.entries.filter { it != TvHomeModel.Shortcut.EXIT }.all { it.route != null })
    }

    @Test
    fun `the TV starts on the home, the phone on Live, and a first launch on onboarding`() {
        assertEquals(BuntuRoutes.HOME, TvHomeModel.startDestination(isTelevision = true, onboardingDone = true))
        assertEquals(BuntuRoutes.LIVE, TvHomeModel.startDestination(isTelevision = false, onboardingDone = true))
        assertEquals(BuntuRoutes.ONBOARDING, TvHomeModel.startDestination(isTelevision = true, onboardingDone = false))
        assertEquals(BuntuRoutes.ONBOARDING, TvHomeModel.startDestination(isTelevision = false, onboardingDone = false))
    }

    @Test
    fun `the clock is two digits for the hour and the minutes`() {
        assertEquals("21:53", TvHomeModel.clock(21, 53))
        assertEquals("07:05", TvHomeModel.clock(7, 5))
    }
}
