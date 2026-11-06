package com.pcoundia.buntu.core.domain.model

import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.persistentMapOf
import java.net.URI

enum class StreamKind {
    LIVE,
    VOD_MOVIE,
    VOD_EPISODE,
    CATCHUP,
    LOCAL_FILE,
}

data class PlayableStream(
    val itemId: Long,
    val stableHash: String,
    val title: String,
    val subtitle: String? = null,
    val posterUrl: String? = null,
    val originalUrl: String,
    val playbackUrl: String,
    val kind: StreamKind,
    val host: String,
    val containerExtension: String? = null,
    val userAgent: String? = null,
    val referer: String? = null,
    val headers: ImmutableMap<String, String> = persistentMapOf(),
    val startPositionMs: Long = 0L,
    val expectedFileSizeBytes: Long? = null,
    val expectedDurationMs: Long? = null,
    val maxConnectionsForSource: Int = 1,
) {
    val usesSingleConnectionRelay: Boolean
        get() = playbackUrl.startsWith("http://127.0.0.1:")
}

/**
 * PRD-37 § 4.2 & Apple `ConnectionBudget.swift` parity:
 * Default limit is 1 so single-connection IPTV subscriptions never suffer HTTP 429 / 502.
 */
data class ConnectionBudget(
    val rawLimit: Int = DEFAULT_LIMIT,
) {
    val limit: Int = rawLimit.coerceIn(MIN_LIMIT, MAX_LIMIT)

    val downloadConnections: Int
        get() = if (limit <= 1) 1 else limit - 1

    val pausesDownloadsDuringPlayback: Boolean
        get() = limit <= 1

    val allowsParallelPreload: Boolean
        get() = limit >= 2

    fun clampDownloads(requestedSegments: Int, requestedFiles: Int): Pair<Int, Int> {
        val cap = downloadConnections
        val segments = requestedSegments.coerceIn(1, cap)
        val files = requestedFiles.coerceIn(1, maxOf(1, cap / segments))
        return segments to files
    }

    companion object {
        const val DEFAULT_LIMIT = 1
        const val MIN_LIMIT = 1
        const val MAX_LIMIT = 10

        fun forHost(
            host: String?,
            sources: List<SourceSummary>,
            assumedLimit: Int,
        ): ConnectionBudget {
            val base = ConnectionBudget(assumedLimit).limit
            val normalizedHost = host?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
                ?: return ConnectionBudget(base)
            val reported = sources
                .firstOrNull { extractHost(it.serverOrUrl) == normalizedHost }
                ?.maxConnections
                ?.takeIf { it > 0 }
                ?: return ConnectionBudget(base)
            return ConnectionBudget(minOf(base, reported))
        }

        fun extractHost(rawUrlOrServer: String?): String? {
            val trimmed = rawUrlOrServer?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val candidate = if ("://" in trimmed) trimmed else "http://$trimmed"
            return runCatching { URI(candidate).host?.lowercase() }.getOrNull()
        }
    }
}

/**
 * PRD-37 § 4.3 & § 5.4: Clear French error messages matching Apple's `StreamDiagnosis`.
 */
sealed interface StreamDiagnosis {
    val userMessage: String
    val isFinalError: Boolean

    data class Http(val statusCode: Int) : StreamDiagnosis {
        override val isFinalError: Boolean
            get() = statusCode in FINAL_HTTP_CODES

        override val userMessage: String
            get() = when {
                statusCode == 429 ->
                    "Votre abonnement n'autorise qu'une connexion simultanée (HTTP 429) : arrêtez la lecture ou le téléchargement sur l'autre appareil, puis réessayez."
                statusCode == 401 || statusCode == 403 ->
                    "Accès refusé par le serveur (HTTP $statusCode) : identifiants invalides, abonnement expiré ou adresse IP non autorisée."
                statusCode == 404 || statusCode == 410 ->
                    "Contenu introuvable sur le serveur (HTTP $statusCode) : synchronisez la source."
                statusCode == 458 || statusCode == 884 ->
                    "Le serveur refuse ce compte (HTTP $statusCode) : limite de connexions atteinte."
                statusCode in 500..599 ->
                    "Erreur du serveur du fournisseur (HTTP $statusCode) : réessayez dans quelques instants."
                else ->
                    "Réponse inattendue du serveur (HTTP $statusCode)."
            }

