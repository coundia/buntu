package com.pcoundia.buntu.core.platform.logging

import android.util.Log
import android.view.Window
import androidx.metrics.performance.JankStats
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.URI
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

data class FramePerformanceSummary(
    val totalFrames: Long = 0L,
    val jankyFrames: Long = 0L,
) {
    val jankPercent: Double
        get() = if (totalFrames > 0L) (jankyFrames * 100.0) / totalFrames.toDouble() else 0.0
}

/**
 * PRD-37 § 5.1, § 7, § 12:
 * - Masks stream URLs so only `host` and `.ext` appear in logs (parity with Apple `AppLog.describe`).
 * - Tracks `JankStats` slow frames (> 16 ms) for internal diagnostic visibility.
 */
@Singleton
class RedactedAppLogger @Inject constructor() {

    private val totalFrames = AtomicLong(0L)
    private val jankyFrames = AtomicLong(0L)

    private val _frameStats = MutableStateFlow(FramePerformanceSummary())
    val frameStats: StateFlow<FramePerformanceSummary> = _frameStats.asStateFlow()

    fun info(category: String, message: String) {
        runCatching { Log.i("Buntu.$category", message) }
    }

    fun warn(category: String, message: String) {
        runCatching { Log.w("Buntu.$category", message) }
    }

    fun error(category: String, message: String, throwable: Throwable? = null) {
        runCatching { Log.e("Buntu.$category", message, throwable) }
    }

    fun attachJankStats(window: Window): JankStats {
        return JankStats.createAndTrack(window) { frameData ->
            val total = totalFrames.incrementAndGet()
            val janky = if (frameData.isJank) jankyFrames.incrementAndGet() else jankyFrames.get()
            if (total % 30L == 0L || frameData.isJank) {
                _frameStats.value = FramePerformanceSummary(totalFrames = total, jankyFrames = janky)
            }
        }
    }

    companion object {
        fun describeStreamUrl(rawUrl: String?): String {
            val trimmed = rawUrl?.trim()?.takeIf(String::isNotEmpty) ?: return "<empty>"
            val parsed = runCatching { URI(trimmed) }.getOrNull() ?: return "<redacted-url>"
            val host = parsed.host?.lowercase() ?: "<local>"
            val path = parsed.path.orEmpty()
            val lastDot = path.lastIndexOf('.')
            val lastSlash = path.lastIndexOf('/')
            val ext = if (lastDot > lastSlash && lastDot >= 0 && path.length - lastDot <= 6) {
                path.substring(lastDot).lowercase()
            } else {
                ""
            }
            return if (ext.isNotEmpty()) "$host, $ext" else host
        }
    }
}

