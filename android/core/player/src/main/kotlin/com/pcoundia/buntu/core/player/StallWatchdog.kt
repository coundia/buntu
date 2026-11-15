package com.pcoundia.buntu.core.player

import androidx.media3.common.PlaybackException
import com.pcoundia.buntu.core.domain.model.StreamDiagnosis
import com.pcoundia.buntu.core.domain.model.redactStreamUrls
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
        minimumStallThresholdMs: Long = 0L,
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
        if (stalledDuration >= maxOf(stallThresholdMs, minimumStallThresholdMs)) {
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
            is StreamDiagnosis.UnsupportedFormat -> null
            is StreamDiagnosis.Generic -> if (diagnosis.isFinalError) null else 1_800L * attempt.coerceAtLeast(1)
        }
    }

    companion object {
        private val DECODER_OR_FORMAT_ERROR_CODES = setOf(
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
            PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
            PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
            PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED,
        )

        private val MALFORMED_STREAM_ERROR_CODES = setOf(
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
        )

        fun classifyFailure(
            httpStatusCode: Int?,
            cause: Throwable?,
            media3ErrorCode: Int? = null,
        ): StreamDiagnosis {
            if (httpStatusCode != null && httpStatusCode >= 400) {
                return StreamDiagnosis.Http(httpStatusCode)
            }
            val causeChain = generateSequence(cause) { it.cause }.toList()
            val root = causeChain.lastOrNull() ?: cause
            val cleanDetail = redactStreamUrls(
                root?.localizedMessage ?: root?.message ?: cause?.localizedMessage ?: cause?.message,
            )
            if (media3ErrorCode == PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED) {
                return StreamDiagnosis.Generic(
                    userMessage = "Connexion HTTP non chiffrée refusée par Android pour cette source.",
                    isFinalError = true,
                )
            }
            if (media3ErrorCode in DECODER_OR_FORMAT_ERROR_CODES) {
                return StreamDiagnosis.UnsupportedFormat(cleanDetail.takeIf { it.isNotEmpty() })
            }
            if (media3ErrorCode in MALFORMED_STREAM_ERROR_CODES) {
                val suffix = if (cleanDetail.isNotEmpty()) " ($cleanDetail)" else ""
                return StreamDiagnosis.Generic(
                    userMessage = "Flux corrompu ou format illisible$suffix.",
                    isFinalError = false,
                )
            }
            return when (root) {
                is UnknownHostException -> StreamDiagnosis.UnknownHost
                is SocketTimeoutException -> StreamDiagnosis.Timeout
                is SSLException -> StreamDiagnosis.SecureConnection
                is ConnectException -> StreamDiagnosis.Unreachable
                else -> {
                    val combinedLower = causeChain.mapNotNull { it.message?.lowercase() }.joinToString(" | ")
                    when {
                        "429" in combinedLower -> StreamDiagnosis.Http(429)
                        "403" in combinedLower -> StreamDiagnosis.Http(403)
                        "401" in combinedLower -> StreamDiagnosis.Http(401)
                        "404" in combinedLower -> StreamDiagnosis.Http(404)
                        "cleartext" in combinedLower -> StreamDiagnosis.Generic(
                            userMessage = "Connexion HTTP non chiffrée refusée par Android pour cette source.",
                            isFinalError = true,
                        )
                        "decoder" in combinedLower ||
                            "mediacodec" in combinedLower ||
                            "unrecognizedinputformatexception" in combinedLower ||
                            "unsupported" in combinedLower -> StreamDiagnosis.UnsupportedFormat(cleanDetail.takeIf { it.isNotEmpty() })
                        "unable to resolve host" in combinedLower || "unknownhost" in combinedLower -> StreamDiagnosis.UnknownHost
                        "network is unreachable" in combinedLower || "enetunreach" in combinedLower -> StreamDiagnosis.Offline
                        "timed out" in combinedLower || "timeout" in combinedLower -> StreamDiagnosis.Timeout
                        "econnrefused" in combinedLower || "connection refused" in combinedLower -> StreamDiagnosis.Unreachable
                        cleanDetail.isNotEmpty() -> StreamDiagnosis.Generic(
                            userMessage = "Erreur de lecture : $cleanDetail",
                            isFinalError = false,
                        )
                        else -> StreamDiagnosis.Unreachable
                    }
                }
            }
        }
    }
}

