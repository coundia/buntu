package com.pcoundia.buntu.core.designsystem

import androidx.compose.ui.graphics.Color
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Brand palette of Buntu (`docs/BRANDING_BUNTU.md` & Apple `AppBrand.swift`).
 * Contrast ratios are verified by unit test against WCAG 2.1 AA (4.5:1).
 */
object BuntuPalette {
    const val HEX_MIDNIGHT: Long = 0x0B0E14
    const val HEX_SLATE: Long = 0x161B26
    const val HEX_GOLD: Long = 0xFF9F0A
    const val HEX_CYAN: Long = 0x00D2FF
    const val HEX_WHITE: Long = 0xF5F7FA
    const val HEX_SILVER: Long = 0x8E95A5

    val Midnight = Color(0xFF0B0E14)
    val Slate = Color(0xFF161B26)
    val SlateElevated = Color(0xFF202737)
    val TerangaGold = Color(0xFFFF9F0A)
    val LeerCyan = Color(0xFF00D2FF)
    val PureWhite = Color(0xFFF5F7FA)
    val MutedSilver = Color(0xFF8E95A5)
    val DangerRed = Color(0xFFFF5A52)
    val SuccessGreen = Color(0xFF32D74B)

    const val WCAG_AA_NORMAL_TEXT: Double = 4.5

    fun relativeLuminance(rgbHex: Long): Double {
        fun channel(v: Long): Double {
            val srgb = (v and 0xFF) / 255.0
            return if (srgb <= 0.03928) srgb / 12.92 else ((srgb + 0.055) / 1.055).pow(2.4)
        }
        val r = channel(rgbHex shr 16)
        val g = channel(rgbHex shr 8)
        val b = channel(rgbHex)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    fun contrastRatio(hexA: Long, hexB: Long): Double {
        val la = relativeLuminance(hexA)
        val lb = relativeLuminance(hexB)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

