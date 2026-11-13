package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.RecoShelfGroup
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import javax.inject.Inject

/**
 * Single responsibility (PRD-34 & PRD-37 § 12):
 * Emits fast local recommendation shelves for a single `RecoDomainKind` (never mixed),
 * then optionally refines with the user's AI provider — strictly skipped on Kids profiles.
 */
class LoadShelvesUseCase @Inject constructor(
    private val recommendationsRepository: RecommendationsRepository,
    private val profilesRepository: ProfilesRepository,
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
) {
    operator fun invoke(
        kind: RecoDomainKind,
        limitPerShelf: Int = 16,
        locale: String = "fr",
        utcOffsetMinutes: Int = 0,
    ): Flow<ImmutableList<RecoShelfGroup>> = flow {
        val localShelves = recommendationsRepository.loadLocalShelves(
            kind = kind,
            limitPerShelf = limitPerShelf,
            utcOffsetMinutes = utcOffsetMinutes,
        )
        emit(localShelves)

        val activeProfile = profilesRepository.activeProfile()
        if (activeProfile.isKids) {
            // Non-negotiable guardrail (PRD-37 § 12): never call remote AI for Kids profile.
            return@flow
        }

        val prefs = settingsRepository.currentPreferences()
        val aiConfig = prefs.aiConfig
        if (aiConfig.provider == AiProviderType.NONE) return@flow
        if (!aiConfig.consent && !aiConfig.isEndpointLocal) return@flow

        val apiKey = secretStore.getSecret(aiConfig.keyAlias).orEmpty()
        if (apiKey.isBlank() && aiConfig.provider != AiProviderType.OPENAI_COMPATIBLE) {
            return@flow
        }

        val refined = recommendationsRepository.refineShelvesWithAi(
            kind = kind,
            aiConfig = aiConfig,
            apiKey = apiKey,
            limitPerShelf = limitPerShelf,
            locale = locale,
            utcOffsetMinutes = utcOffsetMinutes,
        )
        if (refined != localShelves) {
            emit(refined)
        }
    }
}

