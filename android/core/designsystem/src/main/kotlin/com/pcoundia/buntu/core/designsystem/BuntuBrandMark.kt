package com.pcoundia.buntu.core.designsystem

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The Buntu logo and name, as at the top of the iPhone and Mac sidebar (`AppShellView.sidebarBrand`).
 * The drawable `buntu_logo` is generated from the geometry of Apple `AppLogoView.swift`.
 */
@Composable
fun BuntuBrandMark(
    modifier: Modifier = Modifier,
    logoSize: Dp = 30.dp,
    textStyle: TextStyle = MaterialTheme.typography.titleMedium,
    showName: Boolean = true,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Image(
            painter = painterResource(R.drawable.buntu_logo),
            // The name next to it is read by TalkBack; alone, the logo carries the name.
            contentDescription = if (showName) null else "Buntu",
            modifier = Modifier.size(logoSize),
        )
        if (showName) {
            Text(
                text = "Buntu",
                style = textStyle,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
        }
    }
}
