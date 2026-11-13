package com.pcoundia.buntu.core.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.model.UpNextPreferences
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * PRD-37 § 7:
 * UI preferences persisted via `DataStore<Preferences>`, read/written asynchronously off the main thread.
 * Secrets (Xtream passwords, AI API keys, parental PIN) are NEVER stored here — only Keystore aliases.
 */
@Singleton
class DataStoreSettingsRepository @Inject constructor(
    private val dataStore: DataStore<Preferences>,
) : SettingsRepository {

    private object Keys {
        val ONBOARDING_COMPLETED = booleanPreferencesKey("onboarding_completed")
        val ASSUMED_MAX_CONNECTIONS = intPreferencesKey("assumed_max_connections")
        val UI_SCALE = floatPreferencesKey("ui_scale")
        val TV_AUTO_FRAME_RATE = booleanPreferencesKey("tv_auto_frame_rate")
        val TV_AUDIO_PASSTHROUGH = booleanPreferencesKey("tv_audio_passthrough")
        val TV_TUNNELING = booleanPreferencesKey("tv_tunneling")
        val DOWNLOAD_CELLULAR = booleanPreferencesKey("download_over_cellular")
        val ADULT_UNLOCKED = booleanPreferencesKey("adult_categories_unlocked")
        val LAST_CHANNEL_ID = longPreferencesKey("last_channel_id")

        val AI_PROVIDER = stringPreferencesKey("ai_provider")
        val AI_MODEL = stringPreferencesKey("ai_model")
        val AI_ENDPOINT = stringPreferencesKey("ai_endpoint")
        val AI_SEND_RECENT = booleanPreferencesKey("ai_send_recent_titles")
        val AI_CONSENT = booleanPreferencesKey("ai_consent")
        val AI_AUTO_SEARCH = booleanPreferencesKey("ai_auto_search")

        val UPNEXT_SHELF = booleanPreferencesKey("upnext_shelf_enabled")
        val UPNEXT_CARD = booleanPreferencesKey("upnext_card_enabled")
        val UPNEXT_AUTOPLAY = booleanPreferencesKey("upnext_autoplay_enabled")
        val UPNEXT_COUNTDOWN = intPreferencesKey("upnext_countdown_seconds")
    }

    override val preferencesFlow: Flow<AppPreferences> = dataStore.data
        .map { prefs -> prefs.toAppPreferences() }
        .flowOn(Dispatchers.IO)

    override suspend fun currentPreferences(): AppPreferences =
        withContext(Dispatchers.IO) {
            preferencesFlow.first()
        }

    override suspend fun setOnboardingCompleted(completed: Boolean) = updatePref {
        it[Keys.ONBOARDING_COMPLETED] = completed
    }

    override suspend fun setAssumedMaxConnections(limit: Int) = updatePref {
        it[Keys.ASSUMED_MAX_CONNECTIONS] = limit.coerceIn(1, 10)
    }

    override suspend fun setUiScale(scale: Float) = updatePref {
        it[Keys.UI_SCALE] = scale.coerceIn(0.85f, 1.35f)
    }

    override suspend fun setTvPlaybackOptions(
        autoFrameRate: Boolean,
        audioPassthrough: Boolean,
        tunneling: Boolean,
    ) = updatePref {
        it[Keys.TV_AUTO_FRAME_RATE] = autoFrameRate
        it[Keys.TV_AUDIO_PASSTHROUGH] = audioPassthrough
        it[Keys.TV_TUNNELING] = tunneling
    }

    override suspend fun setDownloadOverCellular(allowed: Boolean) = updatePref {
        it[Keys.DOWNLOAD_CELLULAR] = allowed
    }

    override suspend fun setAdultCategoriesUnlocked(unlocked: Boolean) = updatePref {
        it[Keys.ADULT_UNLOCKED] = unlocked
    }

    override suspend fun setLastChannelId(channelId: Long) = updatePref {
        it[Keys.LAST_CHANNEL_ID] = channelId
    }

    override suspend fun updateAiConfig(config: AiSettingsConfig) = updatePref {
        it[Keys.AI_PROVIDER] = config.provider.name
        it[Keys.AI_MODEL] = config.model
        it[Keys.AI_ENDPOINT] = config.endpointUrl
        it[Keys.AI_SEND_RECENT] = config.sendRecentTitles
        it[Keys.AI_CONSENT] = config.consent
        it[Keys.AI_AUTO_SEARCH] = config.autoSearch
    }

    override suspend fun setUpNextPreferences(preferences: UpNextPreferences) = updatePref {
        it[Keys.UPNEXT_SHELF] = preferences.shelfEnabled
        it[Keys.UPNEXT_CARD] = preferences.nextUpCardEnabled
        it[Keys.UPNEXT_AUTOPLAY] = preferences.autoPlayNext
        it[Keys.UPNEXT_COUNTDOWN] = preferences.countdownSeconds.coerceIn(3, 60)
    }

    private suspend inline fun updatePref(crossinline block: (androidx.datastore.preferences.core.MutablePreferences) -> Unit) {
        withContext(Dispatchers.IO) {
            dataStore.edit { block(it) }
        }
    }

    private fun Preferences.toAppPreferences(): AppPreferences {
        val provider = this[Keys.AI_PROVIDER]?.let { raw ->
            runCatching { AiProviderType.valueOf(raw) }.getOrNull()
        } ?: AiProviderType.NONE

        return AppPreferences(
            onboardingCompleted = this[Keys.ONBOARDING_COMPLETED] ?: false,
            assumedMaxConnections = (this[Keys.ASSUMED_MAX_CONNECTIONS] ?: 1).coerceIn(1, 10),
            uiScale = (this[Keys.UI_SCALE] ?: 1.0f).coerceIn(0.85f, 1.35f),
            autoFrameRateMatchingTv = this[Keys.TV_AUTO_FRAME_RATE] ?: true,
            audioPassthroughTv = this[Keys.TV_AUDIO_PASSTHROUGH] ?: true,
            tunnelingEnabledTv = this[Keys.TV_TUNNELING] ?: true,
            downloadOverCellular = this[Keys.DOWNLOAD_CELLULAR] ?: false,
            adultCategoriesUnlocked = this[Keys.ADULT_UNLOCKED] ?: false,
            lastChannelId = this[Keys.LAST_CHANNEL_ID],
            aiConfig = AiSettingsConfig(
                provider = provider,
                model = this[Keys.AI_MODEL].orEmpty(),
                endpointUrl = this[Keys.AI_ENDPOINT].orEmpty(),
                sendRecentTitles = this[Keys.AI_SEND_RECENT] ?: false,
                consent = this[Keys.AI_CONSENT] ?: true,
                autoSearch = this[Keys.AI_AUTO_SEARCH] ?: true,
            ),
            upNext = UpNextPreferences(
                shelfEnabled = this[Keys.UPNEXT_SHELF] ?: true,
                nextUpCardEnabled = this[Keys.UPNEXT_CARD] ?: true,
                autoPlayNext = this[Keys.UPNEXT_AUTOPLAY] ?: true,
                countdownSeconds = (this[Keys.UPNEXT_COUNTDOWN] ?: UpNextPreferences.DEFAULT_COUNTDOWN_SECONDS)
                    .coerceIn(3, 60),
            ),
        )
    }
}

