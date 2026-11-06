package com.pcoundia.buntu.core.designsystem

import org.junit.Assert.assertTrue
import org.junit.Test

class BuntuPaletteTest {

    @Test
    fun `brand foreground colors meet WCAG AA contrast on Midnight and Slate surfaces`() {
        val surfaces = listOf(
            "Midnight" to BuntuPalette.HEX_MIDNIGHT,
            "Slate" to BuntuPalette.HEX_SLATE,
        )
        val foregrounds = listOf(
            "PureWhite" to BuntuPalette.HEX_WHITE,
            "TerangaGold" to BuntuPalette.HEX_GOLD,
            "LeerCyan" to BuntuPalette.HEX_CYAN,
            "MutedSilver" to BuntuPalette.HEX_SILVER,
        )

        for ((surfaceName, surfaceHex) in surfaces) {
            for ((fgName, fgHex) in foregrounds) {
                val ratio = BuntuPalette.contrastRatio(fgHex, surfaceHex)
                assertTrue(
                    "$fgName on $surfaceName contrast $ratio must be >= ${BuntuPalette.WCAG_AA_NORMAL_TEXT}",
                    ratio >= BuntuPalette.WCAG_AA_NORMAL_TEXT,
                )
            }
        }
    }

    @Test
    fun `TV metrics enforce overscan safe margins and low-RAM disables focus scale animation`() {
        val tvLowRam = BuntuMetrics(isTv = true, isLowRamDevice = true)
        assertTrue(tvLowRam.horizontalScreenPadding.value == 48f)
        assertTrue(tvLowRam.verticalScreenPadding.value == 27f)
        assertTrue(!tvLowRam.enableFocusScaleAnimation)
    }
}

