package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.SearchOutcome
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.SearchRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import javax.inject.Inject

/**
 * Availability snapshot for the AI search toggle inside the Search popup.
 */
data class AiSearchStatus(
    val isAvailable: Boolean,
    val providerLabel: String,
    val autoSearch: Boolean,
    val blockerMessage: String? = null,
)

/**
 * Single responsibility (PRD-33 & PRD-37 § 6):
 * Instant local FTS/prompt search on every keystroke, plus optional AI prompt resolution
 * (strictly disabled on Kids profiles).
 */
class SearchCatalogUseCase @Inject constructor(
    private val searchRepository: SearchRepository,
    private val profilesRepository: ProfilesRepository,
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
) {
    suspend fun getAiSearchStatus(): AiSearchStatus {
        val activeProfile = profilesRepository.activeProfile()
        if (activeProfile.isKids) {
            return AiSearchStatus(
                isAvailable = false,
                providerLabel = "Désactivé (Enfants)",
                autoSearch = false,
                blockerMessage = "L'assistant IA est désactivé sur le profil Enfants.",
            )
        }
        val aiConfig = settingsRepository.currentPreferences().aiConfig
        if (aiConfig.provider == AiProviderType.NONE) {
            return AiSearchStatus(
                isAvailable = false,
                providerLabel = aiConfig.provider.displayName,
                autoSearch = false,
                blockerMessage = "Aucun fournisseur IA configuré. Choisissez-en un dans Réglages > Assistant IA.",
            )
        }
        val hasKey = !secretStore.getSecret(aiConfig.keyAlias).isNullOrBlank()
        val blocker = aiConfig.blocker(hasKey)
        return AiSearchStatus(
            isAvailable = blocker == null,
            providerLabel = aiConfig.provider.displayName,
            autoSearch = aiConfig.autoSearch,
            blockerMessage = blocker,
        )
    }

    suspend fun searchInstant(
        prompt: String,
        scope: SearchScopeKind = SearchScopeKind.ALL,
        locale: String = "fr",
        utcOffsetMinutes: Int = 0,
    ): SearchOutcome = searchRepository.searchLocal(
        prompt = prompt,
        scope = scope,
        locale = locale,
        utcOffsetMinutes = utcOffsetMinutes,
    )

    suspend fun searchSmart(
        prompt: String,
        scope: SearchScopeKind = SearchScopeKind.ALL,
        locale: String = "fr",
        utcOffsetMinutes: Int = 0,
    ): SearchOutcome {
        val activeProfile = profilesRepository.activeProfile()
        if (activeProfile.isKids) {
            return searchInstant(prompt, scope, locale, utcOffsetMinutes)
        }
        val aiConfig = settingsRepository.currentPreferences().aiConfig
        if (aiConfig.provider == AiProviderType.NONE) {
            return searchInstant(prompt, scope, locale, utcOffsetMinutes)
        }
        val apiKey = secretStore.getSecret(aiConfig.keyAlias).orEmpty()
        if (aiConfig.blocker(hasKey = apiKey.isNotBlank()) != null) {
            return searchInstant(prompt, scope, locale, utcOffsetMinutes)
        }
        return searchRepository.searchWithAi(
            prompt = prompt,
            scope = scope,
            locale = locale,
            utcOffsetMinutes = utcOffsetMinutes,
            aiConfig = aiConfig,
            apiKey = apiKey,
        )
    }
}

