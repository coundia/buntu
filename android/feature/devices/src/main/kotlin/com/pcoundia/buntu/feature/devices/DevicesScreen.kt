package com.pcoundia.buntu.feature.devices

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun DevicesRoute(
    onBack: () -> Unit,
    viewModel: DevicesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var showJoinDialog by remember { mutableStateOf(false) }
    var joinKeyInput by remember { mutableStateOf("") }
    var showLeaveConfirmDialog by remember { mutableStateOf(false) }

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
        item(key = "header") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Retour",
                        tint = BuntuPalette.PureWhite,
                    )
                }
                Spacer(modifier = Modifier.width(metrics.spacingM))
                Text(
                    text = "Appareils du foyer",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
            }
        }

        state.errorMessage?.let { err ->
            item(key = "error") {
                Surface(
                    color = Color(0xFF441B1B),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = err,
                        color = Color(0xFFFF8888),
                        modifier = Modifier.padding(12.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }

        state.infoMessage?.let { info ->
            item(key = "info") {
                Surface(
                    color = Color(0xFF1B3A2B),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = info,
                        color = BuntuPalette.LeerCyan,
                        modifier = Modifier.padding(12.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }

        if (!state.isJoined) {
            item(key = "not_joined") {
                DeviceSectionCard(title = "Aucun foyer configuré") {
                    Text(
                        text = "Reliez vos appareils Buntu (iPhone, Mac, TV, Android) sur le Wi-Fi de la maison, sans serveur : favoris, reprises de lecture, comptes IPTV et « Lire sur… ».",
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(modifier = Modifier.height(metrics.spacingM))
                    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
                        BuntuPrimaryActionButton(
                            label = "Créer un foyer",
                            onClick = viewModel::createHousehold,
                        )
                        OutlinedButton(onClick = { showJoinDialog = true }) {
                            Text("Rejoindre avec la clé…", color = BuntuPalette.PureWhite)
                        }
                    }
                }
            }
        } else {
            // Cet appareil
            item(key = "this_device") {
                DeviceSectionCard(title = "Cet appareil") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = deviceTypeIcon(state.deviceType),
                            contentDescription = null,
                            tint = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(32.dp),
                        )
                        Spacer(modifier = Modifier.width(metrics.spacingM))
                        Column {
                            Text(
                                text = state.deviceName,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = BuntuPalette.PureWhite,
                            )
                            state.householdId?.let { hId ->
                                Text(
                                    text = "Foyer ${hId.take(12)}…",
                                    style = MaterialTheme.typography.bodySmall,
                                    fontFamily = FontFamily.Monospace,
                                    color = BuntuPalette.MutedSilver,
                                )
                            }
                        }
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = if (state.peers.any { it.state != "offline" }) Icons.Default.Wifi else Icons.Default.WifiOff,
                            contentDescription = null,
                            tint = if (state.peers.any { it.state != "offline" }) Color(0xFF4CAF50) else BuntuPalette.MutedSilver,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(modifier = Modifier.width(metrics.spacingS))
                        Text(
                            text = state.syncStatus,
                            style = MaterialTheme.typography.bodySmall,
                            color = BuntuPalette.MutedSilver,
                        )
                    }
                }
            }

            // Appareils du foyer
            item(key = "peers_header") {
                Text(
                    text = "Appareils découverts",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.TerangaGold,
                )
            }

            if (state.peers.isEmpty()) {
                item(key = "no_peers") {
                    DeviceSectionCard(title = "") {
                        Text(
                            text = "Aucun autre appareil détecté pour l'instant.\nOuvrez Buntu sur votre iPhone, Mac ou Android TV sur le même réseau Wi-Fi.",
                            color = BuntuPalette.MutedSilver,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            } else {
                items(state.peers, key = { it.id }) { peer ->
                    PeerRow(peer = peer)
                }
            }

            // Actions
            item(key = "actions") {
                DeviceSectionCard(title = "Gestion du foyer") {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        OutlinedButton(onClick = viewModel::syncNow) {
                            Icon(Icons.Default.Refresh, contentDescription = null, tint = BuntuPalette.PureWhite)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Synchroniser maintenant", color = BuntuPalette.PureWhite)
                        }
                        OutlinedButton(onClick = {
                            coroutineScope.launch {
                                val key = viewModel.getHouseholdKeyHex()
                                if (key != null) {
                                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    clipboard.setPrimaryClip(ClipData.newPlainText("Buntu Household Key", key))
                                }
                            }
                        }) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, tint = BuntuPalette.PureWhite)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Copier la clé", color = BuntuPalette.PureWhite)
                        }
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Button(
                        onClick = { showLeaveConfirmDialog = true },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6B1D1D)),
                    ) {
                        Text("Quitter le foyer", color = Color.White)
                    }
                }
            }

            // Journal de synchronisation
            item(key = "log_header") {
                Text(
                    text = "Journal de synchronisation",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.TerangaGold,
                )
            }

            if (state.syncLog.isEmpty()) {
                item(key = "empty_log") {
                    Text(
                        text = "Aucun événement pour le moment.",
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            } else {
                items(state.syncLog.take(20), key = { it.id }) { entry ->
                    SyncLogRow(entry = entry)
                }
            }
        }
    }

    if (showJoinDialog) {
        AlertDialog(
            onDismissRequest = { showJoinDialog = false },
            title = { Text("Rejoindre un foyer") },
            text = {
                Column {
                    Text("Collez la clé affichée sur un autre appareil du foyer (64 caractères).")
                    Spacer(modifier = Modifier.height(8.dp))
                    OutlinedTextField(
                        value = joinKeyInput,
                        onValueChange = { joinKeyInput = it },
                        label = { Text("Clé du foyer") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                Button(onClick = {
                    viewModel.joinHousehold(joinKeyInput)
                    showJoinDialog = false
                    joinKeyInput = ""
                }) {
                    Text("Rejoindre")
                }
            },
            dismissButton = {
                TextButton(onClick = { showJoinDialog = false }) {
                    Text("Annuler")
                }
            },
        )
    }

    if (showLeaveConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showLeaveConfirmDialog = false },
            title = { Text("Quitter le foyer ?") },
            text = {
                Text("Cet appareil ne partagera plus ses favoris, reprises et comptes avec le foyer. Les autres appareils ne sont pas modifiés.")
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.leaveHousehold()
                        showLeaveConfirmDialog = false
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB00020)),
                ) {
                    Text("Quitter le foyer")
                }
            },
            dismissButton = {
                TextButton(onClick = { showLeaveConfirmDialog = false }) {
                    Text("Annuler")
                }
            },
        )
    }
}

