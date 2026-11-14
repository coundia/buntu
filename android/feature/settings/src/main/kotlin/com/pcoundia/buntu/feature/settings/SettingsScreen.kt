package com.pcoundia.buntu.feature.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuBrandMark
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.designsystem.i18n.AppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.AppLanguageState
import com.pcoundia.buntu.core.designsystem.i18n.rememberAppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.t
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.ConnectionBudget
import com.pcoundia.buntu.core.domain.model.RecoDomainKind
import com.pcoundia.buntu.core.domain.model.UpNextPreferences

internal object BuntuAboutInfo {
    const val APP_NAME = "Buntu"
    const val APP_VERSION = "1.0.0"
    const val APP_BUILD = "1"
    const val SLOGAN = "Sa bunt ci lépp — La porte d'entrée de tous vos médias."
    const val AUTHOR_NAME = "Papa COUNDIA"
    const val AUTHOR_EMAIL = "papacoundia@gmail.com"
    const val AUTHOR_COUNTRY = "Sénégal"
    const val LICENSE = "MIT / Apache-2.0"
    const val LEGAL_NOTICE =
        "Buntu est un lecteur neutre : il ne fournit aucun contenu et lit uniquement les sources que vous ajoutez. Vos données restent sur votre appareil."
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsRoute(
    onOpenSources: () -> Unit,
    onOpenProfiles: () -> Unit,
    onOpenDevices: () -> Unit = {},
    onOpenRemoteCommand: () -> Unit = {},
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val prefs = state.preferences
    val aiConfig = prefs.aiConfig
    val runtime = state.runtimeConfig
    val stats = state.dbStats
    val budget = ConnectionBudget(prefs.assumedMaxConnections)
    val metrics = LocalBuntuMetrics.current
    val context = LocalContext.current
    val currentLanguage = rememberAppLanguage()
    var showAiPrivacyDetails by remember { mutableStateOf(false) }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(
            horizontal = metrics.horizontalScreenPadding,
            vertical = metrics.verticalScreenPadding,
        ),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingL),
    ) {
        item(key = "settings_hdr", contentType = "header") {
            Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
                Text(
                    text = t("settings.title"),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    OutlinedButton(onClick = onOpenDevices) {
                        Text(t("settings.nav.devices"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenRemoteCommand) {
                        Text(t("settings.nav.remote"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenSources) {
                        Text(t("settings.nav.sources"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenProfiles) {
                        Text(t("settings.nav.profiles"), color = BuntuPalette.PureWhite)
                    }
                }
            }
        }

        // 0. Langue / Language
        item(key = "language_section", contentType = "settings_card") {
            SettingsCard(
                title = t("settings.language.title"),
                subtitle = t("settings.language.subtitle"),
            ) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                ) {
                    AppLanguage.entries.forEach { lang ->
                        FilterChip(
                            selected = currentLanguage == lang,
                            onClick = { AppLanguageState.setLanguage(lang, context) },
                            label = { Text(lang.label) },
                        )
                    }
                }
            }
        }

        // 1. Assistant IA (Recherche, Commandes & Recommandations) — aligné sur Buntu for macOS
        item(key = "ai_section", contentType = "settings_card") {
            val effectiveAiConfig = aiConfig.copy(
                model = state.aiModelDraft,
                endpointUrl = state.aiEndpointDraft,
            )
            val hasEffectiveKey = state.hasSavedApiKey || state.apiKeyDraft.isNotBlank()
            val blocker = effectiveAiConfig.blocker(hasKey = hasEffectiveKey)

            SettingsCard(
                title = t("settings.ai.title"),
                subtitle = t("settings.ai.subtitle"),
            ) {
                Text(t("settings.ai.provider"), color = BuntuPalette.PureWhite, fontWeight = FontWeight.Medium)
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                ) {
                    AiProviderType.entries.forEach { provider ->
                        FilterChip(
                            selected = aiConfig.provider == provider,
                            onClick = {
                                viewModel.updateAiProvider(
                                    provider = provider,
                                    model = state.aiModelDraft,
                                    endpoint = state.aiEndpointDraft,
                                )
                            },
                            label = { Text(provider.displayName) },
                        )
                    }
                }

                if (aiConfig.provider.isRemote) {
                    OutlinedTextField(
                        value = state.aiModelDraft,
                        onValueChange = viewModel::updateAiModelDraft,
                        label = {
                            Text(t("settings.ai.model_label", aiConfig.provider.defaultModel))
                        },
                        placeholder = { Text(aiConfig.provider.defaultModel) },
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Ascii,
                            imeAction = ImeAction.Done,
                        ),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    OutlinedTextField(
                        value = state.aiEndpointDraft,
                        onValueChange = viewModel::updateAiEndpointDraft,
                        label = { Text(t("settings.ai.endpoint_label")) },
                        placeholder = { Text(aiConfig.provider.endpointPlaceholder) },
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Uri,
                            imeAction = ImeAction.Done,
                        ),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    OutlinedTextField(
                        value = state.apiKeyDraft,
                        onValueChange = viewModel::updateApiKeyDraft,
                        label = {
                            val labelText = when {
                                state.hasSavedApiKey -> t("settings.ai.key_saved")
                                aiConfig.provider.requiresApiKey -> t("settings.ai.key_required")
                                else -> t("settings.ai.key_optional")
                            }
                            Text(labelText)
                        },
                        visualTransformation = if (state.showApiKey) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        trailingIcon = {
                            TextButton(onClick = viewModel::toggleShowApiKey) {
                                Text(
                                    text = if (state.showApiKey) t("settings.ai.hide") else t("settings.ai.show"),
                                    color = BuntuPalette.LeerCyan,
                                )
                            }
                        },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                        verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    ) {
                        BuntuPrimaryActionButton(
                            label = t("settings.ai.save_key"),
                            onClick = viewModel::saveApiKeyToKeystore,
                        )
                        OutlinedButton(
                            onClick = viewModel::testAiProvider,
                            enabled = !state.isTestingAi && (!aiConfig.provider.requiresApiKey || hasEffectiveKey),
                        ) {
                            if (state.isTestingAi) {
                                CircularProgressIndicator(
                                    color = BuntuPalette.LeerCyan,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(t("settings.ai.testing"), color = BuntuPalette.PureWhite)
                            } else {
                                Text(t("settings.ai.test_btn"), color = BuntuPalette.PureWhite)
                            }
                        }
                        if (state.hasSavedApiKey) {
                            OutlinedButton(onClick = viewModel::deleteApiKeyFromKeystore) {
                                Text(t("settings.ai.delete_key"), color = BuntuPalette.DangerRed)
                            }
                        }
                    }

                    state.aiTestResult?.let { testResult ->
                        val accent = if (testResult.ok) BuntuPalette.SuccessGreen else BuntuPalette.DangerRed
                        val prefix = if (testResult.ok) "✓" else "✗"
                        val summary = if (testResult.ok) {
                            "$prefix ${testResult.message} (${testResult.latencyMs} ms · ${testResult.model})"
                        } else {
                            "$prefix ${testResult.message}"
                        }
                        Surface(
                            color = BuntuPalette.Midnight,
                            border = BorderStroke(1.dp, accent),
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = summary,
                                color = accent,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.padding(metrics.spacingM),
                            )
                        }
                    }

                    state.statusMessage?.let { msg ->
                        Text(msg, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodySmall)
                    }

                    if (effectiveAiConfig.isEndpointLocal) {
                        Text(
                            text = t("settings.ai.local_notice"),
                            color = BuntuPalette.SuccessGreen,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Medium,
                        )
                    } else {
                        SettingToggleRow(
                            label = t("settings.ai.consent"),
                            checked = aiConfig.consent,
                            onCheckedChange = viewModel::setAiConsent,
                        )
                    }

                    SettingToggleRow(
                        label = t("settings.ai.auto_search"),
                        checked = aiConfig.autoSearch,
                        onCheckedChange = viewModel::setAiAutoSearch,
                    )

                    if (!effectiveAiConfig.isEndpointLocal) {
                        SettingToggleRow(
                            label = t("settings.ai.send_recent"),
                            checked = aiConfig.sendRecentTitles,
                            onCheckedChange = viewModel::setAiSendRecentTitles,
                        )
                    }

                    if (blocker != null) {
                        Text(
                            text = t("settings.ai.blocker_suffix", blocker),
                            color = BuntuPalette.MutedSilver,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }

                    OutlinedButton(onClick = { showAiPrivacyDetails = !showAiPrivacyDetails }) {
                        Text(
                            text = if (showAiPrivacyDetails) t("settings.ai.privacy_hide") else t("settings.ai.privacy_show"),
                            color = BuntuPalette.PureWhite,
                        )
                    }

                    if (showAiPrivacyDetails) {
                        Surface(
                            color = BuntuPalette.Midnight,
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                modifier = Modifier.padding(metrics.spacingM),
                                verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                            ) {
                                Text(
                                    text = t("settings.ai.privacy_sent_title"),
                                    color = BuntuPalette.LeerCyan,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(
                                    text = t("settings.ai.privacy_sent_body"),
                                    color = BuntuPalette.MutedSilver,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                                Text(
                                    text = t("settings.ai.privacy_never_title"),
                                    color = BuntuPalette.TerangaGold,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(
                                    text = t("settings.ai.privacy_never_body"),
                                    color = BuntuPalette.MutedSilver,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                } else {
                    Text(
                        text = t("settings.ai.local_only_hint"),
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        // 2. Lecture, « À suivre » & Recommandations « Pour vous » (PRD-27 & PRD-34)
        item(key = "upnext_section", contentType = "settings_card") {
            val upNext = prefs.upNext
            SettingsCard(
                title = t("settings.reco.title"),
                subtitle = t("settings.reco.subtitle"),
            ) {
                SettingToggleRow(
                    label = t("settings.reco.shelf_enabled"),
                    checked = upNext.shelfEnabled,
                    onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(shelfEnabled = it)) },
                )
                SettingToggleRow(
                    label = t("settings.reco.next_up_card"),
                    checked = upNext.nextUpCardEnabled,
                    onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(nextUpCardEnabled = it)) },
                )
                if (upNext.nextUpCardEnabled) {
                    SettingToggleRow(
                        label = t("settings.reco.autoplay"),
                        checked = upNext.autoPlayNext,
                        onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(autoPlayNext = it)) },
                    )
                    if (upNext.autoPlayNext) {
                        Text(t("settings.reco.countdown"), color = BuntuPalette.PureWhite)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                            UpNextPreferences.COUNTDOWN_CHOICES.forEach { secs ->
                                FilterChip(
                                    selected = upNext.countdownSeconds == secs,
                                    onClick = { viewModel.setUpNextPreferences(upNext.copy(countdownSeconds = secs)) },
                                    label = { Text("$secs s") },
                                )
                            }
                        }
                    }
                }

                Text(
                    text = t("settings.reco.reset_title"),
                    color = BuntuPalette.PureWhite,
                    fontWeight = FontWeight.Medium,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    OutlinedButton(onClick = viewModel::resetDismissedRecommendations) {
                        Text(t("settings.reco.reset_dismissed"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.MOVIES) }) {
                        Text(t("settings.reco.reset_movies"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.SERIES) }) {
                        Text(t("settings.reco.reset_series"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.LIVE_TV) }) {
                        Text(t("settings.reco.reset_live"), color = BuntuPalette.PureWhite)
                    }
                }

                state.recoFeedbackMessage?.let { msg ->
                    Text(msg, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodySmall)
                }
            }
        }

        // 3. Abonnement, Téléchargements & Réseau (`RuntimeSettings` de `cnd-core`)
        item(key = "budget_section", contentType = "settings_card") {
            SettingsCard(title = t("settings.network.title")) {
                Text(
                    text = t("settings.network.connections", prefs.assumedMaxConnections),
                    color = BuntuPalette.PureWhite,
                    fontWeight = FontWeight.Medium,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(1, 2, 3, 5, 10).forEach { count ->
                        FilterChip(
                            selected = prefs.assumedMaxConnections == count,
                            onClick = { viewModel.setAssumedMaxConnections(count) },
                            label = { Text(t("settings.network.conn_chip", count)) },
                        )
                    }
                }
                Text(
                    text = if (budget.pausesDownloadsDuringPlayback) {
                        t("settings.network.single_conn_hint")
                    } else {
                        t("settings.network.multi_conn_hint", budget.downloadConnections)
                    },
                    color = BuntuPalette.MutedSilver,
                    style = MaterialTheme.typography.bodySmall,
                )

                Text(
                    text = t(
                        "settings.network.segments_summary",
                        runtime.segmentsPerFile,
                        runtime.partSizeMb,
                        runtime.maxActiveFiles,
                    ),
                    color = BuntuPalette.PureWhite,
                    style = MaterialTheme.typography.bodySmall,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(4, 8, 16, 32).forEach { mb ->
                        FilterChip(
                            selected = runtime.partSizeMb == mb,
                            onClick = { viewModel.updateDownloadEngineSettings(partSizeMb = mb) },
                            label = { Text(t("settings.network.part_chip", mb)) },
                        )
                    }
                }

                if (!state.isTv) {
                    SettingToggleRow(
                        label = t("settings.network.cellular"),
                        checked = prefs.downloadOverCellular,
                        onCheckedChange = viewModel::setDownloadOverCellular,
                    )
                }

                OutlinedTextField(
                    value = runtime.defaultUserAgent,
                    onValueChange = { viewModel.updateNetworkHeaders(it, runtime.defaultReferer) },
                    label = { Text(t("settings.network.user_agent")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = runtime.defaultReferer,
                    onValueChange = { viewModel.updateNetworkHeaders(runtime.defaultUserAgent, it) },
                    label = { Text(t("settings.network.referer")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        // 4. Apparence & Contrôle parental
        item(key = "appearance_parental_section", contentType = "settings_card") {
            SettingsCard(title = t("settings.appearance.title")) {
                Text(t("settings.appearance.ui_scale"), color = BuntuPalette.PureWhite, fontWeight = FontWeight.Medium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(
                        0.9f to t("settings.appearance.scale_compact"),
                        1.0f to t("settings.appearance.scale_standard"),
                        1.15f to t("settings.appearance.scale_large"),
                    ).forEach { (scale, label) ->
                        FilterChip(
                            selected = kotlin.math.abs(prefs.uiScale - scale) < 0.03f,
                            onClick = { viewModel.setUiScale(scale) },
                            label = { Text(label) },
                        )
                    }
                }

                SettingToggleRow(
                    label = t("settings.appearance.adult_toggle"),
                    checked = prefs.adultCategoriesUnlocked,
                    onCheckedChange = viewModel::setAdultCategoriesUnlocked,
                )
                Text(
                    text = t("settings.appearance.adult_hint"),
                    color = BuntuPalette.MutedSilver,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        // 5. Métadonnées OMDb & Sous-titres OpenSubtitles
        item(key = "metadata_subtitles_section", contentType = "settings_card") {
            SettingsCard(
                title = t("settings.meta.title"),
                subtitle = t("settings.meta.subtitle"),
            ) {
                OutlinedTextField(
                    value = state.omdbKeyDraft,
                    onValueChange = viewModel::updateOmdbKeyDraft,
                    label = {
                        Text(
                            if (state.hasSavedOmdbKey) t("settings.meta.omdb_saved")
                            else t("settings.meta.omdb_hint"),
                        )
                    },
                    visualTransformation = if (state.showOmdbKey) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        TextButton(onClick = viewModel::toggleShowOmdbKey) {
                            Text(
                                if (state.showOmdbKey) t("settings.ai.hide") else t("settings.ai.show"),
                                color = BuntuPalette.LeerCyan,
                            )
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(onClick = viewModel::saveOmdbKey) {
                    Text(
                        text = if (state.omdbKeyDraft.isBlank() && state.hasSavedOmdbKey) t("settings.meta.omdb_delete") else t("settings.meta.omdb_save"),
                        color = BuntuPalette.PureWhite,
                    )
                }

                OutlinedTextField(
                    value = state.openSubtitlesKeyDraft,
                    onValueChange = viewModel::updateOpenSubtitlesKeyDraft,
                    label = {
                        Text(
                            if (state.hasSavedOpenSubtitlesKey) t("settings.meta.os_saved")
                            else t("settings.meta.os_hint"),
                        )
                    },
                    visualTransformation = if (state.showOpenSubtitlesKey) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        TextButton(onClick = viewModel::toggleShowOpenSubtitlesKey) {
                            Text(
                                if (state.showOpenSubtitlesKey) t("settings.ai.hide") else t("settings.ai.show"),
                                color = BuntuPalette.LeerCyan,
                            )
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(onClick = viewModel::saveOpenSubtitlesKey) {
                    Text(
                        text = if (state.openSubtitlesKeyDraft.isBlank() && state.hasSavedOpenSubtitlesKey) t("settings.meta.os_delete") else t("settings.meta.os_save"),
                        color = BuntuPalette.PureWhite,
                    )
                }
            }
        }

        // 6. Android TV Home Cinema Options
        if (state.isTv) {
            item(key = "tv_section", contentType = "settings_card") {
                SettingsCard(title = t("settings.tv.title")) {
                    SettingToggleRow(
                        label = t("settings.tv.afr"),
                        checked = prefs.autoFrameRateMatchingTv,
                        onCheckedChange = {
                            viewModel.setTvOptions(it, prefs.audioPassthroughTv, prefs.tunnelingEnabledTv)
                        },
                    )
                    SettingToggleRow(
                        label = t("settings.tv.passthrough"),
                        checked = prefs.audioPassthroughTv,
                        onCheckedChange = {
                            viewModel.setTvOptions(prefs.autoFrameRateMatchingTv, it, prefs.tunnelingEnabledTv)
                        },
                    )
                    SettingToggleRow(
                        label = t("settings.tv.tunneling"),
                        checked = prefs.tunnelingEnabledTv,
                        onCheckedChange = {
                            viewModel.setTvOptions(prefs.autoFrameRateMatchingTv, prefs.audioPassthroughTv, it)
                        },
                    )
                }
            }
        }

        // 7. À propos de Buntu
        item(key = "about_section", contentType = "settings_card") {
            SettingsCard(
                title = t("settings.about.title", BuntuAboutInfo.APP_NAME),
                subtitle = t("settings.about.slogan"),
                focusable = state.isTv,
            ) {
                BuntuBrandMark(logoSize = 40.dp)
                Surface(
                    color = BuntuPalette.Midnight,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(metrics.spacingM),
                        verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                    ) {
                        Text(
                            text = t("settings.about.creator", BuntuAboutInfo.AUTHOR_NAME),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = t("settings.about.email", BuntuAboutInfo.AUTHOR_EMAIL),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.LeerCyan,
                        )
                        Text(
                            text = t("settings.about.country", t("settings.about.country_value")),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = t("settings.about.version", BuntuAboutInfo.APP_VERSION, BuntuAboutInfo.APP_BUILD),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = t("settings.about.license", BuntuAboutInfo.LICENSE),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                    }
                }
                Text(
                    text = t("settings.about.legal"),
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.MutedSilver,
                )
            }
        }

        // 8. Diagnostics moteur, À propos & Statistiques (`DbStats`)
        item(key = "diag_section", contentType = "settings_card") {
            val dbSizeFormatted = remember(stats.dbSizeBytes) {
                when {
                    stats.dbSizeBytes >= 1024L * 1024L -> "%.1f Mo".format(stats.dbSizeBytes / (1024.0 * 1024.0))
                    stats.dbSizeBytes >= 1024L -> "${stats.dbSizeBytes / 1024L} Ko"
                    else -> "${stats.dbSizeBytes} o"
                }
            }
            SettingsCard(title = t("settings.diag.title")) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                ) {
                    BuntuBrandMark(logoSize = 36.dp)
                    Text(
                        text = t("settings.diag.subtitle"),
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                }
                Text(
                    text = t(
                        "settings.diag.engine",
                        state.engineVersion,
                        state.frameStats.jankyFrames,
                        state.frameStats.totalFrames,
                        state.frameStats.jankPercent,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BuntuPalette.LeerCyan,
                )
                Text(
                    text = t(
                        "settings.diag.db",
                        dbSizeFormatted,
                        stats.totalSources,
                        stats.totalLiveChannels,
                        stats.totalMovies,
                        stats.totalSeries,
                        stats.totalFavorites,
                        stats.totalBroken,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = BuntuPalette.PureWhite,
                )

                SettingToggleRow(
                    label = t("settings.diag.console"),
                    checked = runtime.showNetworkConsole,
                    onCheckedChange = viewModel::setShowNetworkConsole,
                )

                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    OutlinedButton(onClick = viewModel::refreshDiagnostics) {
                        Text(t("settings.diag.refresh"), color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = viewModel::clearDiagnostics) {
                        Text(t("settings.diag.clear"), color = BuntuPalette.MutedSilver)
                    }
                }
            }
        }

        if (runtime.showNetworkConsole || state.networkLogs.isNotEmpty()) {
            items(
                items = state.networkLogs.take(25),
                key = { it.seqId },
                contentType = { "network_log_row" },
            ) { log ->
                Surface(
                    color = BuntuPalette.Slate,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = "[${log.level}] ${log.category} · ${log.statusCode ?: "-"} · ${log.redactedUrl ?: ""} ${log.message}",
                        style = MaterialTheme.typography.labelSmall,
                        color = BuntuPalette.MutedSilver,
                        modifier = Modifier.padding(10.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SettingsCard(
    title: String,
    subtitle: String? = null,
    focusable: Boolean = false,
    content: @Composable () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    var isFocused by remember { mutableStateOf(false) }
    val cardModifier = if (focusable) {
        Modifier
            .fillMaxWidth()
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
    } else {
        Modifier.fillMaxWidth()
    }
    Surface(
        color = BuntuPalette.Slate,
        border = if (focusable && isFocused) BorderStroke(2.dp, BuntuPalette.TerangaGold) else null,
        shape = RoundedCornerShape(16.dp),
        modifier = cardModifier,
    ) {
        Column(
            modifier = Modifier.padding(metrics.spacingL),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.TerangaGold,
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.MutedSilver,
                )
            }
            content()
        }
    }
}

@Composable
private fun SettingToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = BuntuPalette.PureWhite,
            modifier = Modifier.weight(1f),
        )
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}


