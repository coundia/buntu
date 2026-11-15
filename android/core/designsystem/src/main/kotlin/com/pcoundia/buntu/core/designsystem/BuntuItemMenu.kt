package com.pcoundia.buntu.core.designsystem

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.pcoundia.buntu.core.designsystem.i18n.t
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.launch

/**
 * What the context menu of a card (long press, or Menu key on Android TV) acts on.
 *
 * The designsystem does not know the catalog: the screen passes what it knows how to do.
 * - [itemId] is the playable item sent by « Lire sur un autre appareil »; `null` hides that action
 *   (e.g. a series card, which is not playable by itself).
 * - [isFavorite] / [toggleFavorite] read and flip the favorite; `null` hides the action.
 */
@Immutable
class BuntuItemMenu(
    val title: String,
    val itemId: Long? = null,
    val isFavorite: (suspend () -> Boolean?)? = null,
    val toggleFavorite: (suspend () -> Boolean?)? = null,
    /** Opens the device list directly (a dedicated « Lire sur… » button), skipping the action list. */
    val startOnDevices: Boolean = false,
)

/**
 * Context menu of a catalog card: add / remove favorite, then « Lire sur un autre appareil » which
 * opens the device list. Replaces the former menu that only offered the device list.
 *
 * Remote-friendly: the first action takes the focus. The favorite action keeps the menu open and
 * flips its label, so the user sees the result.
 */
@Composable
fun BuntuItemMenuHost(
    menu: BuntuItemMenu?,
    devices: ImmutableList<BuntuDeviceChoice>,
    status: String?,
    /** Called when the device list opens (clears the previous handoff status). */
    onOpenDevices: () -> Unit,
    onPlayOnDevice: (deviceId: String, itemId: Long, onSent: () -> Unit) -> Unit,
    onDismiss: () -> Unit,
) {
    if (menu == null) return
    var showDevices by remember(menu) { mutableStateOf(menu.startOnDevices && menu.itemId != null) }
    LaunchedEffect(menu) { if (menu.startOnDevices && menu.itemId != null) onOpenDevices() }

    if (showDevices && menu.itemId != null) {
        BuntuDevicePickerDialog(
            itemTitle = menu.title,
            devices = devices,
            status = status,
            onPick = { device -> onPlayOnDevice(device.id, menu.itemId, onDismiss) },
            onDismiss = onDismiss,
        )
        return
    }

    var favorite by remember(menu) { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(menu) { favorite = menu.isFavorite?.invoke() }
    val scope = rememberCoroutineScope()
    val firstFocus = remember { FocusRequester() }

    // Actions in display order; the first one takes the focus.
    val favoriteToggle = menu.toggleFavorite
    val showFavorite = favoriteToggle != null && favorite != null
    val showRemote = menu.itemId != null

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(menu.title, maxLines = 2) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (showFavorite) {
                    val isFavorite = favorite == true
                    MenuActionRow(
                        icon = if (isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                        iconTint = if (isFavorite) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                        label = t(if (isFavorite) "item_menu.favorite_remove" else "item_menu.favorite_add"),
                        modifier = Modifier.focusRequester(firstFocus),
                        onClick = {
                            scope.launch { favoriteToggle?.invoke()?.let { favorite = it } }
                        },
                    )
                }
                if (showRemote) {
                    MenuActionRow(
                        icon = Icons.Filled.Cast,
                        iconTint = BuntuPalette.PureWhite,
                        label = t("item_menu.play_elsewhere"),
                        modifier = if (showFavorite) Modifier else Modifier.focusRequester(firstFocus),
                        onClick = {
                            onOpenDevices()
                            showDevices = true
                        },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(t("common.close")) } },
    )
    LaunchedEffect(showFavorite, showRemote) {
        if (showFavorite || showRemote) runCatching { firstFocus.requestFocus() }
    }
}

@Composable
private fun MenuActionRow(
    icon: ImageVector,
    iconTint: Color,
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        color = BuntuPalette.SlateElevated,
        shape = RoundedCornerShape(8.dp),
        modifier = modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .border(
                width = if (focused) 2.dp else 0.dp,
                color = if (focused) BuntuPalette.TerangaGold else Color.Transparent,
                shape = RoundedCornerShape(8.dp),
            )
            .clickable(role = Role.Button, onClick = onClick),
    ) {
        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(imageVector = icon, contentDescription = null, tint = iconTint)
            Spacer(modifier = Modifier.width(10.dp))
            Text(label, color = BuntuPalette.PureWhite, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
