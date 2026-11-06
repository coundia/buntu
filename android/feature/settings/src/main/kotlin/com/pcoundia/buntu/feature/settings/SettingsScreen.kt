package com.pcoundia.buntu.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.AiProviderType

@Composable
fun SettingsRoute(
    onOpenSources: () -> Unit,
    onOpenProfiles: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val prefs = state.preferences
    val metrics = LocalBuntuMetrics.current

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
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Réglages & Diagnostics",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    OutlinedButton(onClick = onOpenSources) {
                        Text("Sources IPTV", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = onOpenProfiles) {
                        Text("Profils", color = BuntuPalette.PureWhite)
                    }
                }
            }
        }

        // Connection Budget & Display Scale
        item(key = "budget_section", contentType = "settings_card") {
            SettingsCard(title = "Abonnement & Affichage") {
                Text(
                    text = "Connexions simultanées autorisées : ${prefs.assumedMaxConnections}",
                    color = BuntuPalette.PureWhite,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(1, 2, 3, 5).forEach { count ->
                        FilterChip(
                            selected = prefs.assumedMaxConnections == count,
                            onClick = { viewModel.setAssumedMaxConnections(count) },
                            label = { Text("$count conn.") },
                        )
                    }
                }

                Text("Taille d'interface", color = BuntuPalette.PureWhite)
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    listOf(0.9f to "Compact", 1.0f to "Normal", 1.15f to "Grand").forEach { (scale, label) ->
                        FilterChip(
                            selected = kotlin.math.abs(prefs.uiScale - scale) < 0.03f,
                            onClick = { viewModel.setUiScale(scale) },
                            label = { Text(label) },
                        )
                    }
                }

                if (!state.isTv) {
                    SettingToggleRow(
                        label = "Télécharger hors-ligne en 4G/5G",
                        checked = prefs.downloadOverCellular,
                        onCheckedChange = viewModel::setDownloadOverCellular,
                    )
                }
            }
        }

        // Android TV Home Cinema Options
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

        // BYOK AI Configuration
        item(key = "ai_section", contentType = "settings_card") {
            SettingsCard(title = "Recherche & Recommandations IA (optionnel, désactivé sur profil Enfants)") {
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    AiProviderType.entries.forEach { provider ->
                        FilterChip(
                            selected = prefs.aiConfig.provider == provider,
                            onClick = {
                                val defaultModel = when (provider) {
                                    AiProviderType.NONE -> ""
                                    AiProviderType.GEMINI -> "gemini-2.5-flash"
                                    AiProviderType.OPENAI_COMPATIBLE -> "gpt-4o-mini"
                                    AiProviderType.CLAUDE -> "claude-3-5-haiku-latest"
                                }
                                viewModel.updateAiProvider(
                                    provider = provider,
                                    model = prefs.aiConfig.model.ifBlank { defaultModel },
                                    endpoint = prefs.aiConfig.endpointUrl,
                                )
                            },
                            label = { Text(provider.name) },
                        )
                    }
                }

                if (prefs.aiConfig.provider != AiProviderType.NONE) {
                    OutlinedTextField(
                        value = prefs.aiConfig.model,
                        onValueChange = {
                            viewModel.updateAiProvider(prefs.aiConfig.provider, it, prefs.aiConfig.endpointUrl)
                        },
                        label = { Text("Modèle IA") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (prefs.aiConfig.provider == AiProviderType.OPENAI_COMPATIBLE) {
                        OutlinedTextField(
                            value = prefs.aiConfig.endpointUrl,
                            onValueChange = {
                                viewModel.updateAiProvider(prefs.aiConfig.provider, prefs.aiConfig.model, it)
                            },
                            label = { Text("URL Endpoint compatible OpenAI / Ollama") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    OutlinedTextField(
                        value = state.apiKeyDraft,
                        onValueChange = viewModel::updateApiKeyDraft,
                        label = {
                            Text(
                                if (state.hasSavedApiKey) "Clé API enregistrée dans Keystore (saisir pour remplacer)"
                                else "Clé API (chiffrée dans Android Keystore)",
                            )
                        },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    BuntuPrimaryActionButton(
                        label = "Enregistrer la clé API",
                        onClick = viewModel::saveApiKeyToKeystore,
                    )
                    state.statusMessage?.let { msg ->
                        Text(msg, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }

        // Diagnostics & JankStats
        item(key = "diag_section", contentType = "settings_card") {
            SettingsCard(title = "Diagnostics moteur & Fluidité") {
                Text(
                    text = "Moteur Rust : ${state.engineVersion} · Frames lentes (>16 ms) : ${state.frameStats.jankyFrames}/${state.frameStats.totalFrames} (%.1f%%)".format(
                        state.frameStats.jankPercent,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BuntuPalette.LeerCyan,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    OutlinedButton(onClick = viewModel::refreshDiagnostics) {
                        Text("Actualiser les journaux", color = BuntuPalette.PureWhite)
                    }
                    OutlinedButton(onClick = viewModel::clearDiagnostics) {
                        Text("Effacer", color = BuntuPalette.MutedSilver)
                    }
                }
            }
        }

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

@Composable
private fun SettingsCard(
    title: String,
    content: @Composable () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
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

