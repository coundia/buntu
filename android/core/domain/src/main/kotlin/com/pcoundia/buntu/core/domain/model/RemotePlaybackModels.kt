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

