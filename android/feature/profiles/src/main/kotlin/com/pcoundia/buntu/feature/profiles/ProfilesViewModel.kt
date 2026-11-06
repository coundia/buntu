package com.pcoundia.buntu.feature.profiles

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pcoundia.buntu.core.domain.model.ProfileSummary
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@Immutable
data class ProfilesUiState(
    val profiles: ImmutableList<ProfileSummary> = persistentListOf(),
    val adultCategoriesUnlocked: Boolean = false,
    val hasParentalPin: Boolean = false,
    val newProfileName: String = "",
    val newProfileKids: Boolean = false,
    val pinInput: String = "",
    val statusMessage: String? = null,
)

@HiltViewModel
class ProfilesViewModel @Inject constructor(
    private val profilesRepository: ProfilesRepository,
    private val settingsRepository: SettingsRepository,
    private val secretStore: SecretStore,
) : ViewModel() {

    companion object {
        private const val PARENTAL_PIN_ALIAS = "cnd.parental.pin"
    }

    private val _uiState = MutableStateFlow(ProfilesUiState())
    val uiState: StateFlow<ProfilesUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            profilesRepository.profilesFlow.collect { list ->
                _uiState.update { it.copy(profiles = list) }
            }
        }
        viewModelScope.launch {
            val prefs = settingsRepository.currentPreferences()
            val existingPin = secretStore.getSecret(PARENTAL_PIN_ALIAS)
            profilesRepository.refreshProfiles()
            _uiState.update {
                it.copy(
                    adultCategoriesUnlocked = prefs.adultCategoriesUnlocked,
                    hasParentalPin = !existingPin.isNullOrEmpty(),
                )
            }
        }
    }

    fun updateNewProfile(name: String, isKids: Boolean) {
        _uiState.update { it.copy(newProfileName = name, newProfileKids = isKids) }
    }

    fun updatePinInput(pin: String) {
        _uiState.update { it.copy(pinInput = pin.filter(Char::isDigit).take(6), statusMessage = null) }
    }

    fun createProfile() {
        val name = _uiState.value.newProfileName.trim()
        if (name.isEmpty()) return
        val isKids = _uiState.value.newProfileKids
        viewModelScope.launch {
            profilesRepository.createProfile(
                name = name,
                avatar = if (isKids) "🧸" else "🎬",
                isKids = isKids,
            )
            _uiState.update { it.copy(newProfileName = "", newProfileKids = false) }
        }
    }

    fun selectProfile(profile: ProfileSummary) {
        viewModelScope.launch {
            // Leaving a Kids profile requires the parental PIN when one is configured (PRD-20 & 37.7)
            val currentActive = _uiState.value.profiles.firstOrNull { it.isActive }
            if (currentActive?.isKids == true && !profile.isKids && _uiState.value.hasParentalPin) {
                val savedPin = secretStore.getSecret(PARENTAL_PIN_ALIAS)
                if (savedPin != null && _uiState.value.pinInput != savedPin) {
                    _uiState.update { it.copy(statusMessage = "Saisissez le code PIN parental pour quitter le mode Enfants.") }
                    return@launch
                }
            }
            profilesRepository.selectProfile(profile.id)
            _uiState.update { it.copy(pinInput = "", statusMessage = "Profil « ${profile.name} » activé.") }
        }
    }

    fun saveOrVerifyPinAndToggleAdult() {
        viewModelScope.launch {
            val pin = _uiState.value.pinInput
            val savedPin = secretStore.getSecret(PARENTAL_PIN_ALIAS)
            if (savedPin.isNullOrEmpty()) {
                if (pin.length < 4) {
                    _uiState.update { it.copy(statusMessage = "Choisissez un code PIN d'au moins 4 chiffres.") }
                    return@launch
                }
                secretStore.putSecret(PARENTAL_PIN_ALIAS, pin)
                _uiState.update { it.copy(hasParentalPin = true, pinInput = "", statusMessage = "Code PIN enregistré dans le Keystore.") }
            } else if (pin == savedPin) {
                val nextVisible = !_uiState.value.adultCategoriesUnlocked
                profilesRepository.setAdultContentVisible(nextVisible)
                settingsRepository.setAdultCategoriesUnlocked(nextVisible)
                _uiState.update {
                    it.copy(
                        adultCategoriesUnlocked = nextVisible,
                        pinInput = "",
                        statusMessage = if (nextVisible) "Catégories adultes déverrouillées." else "Catégories adultes masquées.",
                    )
                }
            } else {
                _uiState.update { it.copy(statusMessage = "Code PIN incorrect.") }
            }
        }
    }
}

