package com.pcoundia.buntu.core.domain.model

data class DiscoveredPeer(
    val id: String,
    val name: String,
    val deviceType: String, // "mobile" | "tv" | "desktop"
    val canPlay: Boolean = true,
    val capabilities: List<String> = emptyList(),
    val state: String = "idle", // "idle" | "playing" | "busy"
    val lastSeen: Long = System.currentTimeMillis(),
)

data class SyncLogEntry(
    val id: String = java.util.UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis(),
    val isWarning: Boolean = false,
    val message: String,
)

enum class RemoteAccessPolicy {
    OPEN,
    ALWAYS_ASK,
    DISABLED,
}

data class IncomingPlayInstruction(
    val itemId: Long,
    val title: String?,
    val positionMs: Long,
    val sourceKey: String?,
)

data class ActiveRemoteControlSession(
    val targetPeerId: String,
    val targetPeerName: String,
    val contentKey: String,
    val title: String,
    val state: String,
    val positionMs: Long,
    val durationMs: Long,
    val lastUpdate: Long = System.currentTimeMillis(),
)


/** Devices offered by « Lire sur un autre appareil »: reachable and able to play. */
fun List<DiscoveredPeer>.playbackTargets(): List<DiscoveredPeer> = filter { it.state != "offline" && it.canPlay }

/** What a handoff sends about a local item (PRD-42 § 3.1), read from the engine. */
data class RemoteItemDescriptor(
    val contentKey: String,
    val sourceKey: String?,
    /** "movie" | "episode" | "live" (wire values of `item_kind`). */
    val itemKind: String,
    val title: String,
    val resumePositionMs: Long,
    /**
     * The provider's own id of the stream (`…/12345.mkv` → `12345`): another device finds the item by it,
     * since its own catalog ids differ. Never the address, which carries the account's password.
     */
    val providerRef: String? = null,
    /** File extension (`mkv`, `mp4`, `ts`): the Samsung TV rebuilds the address of an item it does not store. */
    val containerExt: String? = null,
)

/** `…/live/u/p/12345.ts?x=1` → `12345`; `null` when the last segment does not look like an id. */
fun providerRefOf(streamUrl: String): String? {
    if (!streamUrl.startsWith("http://") && !streamUrl.startsWith("https://")) return null
    val last = lastPathSegment(streamUrl) ?: return null
    val id = if (last.contains('.')) last.substringBeforeLast('.') else last
    if (id.isEmpty() || id.length > 40) return null
    return id.takeIf { s -> s.all { (it.isLetterOrDigit() && it.code < 128) || it == '_' || it == '-' } }
}

/** `…/12345.mkv` → `mkv`; `null` without a plausible extension. */
fun containerExtOf(streamUrl: String): String? {
    val last = lastPathSegment(streamUrl) ?: return null
    if (!last.contains('.')) return null
    val ext = last.substringAfterLast('.')
    if (ext.isEmpty() || ext.length > 8 || !ext.all { it.isLetterOrDigit() && it.code < 128 }) return null
    return ext.lowercase()
}

/** Last segment of the path (never the host), `null` when the path is empty. */
private fun lastPathSegment(streamUrl: String): String? {
    val afterScheme = streamUrl.substringAfter("://", streamUrl)
    val slash = afterScheme.indexOf('/')
    if (slash < 0) return null
    val path = afterScheme.substring(slash).substringBefore('?').substringBefore('#').trimEnd('/')
    return path.substringAfterLast('/').takeIf { it.isNotEmpty() }
}
