package com.pcoundia.buntu.feature.devices

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.designsystem.i18n.AppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.rememberAppLanguage
import com.pcoundia.buntu.core.designsystem.i18n.t
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import com.pcoundia.buntu.core.platform.tv.QrMatrix
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
    val currentLanguage = rememberAppLanguage()
    val coroutineScope = rememberCoroutineScope()

    var showJoinDialog by remember { mutableStateOf(false) }
    var joinKeyInput by remember { mutableStateOf("") }
    var showLeaveConfirmDialog by remember { mutableStateOf(false) }
    var remoteCommandText by remember { mutableStateOf("") }
    var speechUnavailable by remember { mutableStateOf(false) }

    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val results = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            val spoken = results?.firstOrNull { it.isNotBlank() }?.trim()
            if (!spoken.isNullOrEmpty()) {
                remoteCommandText = spoken
                viewModel.sendRemoteText(spoken)
            }
        }
    }

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
                        contentDescription = t("common.back"),
                        tint = BuntuPalette.PureWhite,
                    )
                }
                Spacer(modifier = Modifier.width(metrics.spacingM))
                Text(
                    text = t("devices.title"),
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

        if (!state.isTv) {
            item(key = "scan_send_tv") {
                DeviceSectionCard(title = t("devices.scan_send_title")) {
                    OutlinedButton(
                        onClick = { viewModel.scanAndSend(context) },
                        enabled = !state.isScanning,
                    ) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = null, tint = BuntuPalette.PureWhite)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            if (state.isScanning) t("devices.scan_send_busy") else t("devices.scan_send_btn"),
                            color = BuntuPalette.PureWhite,
                        )
                    }
                    Text(t("devices.scan_send_hint"), color = BuntuPalette.MutedSilver)
                }
            }
        }

        if (!state.isJoined) {
            item(key = "not_joined") {
                DeviceSectionCard(title = t("devices.not_joined_title")) {
                    Text(
                        text = t("devices.not_joined_desc"),
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(modifier = Modifier.height(metrics.spacingM))
                    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        BuntuPrimaryActionButton(
                            label = t("devices.create_household"),
                            onClick = viewModel::createHousehold,
                        )
                        // Android TV has no camera: there, the phone scans the code shown by the TV.
                        if (!state.isTv) {
                            OutlinedButton(
                                onClick = { viewModel.scanToJoin(context) },
                                enabled = !state.isScanning,
                            ) {
                                Icon(Icons.Default.QrCodeScanner, contentDescription = null, tint = BuntuPalette.PureWhite)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(t("devices.scan_qr"), color = BuntuPalette.PureWhite)
                            }
                        }
                        OutlinedButton(onClick = { showJoinDialog = true }) {
                            Text(t("devices.join_with_key"), color = BuntuPalette.PureWhite)
                        }
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Text(
                        text = t("devices.join_hint"),
                        color = BuntuPalette.MutedSilver,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        } else {
            // Cet appareil
            item(key = "this_device") {
                DeviceSectionCard(title = t("devices.this_device")) {
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
                                    text = t("devices.household_id", hId.take(12)),
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

            if (!state.isTv) {
                item(key = "remote_text") {
                    DeviceSectionCard(title = t("devices.remote_title")) {
                        OutlinedTextField(
                            value = remoteCommandText,
                            onValueChange = { remoteCommandText = it },
                            label = { Text(t("devices.remote_field_label")) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                            keyboardActions = KeyboardActions(
                                onSend = {
                                    if (remoteCommandText.isNotBlank()) {
                                        viewModel.sendRemoteText(remoteCommandText)
                                        remoteCommandText = ""
                                    }
                                },
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            OutlinedButton(
                                onClick = {
                                    val speechLang = if (currentLanguage == AppLanguage.EN) "en-US" else "fr-FR"
                                    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                                        putExtra(
                                            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                                        )
                                        putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLang)
                                    }
                                    try {
                                        speechUnavailable = false
                                        speechLauncher.launch(intent)
                                    } catch (_: ActivityNotFoundException) {
                                        speechUnavailable = true
                                    }
                                },
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Mic,
                                    contentDescription = null,
                                    tint = BuntuPalette.PureWhite,
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(t("devices.dictate"), color = BuntuPalette.PureWhite, maxLines = 1)
                            }
                            BuntuPrimaryActionButton(
                                label = t("devices.send_to_tv"),
                                enabled = remoteCommandText.isNotBlank(),
                                onClick = {
                                    viewModel.sendRemoteText(remoteCommandText)
                                    remoteCommandText = ""
                                },
                                modifier = Modifier.weight(1f),
                            )
                        }
                        if (speechUnavailable) {
                            Text(
                                text = t("devices.speech_unavailable"),
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFFFFB74D),
                            )
                        }
                    }
                }
            }

            // Appareils du foyer
            item(key = "peers_header") {
                val refreshCd = t("devices.refresh_cd")
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = t("devices.discovered_title"),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.TerangaGold,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        onClick = viewModel::refreshPeers,
                        modifier = Modifier.semantics {
                            contentDescription = refreshCd
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = null,
                            tint = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(t("common.refresh"), color = BuntuPalette.TerangaGold)
                    }
                }
            }

            if (state.peers.isEmpty()) {
                item(key = "no_peers") {
                    DeviceSectionCard(title = "") {
                        Text(
                            text = t("devices.no_peers"),
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
                DeviceSectionCard(title = t("devices.actions_title")) {
                    // One button per line: both stay readable on a small phone.
                    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
                        // Two additive buttons instead of "Synchroniser": nothing is ever deleted, an account is
                        // never duplicated (merged by identity in Rust).
                        OutlinedButton(onClick = viewModel::sendNow) {
                            Icon(Icons.Default.Upload, contentDescription = null, tint = BuntuPalette.PureWhite)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(t("devices.send_data"), color = BuntuPalette.PureWhite)
                        }
                        OutlinedButton(onClick = viewModel::receiveNow) {
                            Icon(Icons.Default.Download, contentDescription = null, tint = BuntuPalette.PureWhite)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(t("devices.receive_data"), color = BuntuPalette.PureWhite)
                        }
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Text(
                        text = t("devices.additive_hint"),
                        style = MaterialTheme.typography.bodySmall,
                        color = BuntuPalette.MutedSilver,
                    )
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
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
                            Text(t("devices.copy_key"), color = BuntuPalette.PureWhite)
                        }
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    OutlinedButton(onClick = viewModel::showInviteQr) {
                        Icon(Icons.Default.QrCode, contentDescription = null, tint = BuntuPalette.PureWhite)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(t("devices.show_qr"), color = BuntuPalette.PureWhite)
                    }
                    Spacer(modifier = Modifier.height(metrics.spacingS))
                    Button(
                        onClick = { showLeaveConfirmDialog = true },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6B1D1D)),
                    ) {
                        Text(t("devices.leave_household"), color = Color.White)
                    }
                }
            }

            // Journal de synchronisation
            item(key = "log_header") {
                Text(
                    text = t("devices.sync_log_title"),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.TerangaGold,
                )
            }

            if (state.syncLog.isEmpty()) {
                item(key = "empty_log") {
                    Text(
                        text = t("devices.sync_log_empty"),
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
            title = { Text(t("devices.join_dialog_title")) },
            text = {
                Column {
                    Text(t("devices.join_dialog_body"))
                    Spacer(modifier = Modifier.height(8.dp))
                    OutlinedTextField(
                        value = joinKeyInput,
                        onValueChange = { joinKeyInput = it },
                        label = { Text(t("devices.join_dialog_label")) },
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
                    Text(t("devices.join_dialog_confirm"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showJoinDialog = false }) {
                    Text(t("common.cancel"))
                }
            },
        )
    }

    state.inviteQr?.let { qr ->
        AlertDialog(
            onDismissRequest = viewModel::hideInviteQr,
            title = { Text(t("devices.qr_dialog_title")) },
            text = {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    HouseholdQrCode(
                        matrix = qr,
                        modifier = Modifier.size(if (state.isTv) 280.dp else 240.dp),
                    )
                    Text(t("devices.qr_dialog_hint"))
                    Text(
                        text = t("devices.qr_dialog_warning"),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = viewModel::hideInviteQr) {
                    Text(t("common.close"))
                }
            },
        )
    }

    if (showLeaveConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showLeaveConfirmDialog = false },
            title = { Text(t("devices.leave_dialog_title")) },
            text = {
                Text(t("devices.leave_dialog_body"))
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.leaveHousehold()
                        showLeaveConfirmDialog = false
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB00020)),
                ) {
                    Text(t("devices.leave_household"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showLeaveConfirmDialog = false }) {
                    Text(t("common.cancel"))
                }
            },
        )
    }
}

private val QUICK_REMOTE_COMMAND_KEYS = listOf(
    "remote.quick.1",
    "remote.quick.2",
    "remote.quick.3",
    "remote.quick.4",
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RemoteCommandRoute(
    onBack: () -> Unit,
    viewModel: DevicesViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val metrics = LocalBuntuMetrics.current
    val currentLanguage = rememberAppLanguage()
    var remoteCommandText by remember { mutableStateOf("") }
    var speechUnavailable by remember { mutableStateOf(false) }

    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val results = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            val spoken = results?.firstOrNull { it.isNotBlank() }?.trim()
            if (!spoken.isNullOrEmpty()) {
                remoteCommandText = spoken
                if (state.connectedPeers.isNotEmpty()) {
                    viewModel.sendRemoteText(spoken)
                }
            }
        }
    }

    val hasConnectedPeers = state.connectedPeers.isNotEmpty()
    val canSend = remoteCommandText.isNotBlank() && hasConnectedPeers

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
        item(key = "remote_header") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = t("common.back"),
                        tint = BuntuPalette.PureWhite,
                    )
                }
                Spacer(modifier = Modifier.width(metrics.spacingM))
                Text(
                    text = t("remote.title"),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                    modifier = Modifier.semantics { heading() },
                )
            }
        }

        state.errorMessage?.let { err ->
            item(key = "remote_error") {
                Surface(
                    color = Color(0xFFB71C1C),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = err,
                        color = Color.White,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }

        state.infoMessage?.let { info ->
            item(key = "remote_info") {
                Surface(
                    color = Color(0xFF1B5E20),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = info,
                        color = Color.White,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }

        item(key = "remote_target_selector") {
            val refreshConnectedCd = t("remote.refresh_cd")
            DeviceSectionCard(title = t("remote.target_title")) {
                Row(
                    horizontalArrangement = Arrangement.End,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    TextButton(
                        onClick = viewModel::refreshPeers,
                        modifier = Modifier.semantics {
                            contentDescription = refreshConnectedCd
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = null,
                            tint = BuntuPalette.TerangaGold,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(t("common.refresh"), color = BuntuPalette.TerangaGold)
                    }
                }
                when {
                    state.connectedPeers.isEmpty() -> {
                        val noPeersCd = t("remote.no_peers_cd")
                        Text(
                            text = t("remote.no_peers"),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BuntuPalette.MutedSilver,
                            modifier = Modifier.semantics {
                                contentDescription = noPeersCd
                            },
                        )
                    }
                    state.connectedPeers.size == 1 -> {
                        val uniquePeer = state.connectedPeers[0]
                        val autoCd = t("remote.target_auto_cd", uniquePeer.name)
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                            modifier = Modifier.selectableGroup(),
                        ) {
                            FilterChip(
                                selected = true,
                                onClick = { viewModel.selectTargetDevice(uniquePeer.id) },
                                label = { Text(uniquePeer.name) },
                                leadingIcon = {
                                    Icon(
                                        imageVector = deviceTypeIcon(uniquePeer.deviceType),
                                        contentDescription = null,
                                    )
                                },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = BuntuPalette.TerangaGold,
                                    selectedLabelColor = BuntuPalette.Midnight,
                                    selectedLeadingIconColor = BuntuPalette.Midnight,
                                ),
                                modifier = Modifier.semantics {
                                    role = Role.RadioButton
                                    selected = true
                                    contentDescription = autoCd
                                },
                            )
                        }
                    }
                    else -> {
                        val allTargetsLabel = t("remote.all_targets")
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                            verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                            modifier = Modifier.selectableGroup(),
                        ) {
                            val allSelected = state.selectedTargetId == null
                            FilterChip(
                                selected = allSelected,
                                onClick = { viewModel.selectTargetDevice(null) },
                                label = { Text(allTargetsLabel) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = BuntuPalette.TerangaGold,
                                    selectedLabelColor = BuntuPalette.Midnight,
                                ),
                                modifier = Modifier.semantics {
                                    role = Role.RadioButton
                                    selected = allSelected
                                    contentDescription = allTargetsLabel
                                },
                            )
                            state.connectedPeers.forEach { peer ->
                                val isSelected = state.selectedTargetId == peer.id
                                val peerCd = t("remote.target_cd", peer.name)
                                FilterChip(
                                    selected = isSelected,
                                    onClick = { viewModel.selectTargetDevice(peer.id) },
                                    label = { Text(peer.name) },
                                    leadingIcon = {
                                        Icon(
                                            imageVector = deviceTypeIcon(peer.deviceType),
                                            contentDescription = null,
                                        )
                                    },
                                    colors = FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = BuntuPalette.TerangaGold,
                                        selectedLabelColor = BuntuPalette.Midnight,
                                        selectedLeadingIconColor = BuntuPalette.Midnight,
                                    ),
                                    modifier = Modifier.semantics {
                                        role = Role.RadioButton
                                        selected = isSelected
                                        contentDescription = peerCd
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }

        item(key = "remote_command_input") {
            val inputCd = t("remote.input_cd")
            val dictateCd = t("remote.dictate_cd")
            val sendCd = t("remote.send_cd")
            DeviceSectionCard(title = t("remote.input_title")) {
                OutlinedTextField(
                    value = remoteCommandText,
                    onValueChange = { remoteCommandText = it },
                    label = { Text(t("devices.remote_field_label")) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(
                        onSend = {
                            if (canSend) {
                                viewModel.sendRemoteText(remoteCommandText)
                                remoteCommandText = ""
                            }
                        },
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = inputCd },
                )

                Row(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    OutlinedButton(
                        onClick = {
                            val speechLang = if (currentLanguage == AppLanguage.EN) "en-US" else "fr-FR"
                            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                                putExtra(
                                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                                )
                                putExtra(RecognizerIntent.EXTRA_LANGUAGE, speechLang)
                            }
                            try {
                                speechUnavailable = false
                                speechLauncher.launch(intent)
                            } catch (_: ActivityNotFoundException) {
                                speechUnavailable = true
                            }
                        },
                        modifier = Modifier.semantics {
                            contentDescription = dictateCd
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Default.Mic,
                            contentDescription = null,
                            tint = BuntuPalette.PureWhite,
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(t("devices.dictate"), color = BuntuPalette.PureWhite, maxLines = 1)
                    }

                    BuntuPrimaryActionButton(
                        label = t("devices.send_to_tv"),
                        enabled = canSend,
                        onClick = {
                            viewModel.sendRemoteText(remoteCommandText)
                            remoteCommandText = ""
                        },
                        modifier = Modifier
                            .weight(1f)
                            .semantics { contentDescription = sendCd },
                    )
                }

                if (speechUnavailable) {
                    Text(
                        text = t("devices.speech_unavailable"),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFFFFB74D),
                    )
                }

                Text(
                    text = t("remote.quick_commands"),
                    style = MaterialTheme.typography.labelLarge,
                    color = BuntuPalette.MutedSilver,
                    modifier = Modifier.semantics { heading() },
                )

                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(metrics.spacingS),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingXS),
                ) {
                    QUICK_REMOTE_COMMAND_KEYS.forEach { cmdKey ->
                        val command = t(cmdKey)
                        val quickCd = t("remote.quick_cd", command)
                        SuggestionChip(
                            onClick = { remoteCommandText = command },
                            label = { Text(command) },
                            modifier = Modifier.semantics {
                                contentDescription = quickCd
                            },
                        )
                    }
                }
            }
        }
    }
}

/** Black on white with a quiet zone, readable by any phone camera. */
@Composable
private fun HouseholdQrCode(matrix: QrMatrix, modifier: Modifier = Modifier) {
    val qrCd = t("devices.qr_cd")
    Canvas(
        modifier = modifier
            .background(Color.White, RoundedCornerShape(12.dp))
            .padding(8.dp)
            .semantics { contentDescription = qrCd },
    ) {
        val cell = size.minDimension / matrix.size.toFloat()
        for (y in 0 until matrix.size) {
            for (x in 0 until matrix.size) {
                if (matrix.pixels[y * matrix.size + x]) {
                    drawRect(
                        color = Color.Black,
                        topLeft = Offset(x * cell, y * cell),
                        size = Size(cell + 0.5f, cell + 0.5f),
                    )
                }
            }
        }
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
                        text = if (isOnline) t("devices.peer_online") else t("devices.peer_recent"),
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
                        text = if (isOnline) t("devices.peer_available") else t("devices.peer_offline"),
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