@Composable
private fun PeerRow(peer: DiscoveredPeer) {
    val isOnline = peer.state != "offline"
    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = deviceTypeIcon(peer.deviceType),
                    contentDescription = null,
                    tint = if (isOnline) BuntuPalette.PureWhite else BuntuPalette.MutedSilver,
                    modifier = Modifier.size(28.dp),
                )
                Spacer(modifier = Modifier.width(12.dp))
                Column {
                    Text(
                        text = peer.name,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.Medium,
                        color = if (isOnline) BuntuPalette.PureWhite else BuntuPalette.MutedSilver,
                    )
                    Text(
                        text = if (isOnline) "Connecté" else "Dernière connexion récente",
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                }
            }

            Surface(
                color = if (isOnline) Color(0xFF1B5E20) else Color(0xFF333333),
                shape = RoundedCornerShape(16.dp),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Spacer(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(if (isOnline) Color(0xFF4CAF50) else Color.Gray),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = if (isOnline) "Disponible" else "Hors ligne",
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White,
                    )
                }
            }
        }
    }
}

@Composable
private fun SyncLogRow(entry: SyncLogEntry) {
    val timeFormat = remember { SimpleDateFormat("HH:mm:ss", Locale.getDefault()) }
    val formattedTime = remember(entry.timestamp) { timeFormat.format(Date(entry.timestamp)) }

    Surface(
        color = BuntuPalette.Slate,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(modifier = Modifier.padding(10.dp)) {
            Text(
                text = formattedTime,
                style = MaterialTheme.typography.labelSmall,
                color = BuntuPalette.MutedSilver,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = entry.message,
                style = MaterialTheme.typography.bodySmall,
                color = if (entry.isWarning) Color(0xFFFFB74D) else BuntuPalette.PureWhite,
            )
        }
    }
}

@Composable
private fun DeviceSectionCard(
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
            if (title.isNotEmpty()) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.TerangaGold,
                )
            }
            content()
        }
    }
}

private fun deviceTypeIcon(type: String): ImageVector {
    return when (type.lowercase()) {
        "tv" -> Icons.Default.Tv
        "desktop", "mac", "pc" -> Icons.Default.Computer
        else -> Icons.Default.PhoneAndroid
    }
}

