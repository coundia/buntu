package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineConfig
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineKinds
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.SearchOutcome
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.SearchRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.SearchContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustSearchRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val profilesRepository: ProfilesRepository,
) : SearchRepository {

    override suspend fun searchLocal(
        prompt: String,
        scope: SearchScopeKind,
        locale: String,
        utcOffsetMinutes: Int,
    ): SearchOutcome = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val nowSecs = System.currentTimeMillis() / 1000L
        val ctx = SearchContext(
            playingStableHash = null,
            groupTitle = null,
            locale = locale,
            utcOffsetMinutes = utcOffsetMinutes,
            kinds = scope.toEngineKinds(),
        )
        engine.searchLocal(prompt, ctx).toDomain(prompt, nowSecs)
    }

    override suspend fun searchWithAi(
        prompt: String,
        scope: SearchScopeKind,
        locale: String,
        utcOffsetMinutes: Int,
        aiConfig: AiSettingsConfig,
        apiKey: String,
    ): SearchOutcome = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val activeProfile = profilesRepository.activeProfile()
        val engineConfig = aiConfig.toEngineConfig(apiKey)

        // PRD-37 § 10 (37.7) & § 12: Zero remote AI calls on Kids profiles!
        if (activeProfile.isKids && !engine.isLocalAiProvider(engineConfig)) {
            return@withContext searchLocal(prompt, scope, locale, utcOffsetMinutes)
        }

        val nowSecs = System.currentTimeMillis() / 1000L
        val ctx = SearchContext(
            playingStableHash = null,
            groupTitle = null,
            locale = locale,
            utcOffsetMinutes = utcOffsetMinutes,
            kinds = scope.toEngineKinds(),
        )
        engine.searchWithAi(prompt, ctx, engineConfig).toDomain(prompt, nowSecs)
    }
}

