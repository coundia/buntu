package com.pcoundia.buntu.feature.profiles

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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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

@Composable
fun ProfilesRoute(
    viewModel: ProfilesViewModel = hiltViewModel(),
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
        item(key = "title", contentType = "header") {
            Text(
                text = "Profils & Contrôle parental",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.PureWhite,
            )
        }

        state.statusMessage?.let { msg ->
            item(key = "status", contentType = "status") {
                Surface(color = BuntuPalette.SlateElevated, shape = RoundedCornerShape(10.dp)) {
                    Text(msg, color = BuntuPalette.LeerCyan, modifier = Modifier.padding(metrics.spacingM))
                }
            }
        }

        items(
            items = state.profiles,
            key = { it.id },
            contentType = { "profile_item" },
        ) { profile ->
            Surface(
                color = if (profile.isActive) BuntuPalette.SlateElevated else BuntuPalette.Slate,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.padding(metrics.spacingM),
                ) {
                    Text(
                        text = "${profile.avatar}  ${profile.name}" +
                            (if (profile.isKids) " · Enfants" else "") +
                            (if (profile.isActive) " · Actif" else ""),
                        style = MaterialTheme.typography.titleMedium,
                        color = if (profile.isActive) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                    )
                    if (!profile.isActive) {
                        BuntuPrimaryActionButton(
                            label = "Choisir",
                            onClick = { viewModel.selectProfile(profile) },
                        )
                    }
                }
            }
        }

        item(key = "create_profile", contentType = "form") {
            Surface(color = BuntuPalette.Slate, shape = RoundedCornerShape(12.dp)) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(metrics.spacingM),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    Text("Nouveau profil", fontWeight = FontWeight.Bold, color = BuntuPalette.PureWhite)
                    OutlinedTextField(
                        value = state.newProfileName,
                        onValueChange = { viewModel.updateNewProfile(it, state.newProfileKids) },
                        label = { Text("Nom du profil") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    FilterChip(
                        selected = state.newProfileKids,
                        onClick = { viewModel.updateNewProfile(state.newProfileName, !state.newProfileKids) },
                        label = { Text("Profil Enfants (sans catégories adultes ni IA distante)") },
                    )
                    BuntuPrimaryActionButton(label = "Créer le profil", onClick = viewModel::createProfile)
                }
            }
        }

        item(key = "parental_pin", contentType = "form") {
            Surface(color = BuntuPalette.Slate, shape = RoundedCornerShape(12.dp)) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(metrics.spacingM),
                    verticalArrangement = Arrangement.spacedBy(metrics.spacingS),
                ) {
                    Text(
                        text = "Code PIN parental (Android Keystore)",
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    OutlinedTextField(
                        value = state.pinInput,
                        onValueChange = viewModel::updatePinInput,
                        label = { Text(if (state.hasParentalPin) "Code PIN" else "Définir un code PIN (4-6 chiffres)") },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    BuntuPrimaryActionButton(
                        label = when {
                            !state.hasParentalPin -> "Enregistrer le code PIN"
                            state.adultCategoriesUnlocked -> "Masquer les catégories adultes"
                            else -> "Déverrouiller les catégories adultes"
                        },
                        onClick = viewModel::saveOrVerifyPinAndToggleAdult,
                    )
                }
            }
        }
    }
}

