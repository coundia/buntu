package com.pcoundia.buntu.core.designsystem

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.collections.immutable.ImmutableList

/**
 * Click of a card, with its context menu (PRD-44 § 2.2): long press on a phone, long press on OK or the
 * Menu key of the remote on Android TV. Without [onLongClick] it is a plain click.
 */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.buntuCardClickable(onClick: () -> Unit, onLongClick: (() -> Unit)?): Modifier {
    if (onLongClick == null) return clickable(role = Role.Button, onClick = onClick)
    return onPreviewKeyEvent { event ->
        if (event.key != Key.Menu) return@onPreviewKeyEvent false
        if (event.type == KeyEventType.KeyUp) onLongClick()
        true
    }.combinedClickable(
        role = Role.Button,
        onClickLabel = null,
        onLongClickLabel = "Plus d'options",
        onClick = onClick,
        onLongClick = onLongClick,
    )
}

/** A household device offered by « Lire sur un autre appareil ». */
@Immutable
data class BuntuDeviceChoice(
    val id: String,
    val name: String,
    /** "tv" | "mobile" | "desktop" … as announced by the device. */
    val deviceType: String,
)

/**
 * « Lire sur un autre appareil » (PRD-42, PRD-44 § 2.2): list of the available household devices.
 * Remote-friendly: the first device takes the focus.
 */
@Composable
fun BuntuDevicePickerDialog(
    itemTitle: String?,
    devices: ImmutableList<BuntuDeviceChoice>,
    status: String?,
    onPick: (BuntuDeviceChoice) -> Unit,
    onDismiss: () -> Unit,
) {
    val firstFocus = remember { FocusRequester() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lire sur un autre appareil") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!itemTitle.isNullOrBlank()) {
                    Text(itemTitle, style = MaterialTheme.typography.bodyMedium, color = BuntuPalette.PureWhite)
                }
                if (!status.isNullOrBlank()) {
                    Text(status, style = MaterialTheme.typography.bodyMedium, color = BuntuPalette.LeerCyan)
                }
                if (devices.isEmpty()) {
                    Text("Aucun autre appareil du foyer détecté.", style = MaterialTheme.typography.bodySmall)
                }
                devices.forEachIndexed { index, device ->
                    var focused by remember { mutableStateOf(false) }
                    Surface(
                        color = BuntuPalette.SlateElevated,
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (index == 0) Modifier.focusRequester(firstFocus) else Modifier)
                            .onFocusChanged { focused = it.isFocused }
                            .border(
                                width = if (focused) 2.dp else 0.dp,
                                color = if (focused) BuntuPalette.TerangaGold else Color.Transparent,
                                shape = RoundedCornerShape(8.dp),
                            )
                            .clickable(role = Role.Button) { onPick(device) },
                    ) {
                        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = when (device.deviceType) {
                                    "tv" -> Icons.Default.Tv
                                    "desktop", "mac" -> Icons.Default.Computer
                                    else -> Icons.Default.PhoneAndroid
                                },
                                contentDescription = null,
                                tint = BuntuPalette.PureWhite,
                            )
                            Spacer(modifier = Modifier.width(10.dp))
                            Text(device.name, color = BuntuPalette.PureWhite, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Fermer") } },
    )
    LaunchedEffect(devices.isNotEmpty()) {
        if (devices.isNotEmpty()) runCatching { firstFocus.requestFocus() }
    }
}
