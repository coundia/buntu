package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.domain.model.RemoteItemDescriptor
import com.pcoundia.buntu.core.domain.model.containerExtOf
import com.pcoundia.buntu.core.domain.model.providerRefOf
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncEngineBridge
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.domain.usecase.SyncSourceUseCase
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.SyncDelta
import com.pcoundia.buntu.core.engine.ffi.SyncFavorite
import com.pcoundia.buntu.core.engine.ffi.SyncProfile
import com.pcoundia.buntu.core.engine.ffi.SyncSource
import com.pcoundia.buntu.core.engine.ffi.SyncTombstone
import com.pcoundia.buntu.core.engine.ffi.SyncWatchProgress
import com.pcoundia.buntu.core.engine.ffi.syncComputeSourceKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustHouseholdSyncEngineBridge @Inject constructor(
    private val engineProvider: EngineProvider,
    private val secretStore: SecretStore,
    private val sourcesRepository: SourcesRepository,
    private val syncSourceUseCase: SyncSourceUseCase,
) : HouseholdSyncEngineBridge {

    /** Catalogs of accounts received from the household are downloaded here, one at a time (one connection). */
    private val catalogScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val catalogMutex = Mutex()

    override suspend fun resolveItemByContentKey(
        contentKey: String,
        sourceKey: String?,
        providerRef: String?,
        itemKind: String?,
    ): Long? = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val record = engine.itemByContentKey(
            contentKey = contentKey,
            sourceKey = sourceKey,
            providerRef = providerRef,
            itemKind = itemKind,
        )
        record?.id
    }

    override suspend fun sourceKeyForItem(itemId: Long): String? = withContext(Dispatchers.IO) {
        runCatching {
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId) ?: return@runCatching null
            val source = engine.listSources().firstOrNull { it.id == item.sourceId } ?: return@runCatching null
            syncComputeSourceKey(source.sourceType, source.server ?: source.url ?: "", source.username)
        }.getOrNull()
    }

    override suspend fun remoteItem(itemId: Long): RemoteItemDescriptor? = withContext(Dispatchers.IO) {
        runCatching {
            val engine = engineProvider.awaitEngine()
            val item = engine.getItemById(itemId) ?: return@runCatching null
            val kind = when (item.kind) {
                "movie", "vod" -> "movie"
                "episode" -> "episode"
                "live" -> "live"
                else -> return@runCatching null // a series is not playable as such
            }
            val source = engine.listSources().firstOrNull { it.id == item.sourceId }
            RemoteItemDescriptor(
                contentKey = item.stableHash,
                sourceKey = source?.let { syncComputeSourceKey(it.sourceType, it.server ?: it.url ?: "", it.username) },
                itemKind = kind,
                title = item.name,
                resumePositionMs = if (kind == "live" || item.isCompleted) 0L else item.resumePositionMs.coerceAtLeast(0L),
                providerRef = providerRefOf(item.streamUrl),
                containerExt = item.containerExt?.trim()?.trimStart('.')?.lowercase()?.takeIf { it.isNotEmpty() }
                    ?: containerExtOf(item.streamUrl),
            )
        }.getOrNull()
    }

    override suspend fun importHouseholdDelta(deltaJson: String): Boolean = withContext(Dispatchers.IO) {
        try {
            val root = JSONObject(deltaJson)
            val sourcesJson = root.optJSONArray("sources") ?: JSONArray()
            val sources = mutableListOf<SyncSource>()
            val engine = engineProvider.awaitEngine()
            // Last write wins (as Apple `storeReceivedPasswords`): a password replaces the local one only when
            // the incoming account is new or not older than this device's copy.
            val localUpdatedAt = runCatching { engine.listSources().associate { it.uuid to it.updatedAt } }
                .getOrDefault(emptyMap())

            for (i in 0 until sourcesJson.length()) {
                val s = sourcesJson.getJSONObject(i)
                val uuid = s.getString("uuid")
                val updatedAt = s.optLong("updated_at", System.currentTimeMillis() / 1000)
                // The password goes where this device looks for it: the account's `password_ref`, or the
                // alias Apple uses (`KeychainStore.xtreamKey`). It was stored under `source_pwd_<uuid>`
                // while the account kept another reference, so received Xtream accounts could not sync.
                val passwordRef = s.optString("password_ref").takeIf { it.isNotEmpty() } ?: "cnd.xtream.$uuid"
                val pwd = s.optString("password").takeIf { it.isNotEmpty() }
                val local = localUpdatedAt[uuid]
                if (pwd != null && (local == null || updatedAt >= local)) {
                    secretStore.putSecret(passwordRef, pwd)
                    secretStore.putSecret("source_pwd_$uuid", pwd)
                }

                sources.add(
                    SyncSource(
                        uuid = uuid,
                        name = s.getString("name"),
                        sourceType = s.getString("source_type"),
                        url = s.optString("url").takeIf { it.isNotEmpty() },
                        server = s.optString("server").takeIf { it.isNotEmpty() },
                        username = s.optString("username").takeIf { it.isNotEmpty() },
                        passwordRef = passwordRef.takeIf { s.optString("source_type") == "xtream" }
                            ?: s.optString("password_ref").takeIf { it.isNotEmpty() },
                        epgUrl = s.optString("epg_url").takeIf { it.isNotEmpty() },
                        updatedAt = updatedAt,
                    )
                )
            }

            val profilesJson = root.optJSONArray("profiles") ?: JSONArray()
            val profiles = mutableListOf<SyncProfile>()
            for (i in 0 until profilesJson.length()) {
                val p = profilesJson.getJSONObject(i)
                profiles.add(
                    SyncProfile(
                        uuid = p.getString("uuid"),
                        name = p.getString("name"),
                        avatar = p.optString("avatar", "person"),
                        isKids = p.optBoolean("is_kids", false),
                        updatedAt = p.optLong("updated_at", System.currentTimeMillis() / 1000),
                    )
                )
            }

            val favoritesJson = root.optJSONArray("favorites") ?: JSONArray()
            val favorites = mutableListOf<SyncFavorite>()
            for (i in 0 until favoritesJson.length()) {
                val f = favoritesJson.getJSONObject(i)
                favorites.add(
                    SyncFavorite(
                        stableHash = f.getString("stable_hash"),
                        itemKind = f.getString("item_kind"),
                        createdAt = f.optLong("created_at", System.currentTimeMillis() / 1000),
                        profileUuid = f.optString("profile_uuid").takeIf { it.isNotEmpty() },
                    )
                )
            }

            val watchJson = root.optJSONArray("watch_history") ?: JSONArray()
            val watchHistory = mutableListOf<SyncWatchProgress>()
            for (i in 0 until watchJson.length()) {
                val w = watchJson.getJSONObject(i)
                watchHistory.add(
                    SyncWatchProgress(
                        stableHash = w.getString("stable_hash"),
                        positionMs = w.getLong("position_ms"),
                        durationMs = w.getLong("duration_ms"),
                        completed = w.optBoolean("completed", false),
                        lastWatchedAt = w.optLong("last_watched_at", System.currentTimeMillis() / 1000),
                        profileUuid = w.optString("profile_uuid").takeIf { it.isNotEmpty() },
                    )
                )
            }

            val tombstonesJson = root.optJSONArray("tombstones") ?: JSONArray()
            val tombstones = mutableListOf<SyncTombstone>()
            for (i in 0 until tombstonesJson.length()) {
                val t = tombstonesJson.getJSONObject(i)
                tombstones.add(
                    SyncTombstone(
                        kind = t.getString("kind"),
                        key = t.getString("key"),
                        deletedAt = t.optLong("deleted_at", System.currentTimeMillis() / 1000),
                    )
                )
            }

            val syncDelta = SyncDelta(
                profiles = profiles,
                sources = sources,
                favorites = favorites,
                watchHistory = watchHistory,
                tombstones = tombstones,
            )

            val summary = engine.importSyncDelta(syncDelta)
            // The Sources screen shows the received accounts at once.
            runCatching { sourcesRepository.refreshSourcesList() }
            downloadCatalogsOf(summary.insertedSourceIds)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * New accounts arrive empty: download their channels, films and series, one account after the other
     * (never two connections at once), as Apple does with `onSourcesInserted`.
     */
    private fun downloadCatalogsOf(sourceIds: List<Long>) {
        if (sourceIds.isEmpty()) return
        catalogScope.launch {
            catalogMutex.withLock {
                val sources = runCatching { sourcesRepository.refreshSourcesList() }.getOrNull() ?: return@withLock
                for (id in sourceIds) {
                    val source = sources.firstOrNull { it.id == id } ?: continue
                    runCatching { syncSourceUseCase(source) }
                }
            }
        }
    }

    override suspend fun exportHouseholdDelta(sinceTs: Long): String = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val delta = engine.exportSyncDelta(sinceTs)

        if (delta.profiles.isEmpty() && delta.sources.isEmpty() && delta.favorites.isEmpty() &&
            delta.watchHistory.isEmpty() && delta.tombstones.isEmpty()
        ) {
            return@withContext ""
        }

        val sourcesJson = JSONArray()
        for (s in delta.sources) {
            val obj = JSONObject().apply {
                put("uuid", s.uuid)
                put("name", s.name)
                put("source_type", s.sourceType)
                put("url", s.url)
                put("server", s.server)
                put("username", s.username)
                put("password_ref", s.passwordRef)
                put("epg_url", s.epgUrl)
                put("updated_at", s.updatedAt)
            }
            val pwd = secretStore.getSecret("source_pwd_${s.uuid}")
                ?: s.passwordRef?.let { secretStore.getSecret(it) }
            if (pwd != null) {
                obj.put("password", pwd)
            }
            sourcesJson.put(obj)
        }

        val profilesJson = JSONArray()
        for (p in delta.profiles) {
            profilesJson.put(JSONObject().apply {
                put("uuid", p.uuid)
                put("name", p.name)
                put("avatar", p.avatar)
                put("is_kids", p.isKids)
                put("updated_at", p.updatedAt)
            })
        }

        val favoritesJson = JSONArray()
        for (f in delta.favorites) {
            favoritesJson.put(JSONObject().apply {
                put("stable_hash", f.stableHash)
                put("item_kind", f.itemKind)
                put("created_at", f.createdAt)
                put("profile_uuid", f.profileUuid)
            })
        }

        val watchJson = JSONArray()
        for (w in delta.watchHistory) {
            watchJson.put(JSONObject().apply {
                put("stable_hash", w.stableHash)
                put("position_ms", w.positionMs)
                put("duration_ms", w.durationMs)
                put("completed", w.completed)
                put("last_watched_at", w.lastWatchedAt)
                put("profile_uuid", w.profileUuid)
            })
        }

        val tombstonesJson = JSONArray()
        for (t in delta.tombstones) {
            tombstonesJson.put(JSONObject().apply {
                put("kind", t.kind)
                put("key", t.key)
                put("deleted_at", t.deletedAt)
            })
        }

        JSONObject().apply {
            put("profiles", profilesJson)
            put("sources", sourcesJson)
            put("favorites", favoritesJson)
            put("watch_history", watchJson)
            put("tombstones", tombstonesJson)
        }.toString()
    }
}
