package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustProfilesRepository @Inject constructor(
    private val engineProvider: EngineProvider,
) : ProfilesRepository {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _profilesFlow = MutableStateFlow<ImmutableList<ProfileSummary>>(persistentListOf())
    override val profilesFlow: Flow<ImmutableList<ProfileSummary>> = _profilesFlow.asStateFlow()

    init {
        scope.launch {
            runCatching { refreshProfiles() }
        }
    }

    override suspend fun refreshProfiles(): ImmutableList<ProfileSummary> =
        withContext(Dispatchers.IO) {
            val engine = engineProvider.awaitEngine()
            val activeId = engine.activeProfileId()
            val list = engine.listProfiles().map { it.toDomain(activeId) }.toImmutableList()
            _profilesFlow.value = list
            list
        }

    override suspend fun activeProfile(): ProfileSummary =
        withContext(Dispatchers.IO) {
            val profiles = refreshProfiles()
            profiles.firstOrNull { it.isActive }
                ?: profiles.firstOrNull()
                ?: ProfileSummary(id = 1L, name = "Principal", avatar = "🎬", isKids = false, isActive = true)
        }

    override suspend fun selectProfile(profileId: Long) = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        engine.setActiveProfileId(profileId)
        refreshProfiles()
        Unit
    }

    override suspend fun createProfile(
        name: String,
        avatar: String,
        isKids: Boolean,
    ): ProfileSummary = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val created = engine.createProfile(name.trim(), avatar, isKids)
        val activeId = engine.activeProfileId()
        refreshProfiles()
        created.toDomain(activeId)
    }

    override suspend fun deleteProfile(profileId: Long) = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        engine.deleteProfile(profileId)
        refreshProfiles()
        Unit
    }

    override suspend fun setAdultContentVisible(visible: Boolean) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().setAdultContentVisible(visible)
    }

    override suspend fun setGroupAllowedForKids(
        profileId: Long,
        kind: String,
        groupName: String,
        allowed: Boolean,
    ) = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        if (allowed) {
            engine.allowGroup(profileId, kind, groupName)
        } else {
            engine.disallowGroup(profileId, kind, groupName)
        }
        Unit
    }
}

