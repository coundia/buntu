package com.pcoundia.buntu.feature.onboarding

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.SourceKind
import com.pcoundia.buntu.core.platform.tv.QrMatrix

/**
 * PRD-37 § 5.4:
 * 3-step first launch (Source -> Profile -> Ready for Live TV) shared across Phone & Android TV.
 */
@Composable
fun OnboardingRoute(
    onFinished: () -> Unit,
    viewModel: OnboardingViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    OnboardingScreen(
        state = state,
        onSelectKind = viewModel::selectSourceKind,
        onUpdateFields = viewModel::updateFields,
        onSubmitSource = viewModel::submitSourceAndSync,
        onSelectProfile = viewModel::selectProfileAndAdvance,
        onFinish = { viewModel.finishOnboarding(onCompleted = onFinished) },
    )
}

@Composable
fun OnboardingScreen(
    state: OnboardingUiState,
    onSelectKind: (SourceKind) -> Unit,
    onUpdateFields: (String, String, String, String) -> Unit,
    onSubmitSource: () -> Unit,
    onSelectProfile: (Long) -> Unit,
    onFinish: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BuntuPalette.Midnight)
            .padding(
                horizontal = metrics.horizontalScreenPadding,
                vertical = metrics.verticalScreenPadding,
            )
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(metrics.spacingL),
    ) {
        Text(
            text = "Bienvenue sur Buntu · Étape ${state.step} / 3",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = BuntuPalette.TerangaGold,
        )

        state.errorMessage?.let { err ->
            BuntuErrorBanner(message = err)
        }

        when (state.step) {
            1 -> StepOneAddSource(
                state = state,
                onSelectKind = onSelectKind,
                onUpdateFields = onUpdateFields,
                onSubmitSource = onSubmitSource,
                onSkipForNow = onFinish,
            )
            2 -> StepTwoPickProfile(
                state = state,
                onSelectProfile = onSelectProfile,
            )
            else -> StepThreeReady(onFinish = onFinish)
        }
    }
}

@Composable
private fun StepOneAddSource(
    state: OnboardingUiState,
    onSelectKind: (SourceKind) -> Unit,
    onUpdateFields: (String, String, String, String) -> Unit,
    onSubmitSource: () -> Unit,
    onSkipForNow: () -> Unit,
) {
    val metrics = LocalBuntuMetrics.current

    if (state.isTv && state.qrMatrix != null && state.pairingUrl != null) {
        Surface(
            color = BuntuPalette.Slate,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(metrics.spacingL),
            ) {
                QrCodeBox(matrix = state.qrMatrix, modifier = Modifier.size(168.dp))
                Spacer(modifier = Modifier.width(metrics.spacingL))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Ajout rapide sans télécommande",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                    )
                    Spacer(modifier = Modifier.height(metrics.spacingXS))
                    Text(
                        text = "Scannez ce QR code avec votre téléphone ou ouvrez ${state.pairingUrl} sur le même Wi-Fi.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = BuntuPalette.MutedSilver,
                    )
                }
            }
        }
    }

    Row(horizontalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
        FilterChip(
            selected = state.sourceKind == SourceKind.XTREAM,
            onClick = { onSelectKind(SourceKind.XTREAM) },
            label = { Text("Xtream Codes") },
        )
        FilterChip(
            selected = state.sourceKind == SourceKind.M3U,
            onClick = { onSelectKind(SourceKind.M3U) },
            label = { Text("Playlist M3U") },
        )
    }

    OutlinedTextField(
        value = state.name,
        onValueChange = { onUpdateFields(it, state.serverOrUrl, state.username, state.password) },
        label = { Text("Nom de la source") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )

    OutlinedTextField(
        value = state.serverOrUrl,
        onValueChange = { onUpdateFields(state.name, it, state.username, state.password) },
        label = {
            Text(
                if (state.sourceKind == SourceKind.XTREAM) "Serveur Xtream (http://...)"
                else "URL de la playlist M3U",
            )
        },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )

    if (state.sourceKind == SourceKind.XTREAM) {
        OutlinedTextField(
            value = state.username,
            onValueChange = { onUpdateFields(state.name, state.serverOrUrl, it, state.password) },
            label = { Text("Identifiant") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = state.password,
            onValueChange = { onUpdateFields(state.name, state.serverOrUrl, state.username, it) },
            label = { Text("Mot de passe") },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(metrics.spacingM),
    ) {
        if (state.isSyncing) {
            CircularProgressIndicator(color = BuntuPalette.TerangaGold, modifier = Modifier.size(32.dp))
            Text("Synchronisation du catalogue…", color = BuntuPalette.PureWhite)
        } else {
            BuntuPrimaryActionButton(
                label = "Connecter et synchroniser",
                onClick = onSubmitSource,
            )
            TextButton(onClick = onSkipForNow) {
                Text("Plus tard", color = BuntuPalette.MutedSilver)
            }
        }
    }
}

@Composable
private fun StepTwoPickProfile(
    state: OnboardingUiState,
    onSelectProfile: (Long) -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Text(
        text = "Qui regarde aujourd'hui ?",
        style = MaterialTheme.typography.titleLarge,
        color = BuntuPalette.PureWhite,
        fontWeight = FontWeight.Bold,
    )
    LazyRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingM)) {
        items(
            items = state.profiles,
            key = { it.id },
            contentType = { "onboarding_profile_card" },
        ) { profile ->
            BuntuPrimaryActionButton(
                label = "${profile.avatar}  ${profile.name}" + if (profile.isKids) " (Enfants)" else "",
                onClick = { onSelectProfile(profile.id) },
            )
        }
    }
    if (state.profiles.isEmpty()) {
        BuntuPrimaryActionButton(
            label = "Continuer avec le profil Principal",
            onClick = { onSelectProfile(1L) },
        )
    }
}

@Composable
private fun StepThreeReady(onFinish: () -> Unit) {
    Text(
        text = "Votre catalogue est prêt !",
        style = MaterialTheme.typography.headlineMedium,
        fontWeight = FontWeight.Bold,
        color = BuntuPalette.PureWhite,
    )
    Text(
        text = "Ouvrez directement la TV en direct et zappez d'un geste ou avec les flèches de votre télécommande.",
        style = MaterialTheme.typography.bodyLarge,
        color = BuntuPalette.MutedSilver,
    )
    BuntuPrimaryActionButton(
        label = "Regarder la TV en direct",
        onClick = onFinish,
    )
}

@Composable
fun QrCodeBox(matrix: QrMatrix, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(Color.White, RoundedCornerShape(12.dp))
            .padding(8.dp),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val cellW = size.width / matrix.size.toFloat()
            val cellH = size.height / matrix.size.toFloat()
            for (y in 0 until matrix.size) {
                for (x in 0 until matrix.size) {
                    if (matrix.pixels[y * matrix.size + x]) {
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
}

