package com.pcoundia.buntu.feature.sources

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
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

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SourcesRoute(
    viewModel: SourcesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current
    val context = LocalContext.current

    if (state.pairToTv !is PairToTvUiState.Closed) {
        PairToTvBottomSheet(
            pairState = state.pairToTv,
            sources = state.sources,
            onDismiss = viewModel::closePairToTv,
            onScanQr = { viewModel.launchQrScanner(context) },
            onUpdateManualLink = viewModel::updateManualPairLink,
            onSubmitManualLink = viewModel::submitManualPairLink,
            onToggleSource = viewModel::togglePairSourceSelection,
            onToggleCredentials = viewModel::togglePairSourceCredentials,
            onSend = viewModel::sendPairedSourcesToTv,
            onRestartScan = viewModel::openPairToTv,
            onOpenAddSource = viewModel::closePairAndOpenAddSource,
        )
    }

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
            Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
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
                if (!state.isTv) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                        verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    ) {
                        OutlinedButton(onClick = viewModel::openPairToTv) {
                            Icon(
                                imageVector = Icons.Default.QrCodeScanner,
                                contentDescription = null,
                                tint = BuntuPalette.TerangaGold,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = "Envoyer vers une TV (QR)",
                                color = BuntuPalette.PureWhite,
                            )
                        }
                    }
                }
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
                    onConfirmPairing = viewModel::confirmIncomingPairing,
                    onRefusePairing = viewModel::refuseIncomingPairing,
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairToTvBottomSheet(
    pairState: PairToTvUiState,
    sources: List<SourceSummary>,
    onDismiss: () -> Unit,
    onScanQr: () -> Unit,
    onUpdateManualLink: (String) -> Unit,
    onSubmitManualLink: () -> Unit,
    onToggleSource: (Long) -> Unit,
    onToggleCredentials: (Long) -> Unit,
    onSend: () -> Unit,
    onRestartScan: () -> Unit,
    onOpenAddSource: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = BuntuPalette.Slate,
        contentColor = BuntuPalette.PureWhite,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = metrics.spacingL, vertical = metrics.spacingM)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
        ) {
            when (pairState) {
                PairToTvUiState.Closed -> Unit

                is PairToTvUiState.Scanning -> {
                    Text(
                        text = "Envoyer vos comptes vers une TV",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    Text(
                        text = "Ouvrez Buntu sur votre TV Samsung ou Android TV, affichez le QR code d'ajout, puis scannez-le avec ce téléphone (même Wi-Fi).",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.MutedSilver,
                    )
                    pairState.error?.let { BuntuErrorBanner(message = it) }

                    BuntuPrimaryActionButton(
                        label = if (pairState.isScannerRunning) "Ouverture du scanner…" else "Scanner le QR code de la TV",
                        enabled = !pairState.isScannerRunning,
                        onClick = onScanQr,
                    )

                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "Secours sans caméra :",
                        style = MaterialTheme.typography.labelMedium,
                        color = BuntuPalette.MutedSilver,
                    )
                    OutlinedTextField(
                        value = pairState.manualLink,
                        onValueChange = onUpdateManualLink,
                        label = { Text("Lien buntu://pair?…") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        OutlinedButton(
                            enabled = pairState.manualLink.isNotBlank(),
                            onClick = onSubmitManualLink,
                        ) {
                            Text("Continuer avec ce lien")
                        }
                        OutlinedButton(onClick = onDismiss) {
                            Text("Fermer")
                        }
                    }
                }

                is PairToTvUiState.Choosing -> {
                    val tvLabel = pairState.link.tvName.ifBlank { "votre TV" }
                    Text(
                        text = "Envoyer vers $tvLabel",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.TerangaGold,
                    )
                    Text(
                        text = "Chiffré de bout en bout · Confirmation requise avec la télécommande de la TV.",
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.LeerCyan,
                    )
                    pairState.error?.let { BuntuErrorBanner(message = it) }

                    if (sources.isEmpty()) {
                        Surface(
                            color = BuntuPalette.SlateElevated,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                modifier = Modifier.padding(metrics.spacingM),
                                verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            ) {
                                Text(
                                    text = "Aucun compte n'est encore configuré sur ce téléphone.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = BuntuPalette.PureWhite,
                                )
                                BuntuPrimaryActionButton(
                                    label = "Ajouter une source sur le téléphone",
                                    onClick = onOpenAddSource,
                                )
                            }
                        }
                    } else {
                        sources.forEach { source ->
                            val selected = source.id in pairState.selectedIds
                            val includeCreds = source.id in pairState.includeCredentialsIds
                            Surface(
                                color = BuntuPalette.SlateElevated,
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onToggleSource(source.id) },
                            ) {
                                Column(modifier = Modifier.padding(metrics.spacingM)) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        Checkbox(
                                            checked = selected,
                                            onCheckedChange = { onToggleSource(source.id) },
                                        )
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                text = source.name,
                                                style = MaterialTheme.typography.titleMedium,
                                                fontWeight = FontWeight.SemiBold,
                                                color = BuntuPalette.PureWhite,
                                            )
                                            Text(
                                                text = if (source.kind == SourceKind.XTREAM) "Xtream Codes" else "Playlist M3U",
                                                style = MaterialTheme.typography.bodySmall,
                                                color = BuntuPalette.MutedSilver,
                                            )
                                        }
                                    }
                                    if (selected && source.kind == SourceKind.XTREAM) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(start = 12.dp, top = 4.dp),
                                        ) {
                                            Text(
                                                text = "Inclure le mot de passe",
                                                style = MaterialTheme.typography.bodySmall,
                                                color = BuntuPalette.PureWhite,
                                            )
                                            Switch(
                                                checked = includeCreds,
                                                onCheckedChange = { onToggleCredentials(source.id) },
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        Text(
                            text = "Note : la plupart des abonnements IPTV limitent la lecture à 1 écran simultané.",
                            style = MaterialTheme.typography.bodySmall,
                            color = BuntuPalette.MutedSilver,
                        )

                        Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                            BuntuPrimaryActionButton(
                                label = "Envoyer (${pairState.selectedIds.size})",
                                enabled = pairState.selectedIds.isNotEmpty(),
                                onClick = onSend,
                            )
                            OutlinedButton(onClick = onDismiss) {
                                Text("Annuler")
                            }
                        }
                    }
                }

                is PairToTvUiState.WaitingForTv -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                    ) {
                        CircularProgressIndicator(
                            color = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(32.dp),
                        )
                        Text(
                            text = "En attente de confirmation sur ${pairState.tvName}…",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = BuntuPalette.PureWhite,
                        )
                    }
                    Text(
                        text = "Prenez la télécommande de la TV et choisissez « Ajouter » pour confirmer l'importation.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.MutedSilver,
                    )
                    Text(
                        text = "Astuce TV Samsung : si un bandeau système « Autoriser cet appareil » apparaît en haut de l'écran TV, sélectionnez Autoriser.",
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.TerangaGold,
                    )
                    OutlinedButton(onClick = onDismiss) {
                        Text("Annuler")
                    }
                }

                is PairToTvUiState.Done -> {
                    Text(
                        text = "Ajouté sur ${pairState.tvName}",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.LeerCyan,
                    )
                    Text(
                        text = "${pairState.addedCount} compte${if (pairState.addedCount > 1) "s ont été ajoutés" else " a été ajouté"} sur la TV. La synchronisation du catalogue a démarré.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.PureWhite,
                    )
                    BuntuPrimaryActionButton(label = "Terminé", onClick = onDismiss)
                }

                is PairToTvUiState.Refused -> {
                    Text(
                        text = "Refusé sur ${pairState.tvName}",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.TerangaGold,
                    )
                    Text(
                        text = "L'ajout des comptes a été refusé depuis la télécommande de la TV.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.MutedSilver,
                    )
                    OutlinedButton(onClick = onDismiss) {
                        Text("Fermer")
                    }
                }

                is PairToTvUiState.Failed -> {
                    Text(
                        text = "Envoi impossible",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.DangerRed,
                    )
                    BuntuErrorBanner(message = pairState.message)
                    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        BuntuPrimaryActionButton(
                            label = "Scanner un autre QR code",
                            onClick = onRestartScan,
                        )
                        OutlinedButton(onClick = onDismiss) {
                            Text("Fermer")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AddSourceCard(
    state: SourcesUiState,
    onUpdate: (SourceKind, String, String, String, String) -> Unit,
    onSubmit: () -> Unit,
    onConfirmPairing: () -> Unit = {},
    onRefusePairing: () -> Unit = {},
) {
    val metrics = LocalBuntuMetrics.current
    // A phone sent accounts: nothing is added before the user answers here (PRD-39 § 4.3).
    state.incomingPairing?.let { incoming ->
        Surface(color = BuntuPalette.Slate, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(metrics.spacingL),
                verticalArrangement = Arrangement.spacedBy(metrics.spacingM),
            ) {
                val count = incoming.sources.size
                Text(
                    text = "${incoming.from.ifBlank { "Un téléphone" }} veut ajouter $count compte${if (count > 1) "s" else ""}",
                    style = MaterialTheme.typography.titleMedium,
                    color = BuntuPalette.TerangaGold,
                )
                incoming.sources.forEach { source ->
                    Text(
                        text = "${source.name} · ${if (source.isXtream) "Xtream" else "M3U"} · ${source.host}" +
                            if (source.hasPassword) " · avec mot de passe" else "",
                        color = BuntuPalette.PureWhite,
                    )
                }
                BuntuPrimaryActionButton(label = "Ajouter", onClick = onConfirmPairing)
                OutlinedButton(onClick = onRefusePairing) { Text("Refuser") }
            }
        }
        return
    }
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
                        text = "Scannez ce QR code avec l'appareil photo de votre téléphone : l'application Buntu lui envoie vos comptes, chiffrés.",
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
