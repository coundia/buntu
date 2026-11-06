package com.pcoundia.buntu.core.player

import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * PRD-37 § 4.3:
 * - Never restarts a stream while bytes are still arriving from the provider/relay!
 * - Waits longer after HTTP `429` so a single-connection IPTV server releases the previous socket.
 * - Maps low-level exceptions and HTTP codes to actionable French `StreamDiagnosis`.
 */
class StallWatchdog(
    private val stallThresholdMs: Long = 10_000L,
    private val maxAutoRetries: Int = 3,
) {
    private var lastBytesObserved: Long = 0L
    private var lastByteAdvanceAtMs: Long = 0L
    private var retryCount: Int = 0

    fun reset(nowMs: Long) {
        lastBytesObserved = 0L
        lastByteAdvanceAtMs = nowMs
        retryCount = 0
    }

    /**
     * Returns `true` ONLY when the player is buffering, zero new bytes have arrived for at least
     * `stallThresholdMs`, and the retry budget has not been exhausted.
     */
    fun shouldRestartStalledStream(
        isBuffering: Boolean,
        totalBytesReceived: Long,
        nowMs: Long,
    ): Boolean {
        if (!isBuffering) {
            lastBytesObserved = totalBytesReceived
            lastByteAdvanceAtMs = nowMs
            return false
        }
        if (totalBytesReceived > lastBytesObserved) {
            // Bytes are actively flowing — NEVER restart! (PRD-37 § 4.3)
            lastBytesObserved = totalBytesReceived
            lastByteAdvanceAtMs = nowMs
            return false
        }
        if (retryCount >= maxAutoRetries) {
            return false
        }
        val stalledDuration = nowMs - lastByteAdvanceAtMs
        if (stalledDuration >= stallThresholdMs) {
            retryCount += 1
            lastByteAdvanceAtMs = nowMs
            return true
        }
        return false
    }

    fun computeRetryDelayMs(diagnosis: StreamDiagnosis, attempt: Int): Long? {
        if (attempt > maxAutoRetries) return null
        return when (diagnosis) {
            is StreamDiagnosis.Http -> when {
                // PRD-37 § 4.3: After 429, wait for the provider to release the single connection!
                diagnosis.statusCode == 429 -> 4_500L * attempt.coerceAtLeast(1)
                diagnosis.isFinalError -> null
                else -> 1_500L * attempt.coerceAtLeast(1)
            }
            StreamDiagnosis.Timeout, StreamDiagnosis.Unreachable -> 1_800L * attempt.coerceAtLeast(1)
            StreamDiagnosis.Offline -> 3_000L
            StreamDiagnosis.UnknownHost, StreamDiagnosis.SecureConnection -> null
        }
    }

    companion object {
        fun classifyFailure(httpStatusCode: Int?, cause: Throwable?): StreamDiagnosis {
            if (httpStatusCode != null && httpStatusCode >= 400) {
                return StreamDiagnosis.Http(httpStatusCode)
            }
            val root = generateSequence(cause) { it.cause }.lastOrNull() ?: cause
            return when (root) {
                is UnknownHostException -> StreamDiagnosis.UnknownHost
                is SocketTimeoutException -> StreamDiagnosis.Timeout
                is SSLException -> StreamDiagnosis.SecureConnection
                is ConnectException -> StreamDiagnosis.Unreachable
                else -> {
                    val msg = root?.message?.lowercase().orEmpty()
                    when {
                        "429" in msg -> StreamDiagnosis.Http(429)
                        "403" in msg -> StreamDiagnosis.Http(403)
                        "401" in msg -> StreamDiagnosis.Http(401)
                        "404" in msg -> StreamDiagnosis.Http(404)
                        "unable to resolve host" in msg -> StreamDiagnosis.UnknownHost
                        "network is unreachable" in msg -> StreamDiagnosis.Offline
                        "timed out" in msg || "timeout" in msg -> StreamDiagnosis.Timeout
                        else -> StreamDiagnosis.Unreachable
                    }
                }
            }
        }
    }
}

