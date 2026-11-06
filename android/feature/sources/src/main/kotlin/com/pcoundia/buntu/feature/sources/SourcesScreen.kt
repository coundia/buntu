package com.pcoundia.buntu.feature.sources

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuEmptyState
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.domain.model.SourceSummary

@Composable
fun SourcesRoute(
    viewModel: SourcesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight),
        contentPadding = PaddingValues(
            horizontal = metrics.horizontalScreenPadding,
            vertical = metrics.verticalScreenPadding,
        ),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
    ) {
        item(key = "header", contentType = "sources_header") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Sources IPTV",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                BuntuPrimaryActionButton(
                    label = if (state.showAddForm) "Fermer" else "Ajouter une source",
                    onClick = { viewModel.toggleAddForm(!state.showAddForm) },
                )
            }
        }

        state.errorMessage?.let { err ->
            item(key = "error", contentType = "banner") {
                BuntuErrorBanner(message = err)
            }
        }

        state.statusMessage?.let { msg ->
            item(key = "status", contentType = "banner") {
                Surface(color = BuntuPalette.SlateElevated, shape = RoundedCornerShape(10.dp)) {
                    Text(
                        text = msg,
                        color = BuntuPalette.LeerCyan,
                        modifier = Modifier.padding(metrics.spacingM),
                    )
                }
            }
        }

        if (state.showAddForm) {
            item(key = "add_form", contentType = "add_source_form") {
                AddSourceCard(
                    state = state,
                    onUpdate = viewModel::updateNewSourceForm,
                    onSubmit = viewModel::addSource,
                )
            }
        }

        if (state.sources.isEmpty() && !state.showAddForm) {
            item(key = "empty", contentType = "empty_state") {
                BuntuEmptyState(
                    title = "Aucune source configurée",
                    subtitle = "Ajoutez un compte Xtream Codes, une playlist M3U ou scannez un QR code.",
                    actionLabel = "Ajouter une source",
                    onAction = { viewModel.toggleAddForm(true) },
                )
            }
        }

        items(
            items = state.sources,
            key = { it.id },
            contentType = { "source_card" },
        ) { source ->
            SourceRowCard(
                source = source,
                isSyncing = state.isSyncing,
                onSync = { viewModel.refreshSource(source) },
                onDelete = { viewModel.deleteSource(source.id) },
            )
        }
    }
}

@Composable
private fun AddSourceCard(
    state: SourcesUiState,
    onUpdate: (SourceKind, String, String, String, String) -> Unit,
    onSubmit: () -> Unit,
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
            if (state.isTv && state.qrMatrix != null && state.pairingUrl != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(136.dp)
                            .background(Color.White, RoundedCornerShape(8.dp))
                            .padding(6.dp),
                    ) {
                        Canvas(modifier = Modifier.fillMaxSize()) {
                            val cellW = size.width / state.qrMatrix.size.toFloat()
                            val cellH = size.height / state.qrMatrix.size.toFloat()
                            for (y in 0 until state.qrMatrix.size) {
                                for (x in 0 until state.qrMatrix.size) {
                                    if (state.qrMatrix.pixels[y * state.qrMatrix.size + x]) {
                                        drawRect(
                                            color = Color.Black,
                                            topLeft = Offset(x * cellW, y * cellH),
                                            size = Size(cellW + 0.5f, cellH + 0.5f),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Spacer(modifier = Modifier.width(metrics.spacingM))
                    Text(
                        text = "Scannez avec votre téléphone (${state.pairingUrl}) pour envoyer vos identifiants sans clavier TV.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.PureWhite,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                FilterChip(
                    selected = state.newKind == SourceKind.XTREAM,
                    onClick = { onUpdate(SourceKind.XTREAM, state.newName, state.newServerOrUrl, state.newUsername, state.newPassword) },
                    label = { Text("Xtream Codes") },
                )
                FilterChip(
                    selected = state.newKind == SourceKind.M3U,
                    onClick = { onUpdate(SourceKind.M3U, state.newName, state.newServerOrUrl, state.newUsername, state.newPassword) },
                    label = { Text("Playlist M3U") },
                )
            }

            OutlinedTextField(
                value = state.newName,
                onValueChange = { onUpdate(state.newKind, it, state.newServerOrUrl, state.newUsername, state.newPassword) },
                label = { Text("Nom") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = state.newServerOrUrl,
                onValueChange = { onUpdate(state.newKind, state.newName, it, state.newUsername, state.newPassword) },
                label = { Text(if (state.newKind == SourceKind.XTREAM) "Serveur Xtream" else "URL M3U") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (state.newKind == SourceKind.XTREAM) {
                OutlinedTextField(
                    value = state.newUsername,
                    onValueChange = { onUpdate(state.newKind, state.newName, state.newServerOrUrl, it, state.newPassword) },
                    label = { Text("Identifiant") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = state.newPassword,
                    onValueChange = { onUpdate(state.newKind, state.newName, state.newServerOrUrl, state.newUsername, it) },
                    label = { Text("Mot de passe") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            if (state.isSyncing) {
                CircularProgressIndicator(color = BuntuPalette.TerangaGold, modifier = Modifier.size(28.dp))
            } else {
                BuntuPrimaryActionButton(label = "Enregistrer et synchroniser", onClick = onSubmit)
            }
        }
    }
}

@Composable
private fun SourceRowCard(
    source: SourceSummary,
    isSyncing: Boolean,
    onSync: () -> Unit,
    onDelete: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(metrics.spacingM)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = source.name,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    Text(
                        text = "${source.kind.name} · ${source.accountStatus ?: "Prêt"} · Connexions max : ${source.maxConnections ?: 1}",
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                    BuntuPrimaryActionButton(
                        label = "Synchroniser",
                        enabled = !isSyncing,
                        onClick = onSync,
                    )
                    OutlinedButton(onClick = onDelete) {
                        Text("Supprimer", color = BuntuPalette.DangerRed)
                    }
                }
            }
        }
    }
}