        companion object {
            private val FINAL_HTTP_CODES = setOf(401, 403, 404, 410, 429, 458, 884)
        }
    }

    data object Timeout : StreamDiagnosis {
        override val isFinalError: Boolean = false
        override val userMessage: String =
            "Le serveur ne répond pas (délai dépassé) : serveur surchargé ou réseau trop lent."
    }

    data object UnknownHost : StreamDiagnosis {
        override val isFinalError: Boolean = true
        override val userMessage: String =
            "Nom du serveur introuvable (DNS) : vérifiez l'adresse de la source ou votre connexion."
    }

    data object Offline : StreamDiagnosis {
        override val isFinalError: Boolean = false
        override val userMessage: String = "Pas de connexion Internet."
    }

    data object SecureConnection : StreamDiagnosis {
        override val isFinalError: Boolean = true
        override val userMessage: String = "Connexion sécurisée refusée (certificat HTTPS invalide)."
    }

    data object Unreachable : StreamDiagnosis {
        override val isFinalError: Boolean = false
        override val userMessage: String = "Connexion au serveur impossible (serveur éteint ou port fermé)."
    }
}

/**
 * PRD-37 § 4.3: Insufficient throughput warning for heavy VOD files (e.g. 4K MKV remux).
 */
data class BandwidthAssessment(
    val isInsufficient: Boolean,
    val measuredBitsPerSec: Long,
    val requiredBitsPerSec: Long,
    val hasLighterVersions: Boolean = false,
) {
    val measuredMbps: Double
        get() = measuredBitsPerSec / 1_000_000.0

    val requiredMbps: Double
        get() = requiredBitsPerSec / 1_000_000.0
}

data class DownloadItem(
    val id: Long,
    val itemId: Long?,
    val title: String,
    val state: String,
    val downloadedBytes: Long,
    val totalBytes: Long?,
    val speedBytesPerSec: Double,
    val etaSeconds: Long?,
    val targetPath: String,
    val errorMessage: String?,
) {
    val progressFraction: Float
        get() = if (totalBytes != null && totalBytes > 0L) {
            (downloadedBytes.toFloat() / totalBytes.toFloat()).coerceIn(0f, 1f)
        } else {
            0f
        }
}

data class ProfileSummary(
    val id: Long,
    val name: String,
    val avatar: String,
    val isKids: Boolean,
    val isActive: Boolean,
)

enum class AiProviderType {
    NONE,
    GEMINI,
    OPENAI_COMPATIBLE,
    CLAUDE,
}

data class AiSettingsConfig(
    val provider: AiProviderType = AiProviderType.NONE,
    val model: String = "",
    val endpointUrl: String = "",
    val keyAlias: String = "ai_provider_key",
    val sendRecentTitles: Boolean = false,
)

data class AppPreferences(
    val onboardingCompleted: Boolean = false,
    val assumedMaxConnections: Int = 1,
    val uiScale: Float = 1.0f,
    val autoFrameRateMatchingTv: Boolean = true,
    val audioPassthroughTv: Boolean = true,
    val tunnelingEnabledTv: Boolean = true,
    val downloadOverCellular: Boolean = false,
    val adultCategoriesUnlocked: Boolean = false,
    val lastChannelId: Long? = null,
    val aiConfig: AiSettingsConfig = AiSettingsConfig(),
)

data class NetworkLogItem(
    val seqId: Long,
    val timestampMs: Long,
    val level: String,
    val category: String,
    val redactedUrl: String?,
    val statusCode: Int?,
    val durationMs: Long?,
    val message: String,
)

