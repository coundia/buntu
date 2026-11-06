package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.data.mapper.EngineMappers.toDomain
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineConfig
import com.pcoundia.buntu.core.data.mapper.EngineMappers.toEngineKind
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class RustRecommendationsRepository @Inject constructor(
    private val engineProvider: EngineProvider,
    private val profilesRepository: ProfilesRepository,
) : RecommendationsRepository {

    override suspend fun loadLocalShelves(
        kind: RecoDomainKind,
        limitPerShelf: Int,
        utcOffsetMinutes: Int,
    ): ImmutableList<RecoShelfGroup> = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        engine.recommendationShelves(
            kind = kind.toEngineKind(),
            limitPerShelf = limitPerShelf.coerceIn(4, 40).toUInt(),
            utcOffsetMinutes = utcOffsetMinutes,
        ).map { it.toDomain() }.toImmutableList()
    }

    override suspend fun refineShelvesWithAi(
        kind: RecoDomainKind,
        aiConfig: AiSettingsConfig,
        apiKey: String,
        limitPerShelf: Int,
        locale: String,
        utcOffsetMinutes: Int,
    ): ImmutableList<RecoShelfGroup> = withContext(Dispatchers.IO) {
        val engine = engineProvider.awaitEngine()
        val activeProfile = profilesRepository.activeProfile()
        val engineConfig = aiConfig.toEngineConfig(apiKey)

        // PRD-37 § 12: Never call remote AI for Kids profiles
        if (activeProfile.isKids && !engine.isLocalAiProvider(engineConfig)) {
            return@withContext loadLocalShelves(kind, limitPerShelf, utcOffsetMinutes)
        }

        engine.refineShelvesWithAi(
            kind = kind.toEngineKind(),
            config = engineConfig,
            limitPerShelf = limitPerShelf.coerceIn(4, 40).toUInt(),
            sendRecentTitles = aiConfig.sendRecentTitles,
            locale = locale,
            utcOffsetMinutes = utcOffsetMinutes,
        ).map { it.toDomain() }.toImmutableList()
    }

    override suspend fun markLessLikeThis(
        kind: RecoDomainKind,
        stableHash: String,
    ) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().lessLikeThis(kind.toEngineKind(), stableHash)
    }

    override suspend fun resetTaste(kind: RecoDomainKind) = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine().resetTaste(kind.toEngineKind())
    }
}

