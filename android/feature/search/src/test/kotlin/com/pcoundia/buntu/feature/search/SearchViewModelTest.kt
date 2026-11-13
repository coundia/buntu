package com.pcoundia.buntu.feature.search

import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.model.SearchHitItem
import com.pcoundia.buntu.core.domain.model.SearchHitKind
import com.pcoundia.buntu.core.domain.model.SearchOutcome
import com.pcoundia.buntu.core.domain.model.SearchScopeKind
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.SearchRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.SearchCatalogUseCase
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SearchViewModelTest {

    private val testDispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `voice transcript triggers smart search while respecting Kids profile AI block`() = runTest {
        var aiCalled = false
        val searchRepo = object : SearchRepository {
            override suspend fun searchLocal(
                prompt: String,
                scope: SearchScopeKind,
                locale: String,
                utcOffsetMinutes: Int,
            ): SearchOutcome = SearchOutcome(
                query = prompt,
                hits = persistentListOf(
                    SearchHitItem(
                        id = 7L,
                        seriesId = null,
                        stableHash = "kirikou",
                        kind = SearchHitKind.MOVIE,
                        title = "Kirikou et la Sorcière",
                        subtitle = "1998",
                        posterUrl = null,
                        reason = "Titre exact",
                        startEpochSecs = null,
                        endEpochSecs = null,
                    )
                ),
                resolvedBy = "local",
            )

            override suspend fun searchWithAi(
                prompt: String,
                scope: SearchScopeKind,
                locale: String,
                utcOffsetMinutes: Int,
                aiConfig: AiSettingsConfig,
                apiKey: String,
            ): SearchOutcome {
                aiCalled = true
                return SearchOutcome(query = prompt, hits = persistentListOf(), resolvedBy = "ai")
            }
        }
        val kidsProfileRepo = object : ProfilesRepository {
            override val profilesFlow: Flow<ImmutableList<ProfileSummary>> = flowOf(persistentListOf())
            override suspend fun refreshProfiles(): ImmutableList<ProfileSummary> = persistentListOf()
            override suspend fun activeProfile(): ProfileSummary =
                ProfileSummary(2L, "Enfants", "🧸", isKids = true, isActive = true)
            override suspend fun selectProfile(profileId: Long) = Unit
            override suspend fun createProfile(name: String, avatar: String, isKids: Boolean) = activeProfile()
            override suspend fun deleteProfile(profileId: Long) = Unit
            override suspend fun setAdultContentVisible(visible: Boolean) = Unit
            override suspend fun setGroupAllowedForKids(profileId: Long, kind: String, groupName: String, allowed: Boolean) = Unit
        }
        val settingsRepo = object : SettingsRepository {
            private val p = AppPreferences(
                aiConfig = AiSettingsConfig(provider = AiProviderType.GEMINI, model = "gemini-2.5-flash"),
            )
            override val preferencesFlow: Flow<AppPreferences> = flowOf(p)
            override suspend fun currentPreferences(): AppPreferences = p
            override suspend fun setOnboardingCompleted(completed: Boolean) = Unit
            override suspend fun setAssumedMaxConnections(limit: Int) = Unit
            override suspend fun setUiScale(scale: Float) = Unit
            override suspend fun setTvPlaybackOptions(autoFrameRate: Boolean, audioPassthrough: Boolean, tunneling: Boolean) = Unit
            override suspend fun setDownloadOverCellular(allowed: Boolean) = Unit
            override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = Unit
            override suspend fun setLastChannelId(channelId: Long) = Unit
            override suspend fun updateAiConfig(config: AiSettingsConfig) = Unit
            override suspend fun setUpNextPreferences(preferences: com.pcoundia.buntu.core.domain.model.UpNextPreferences) = Unit
        }
        val secretStore = object : SecretStore {
            override suspend fun putSecret(alias: String, plaintext: String) = Unit
            override suspend fun getSecret(alias: String): String = "secret-key"
            override suspend fun deleteSecret(alias: String) = Unit
        }

        val vm = SearchViewModel(
            SearchCatalogUseCase(searchRepo, kidsProfileRepo, settingsRepo, secretStore),
        )
        vm.applyVoiceTranscript("Kirikou")

        assertFalse(aiCalled)
        assertEquals(1, vm.uiState.value.hits.size)
        assertEquals("Kirikou et la Sorcière", vm.uiState.value.hits.first().title)
    }
}

