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
                    text = "Réglages",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    OutlinedButton(onClick = onOpenDevices) {
                        Text("Appareils & Foyer", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenRemoteCommand) {
                        Text("Commande TV", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenSources) {
                        Text("Sources IPTV", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenProfiles) {
                        Text("Profils & Bouquets", color = BuntuPalette.PureWhite)
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
                title = "Assistant IA (Recherche, Commandes & Recommandations)",
                subtitle = "Désactivé automatiquement sur le profil Enfants.",
            ) {
                Text("Fournisseur", color = BuntuPalette.PureWhite, fontWeight = FontWeight.Medium)
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
                            Text("Modèle (par défaut : ${aiConfig.provider.defaultModel})")
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
                        label = { Text("Adresse du serveur (optionnel)") },
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
                                state.hasSavedApiKey ->
                                    "Clé API enregistrée dans Keystore (saisir pour remplacer)"
                                aiConfig.provider.requiresApiKey ->
                                    "Clé API (chiffrée dans Android Keystore)"
                                else ->
                                    "Clé API facultative (chiffrée dans Android Keystore)"
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
                                    text = if (state.showApiKey) "Masquer" else "Afficher",
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
                            label = "Enregistrer la clé API",
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
                                Text("Test en cours…", color = BuntuPalette.PureWhite)
                            } else {
                                Text("Tester l'IA", color = BuntuPalette.PureWhite)
                            }
                        }
                        if (state.hasSavedApiKey) {
                            OutlinedButton(onClick = viewModel::deleteApiKeyFromKeystore) {
                                Text("Supprimer la clé", color = BuntuPalette.DangerRed)
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
                            text = "🔒 Serveur sur cet appareil ou réseau local : rien ne quitte votre réseau.",
                            color = BuntuPalette.SuccessGreen,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Medium,
                        )
                    } else {
                        SettingToggleRow(
                            label = "J'accepte d'envoyer mes commandes à ce fournisseur",
                            checked = aiConfig.consent,
                            onCheckedChange = viewModel::setAiConsent,
                        )
                    }

                    SettingToggleRow(
                        label = "Chercher avec l'assistant pendant la saisie",
                        checked = aiConfig.autoSearch,
                        onCheckedChange = viewModel::setAiAutoSearch,
                    )

                    if (!effectiveAiConfig.isEndpointLocal) {
                        SettingToggleRow(
                            label = "Envoyer mes derniers titres regardés à l'IA distante (« Pour vous »)",
                            checked = aiConfig.sendRecentTitles,
                            onCheckedChange = viewModel::setAiSendRecentTitles,
                        )
                    }

                    if (blocker != null) {
                        Text(
                            text = "ℹ️ $blocker En attendant, la résolution reste locale.",
                            color = BuntuPalette.MutedSilver,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }

                    OutlinedButton(onClick = { showAiPrivacyDetails = !showAiPrivacyDetails }) {
                        Text(
                            text = if (showAiPrivacyDetails) "Masquer « Ce qui est envoyé »" else "Ce qui est envoyé",
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
                                    text = "Envoyé",
                                    color = BuntuPalette.LeerCyan,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(
                                    text = "• la phrase que vous tapez\n• pour 40 chaînes ou titres au plus : nom, catégorie, numéro, programme en cours et suivant\n• la langue de l'interface",
                                    color = BuntuPalette.MutedSilver,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                                Text(
                                    text = "Jamais envoyé",
                                    color = BuntuPalette.TerangaGold,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(
                                    text = "• les adresses des flux et le serveur IPTV\n• identifiants, mots de passe, en-têtes\n• l'historique complet, les favoris hors propositions, les téléchargements",
                                    color = BuntuPalette.MutedSilver,
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                } else {
                    Text(
                        text = "Les commandes explicites (« France 2 », « chaîne 6 », « suivante ») et la recherche instantanée sont résolues sur l'appareil, sans aucun envoi. Choisissez un fournisseur pour les demandes plus libres.",
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
                title = "Recommandations, « À suivre » & « Pour vous »",
                subtitle = "Les films, les séries et la TV ont chacun leurs goûts et leurs rangées : ils ne se mélangent jamais.",
            ) {
                SettingToggleRow(
                    label = "Afficher « À suivre » sous le lecteur",
                    checked = upNext.shelfEnabled,
                    onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(shelfEnabled = it)) },
                )
                SettingToggleRow(
                    label = "Carte « Film suivant » en fin de lecture",
                    checked = upNext.nextUpCardEnabled,
                    onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(nextUpCardEnabled = it)) },
                )
                if (upNext.nextUpCardEnabled) {
                    SettingToggleRow(
                        label = "Lecture automatique du titre suivant",
                        checked = upNext.autoPlayNext,
                        onCheckedChange = { viewModel.setUpNextPreferences(upNext.copy(autoPlayNext = it)) },
                    )
                    if (upNext.autoPlayNext) {
                        Text("Compte à rebours", color = BuntuPalette.PureWhite)
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
                    text = "Réinitialiser les recommandations",
                    color = BuntuPalette.PureWhite,
                    fontWeight = FontWeight.Medium,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    OutlinedButton(onClick = viewModel::resetDismissedRecommendations) {
                        Text("Réinitialiser « Pas intéressé »", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.MOVIES) }) {
                        Text("Goûts : Films", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.SERIES) }) {
                        Text("Goûts : Séries", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = { viewModel.resetTaste(RecoDomainKind.LIVE_TV) }) {
                        Text("Goûts : TV", color = BuntuPalette.PureWhite)
                    }
                }

                state.recoFeedbackMessage?.let { msg ->
                    Text(msg, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodySmall)
                }
            }
        }

        // 3. Abonnement, Téléchargements & Réseau (`RuntimeSettings` de `cnd-core`)
        item(key = "budget_section", contentType = "settings_card") {
            SettingsCard(title = "Abonnement, Téléchargements & Réseau") {
                Text(
                    text = "Connexions de mon abonnement : ${prefs.assumedMaxConnections}",
                    color = BuntuPalette.PureWhite,
                    fontWeight = FontWeight.Medium,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(1, 2, 3, 5, 10).forEach { count ->
                        FilterChip(
                            selected = prefs.assumedMaxConnections == count,
                            onClick = { viewModel.setAssumedMaxConnections(count) },
                            label = { Text("$count conn.") },
                        )
                    }
                }
                Text(
                    text = if (budget.pausesDownloadsDuringPlayback) {
                        "Avec une seule connexion, un téléchargement ne peut pas tourner pendant une lecture : il est mis en pause puis repris à la fin. Si votre abonnement en autorise plusieurs, indiquez-le ci-dessus."
                    } else {
                        "Une connexion reste libre pour regarder : les téléchargements en utilisent au plus ${budget.downloadConnections} ensemble."
                    },
                    color = BuntuPalette.MutedSilver,
                    style = MaterialTheme.typography.bodySmall,
                )

                Text(
                    text = "Segments par fichier : ${runtime.segmentsPerFile} · Taille d'une partie : ${runtime.partSizeMb} Mo · Fichiers simultanés : ${runtime.maxActiveFiles}",
                    color = BuntuPalette.PureWhite,
                    style = MaterialTheme.typography.bodySmall,
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(4, 8, 16, 32).forEach { mb ->
                        FilterChip(
                            selected = runtime.partSizeMb == mb,
                            onClick = { viewModel.updateDownloadEngineSettings(partSizeMb = mb) },
                            label = { Text("Partie $mb Mo") },
                        )
                    }
                }

                if (!state.isTv) {
                    SettingToggleRow(
                        label = "Autoriser les téléchargements cellulaires (4G/5G)",
                        checked = prefs.downloadOverCellular,
                        onCheckedChange = viewModel::setDownloadOverCellular,
                    )
                }

                OutlinedTextField(
                    value = runtime.defaultUserAgent,
                    onValueChange = { viewModel.updateNetworkHeaders(it, runtime.defaultReferer) },
                    label = { Text("User-Agent HTTP") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = runtime.defaultReferer,
                    onValueChange = { viewModel.updateNetworkHeaders(runtime.defaultUserAgent, it) },
                    label = { Text("Referer HTTP (optionnel)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        // 4. Apparence & Contrôle parental
        item(key = "appearance_parental_section", contentType = "settings_card") {
            SettingsCard(title = "Apparence & Contrôle parental") {
                Text("Taille de l'interface", color = BuntuPalette.PureWhite, fontWeight = FontWeight.Medium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(0.9f to "Compact", 1.0f to "Standard", 1.15f to "Grand").forEach { (scale, label) ->
                        FilterChip(
                            selected = kotlin.math.abs(prefs.uiScale - scale) < 0.03f,
                            onClick = { viewModel.setUiScale(scale) },
                            label = { Text(label) },
                        )
                    }
                }

                SettingToggleRow(
                    label = "Afficher les catégories adultes (+18)",
                    checked = prefs.adultCategoriesUnlocked,
                    onCheckedChange = viewModel::setAdultCategoriesUnlocked,
                )
                Text(
                    text = "Les catégories adultes sont masquées par défaut partout, recherche comprise, et ne sont jamais montrées au profil Enfants.",
                    color = BuntuPalette.MutedSilver,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        // 5. Métadonnées OMDb & Sous-titres OpenSubtitles
        item(key = "metadata_subtitles_section", contentType = "settings_card") {
            SettingsCard(
                title = "Métadonnées OMDb & Sous-titres OpenSubtitles",
                subtitle = "Clés conservées dans Android Keystore, jamais dans la base de données.",
            ) {
                OutlinedTextField(
                    value = state.omdbKeyDraft,
                    onValueChange = viewModel::updateOmdbKeyDraft,
                    label = {
                        Text(
                            if (state.hasSavedOmdbKey) "Clé API OMDb enregistrée (saisir pour remplacer)"
                            else "Clé API OMDb (enrichit les fiches films et séries)",
                        )
                    },
                    visualTransformation = if (state.showOmdbKey) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        TextButton(onClick = viewModel::toggleShowOmdbKey) {
                            Text(if (state.showOmdbKey) "Masquer" else "Afficher", color = BuntuPalette.LeerCyan)
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(onClick = viewModel::saveOmdbKey) {
                    Text(
                        text = if (state.omdbKeyDraft.isBlank() && state.hasSavedOmdbKey) "Supprimer la clé OMDb" else "Enregistrer la clé OMDb",
                        color = BuntuPalette.PureWhite,
                    )
                }

                OutlinedTextField(
                    value = state.openSubtitlesKeyDraft,
                    onValueChange = viewModel::updateOpenSubtitlesKeyDraft,
                    label = {
                        Text(
                            if (state.hasSavedOpenSubtitlesKey) "Clé API OpenSubtitles enregistrée (saisir pour remplacer)"
                            else "Clé API OpenSubtitles (sous-titres en ligne)",
                        )
                    },
                    visualTransformation = if (state.showOpenSubtitlesKey) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        TextButton(onClick = viewModel::toggleShowOpenSubtitlesKey) {
                            Text(if (state.showOpenSubtitlesKey) "Masquer" else "Afficher", color = BuntuPalette.LeerCyan)
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedButton(onClick = viewModel::saveOpenSubtitlesKey) {
                    Text(
                        text = if (state.openSubtitlesKeyDraft.isBlank() && state.hasSavedOpenSubtitlesKey) "Supprimer la clé OpenSubtitles" else "Enregistrer la clé OpenSubtitles",
                        color = BuntuPalette.PureWhite,
                    )
                }
            }
        }

        // 6. Android TV Home Cinema Options
        if (state.isTv) {
            item(key = "tv_section", contentType = "settings_card") {
                SettingsCard(title = "Android TV · Home Cinéma") {
                    SettingToggleRow(
                        label = "Adaptation automatique de fréquence HDMI (24p / 50 Hz / 60 Hz)",
                        checked = prefs.autoFrameRateMatchingTv,
                        onCheckedChange = {
                            viewModel.setTvOptions(it, prefs.audioPassthroughTv, prefs.tunnelingEnabledTv)
                        },
                    )
                    SettingToggleRow(
                        label = "Passthrough audio HDMI (AC3 / E-AC3 / DTS)",
                        checked = prefs.audioPassthroughTv,
                        onCheckedChange = {
                            viewModel.setTvOptions(prefs.autoFrameRateMatchingTv, it, prefs.tunnelingEnabledTv)
                        },
                    )
                    SettingToggleRow(
                        label = "Décodage matériel tunnelisé 4K HDR",
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
                title = "À propos de ${BuntuAboutInfo.APP_NAME}",
                subtitle = BuntuAboutInfo.SLOGAN,
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
                            text = "Créateur : ${BuntuAboutInfo.AUTHOR_NAME}",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = "E-mail : ${BuntuAboutInfo.AUTHOR_EMAIL}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.LeerCyan,
                        )
                        Text(
                            text = "Pays : ${BuntuAboutInfo.AUTHOR_COUNTRY}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = "Version : ${BuntuAboutInfo.APP_VERSION} (build ${BuntuAboutInfo.APP_BUILD})",
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                        Text(
                            text = "Licence : ${BuntuAboutInfo.LICENSE}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.PureWhite,
                        )
                    }
                }
                Text(
                    text = BuntuAboutInfo.LEGAL_NOTICE,
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
            SettingsCard(title = "À propos & Diagnostics moteur") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                ) {
                    BuntuBrandMark(logoSize = 36.dp)
                    Text(
                        text = "Lecteur IPTV natif — Moteur Rust & Jetpack Compose",
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                }
                Text(
                    text = "Moteur Rust : ${state.engineVersion} · Frames lentes (>16 ms) : ${state.frameStats.jankyFrames}/${state.frameStats.totalFrames} (%.1f%%)".format(
                        state.frameStats.jankPercent,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BuntuPalette.LeerCyan,
                )
                Text(
                    text = "Base de données : $dbSizeFormatted · Sources : ${stats.totalSources}\n" +
                        "Chaînes / Films / Séries : ${stats.totalLiveChannels} / ${stats.totalMovies} / ${stats.totalSeries}\n" +
                        "Favoris / En panne : ${stats.totalFavorites} / ${stats.totalBroken}",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = BuntuPalette.PureWhite,
                )

                SettingToggleRow(
                    label = "Afficher la console réseau",
                    checked = runtime.showNetworkConsole,
                    onCheckedChange = viewModel::setShowNetworkConsole,
                )

                FlowRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    OutlinedButton(onClick = viewModel::refreshDiagnostics) {
                        Text("Actualiser les journaux", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = viewModel::clearDiagnostics) {
                        Text("Effacer", color = BuntuPalette.MutedSilver)
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


