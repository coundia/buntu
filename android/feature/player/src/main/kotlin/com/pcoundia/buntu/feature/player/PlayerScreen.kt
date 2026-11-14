package com.pcoundia.buntu.feature.player

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.pcoundia.buntu.core.designsystem.BuntuErrorBanner
import com.pcoundia.buntu.core.designsystem.BuntuPalette
import com.pcoundia.buntu.core.designsystem.BuntuPosterCard
import com.pcoundia.buntu.core.designsystem.BuntuPrimaryActionButton
import com.pcoundia.buntu.core.designsystem.LocalBuntuMetrics
import com.pcoundia.buntu.core.domain.model.ChannelItem
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.MovieItem
import com.pcoundia.buntu.core.domain.model.StreamKind
import com.pcoundia.buntu.core.domain.model.UpNextItem
import com.pcoundia.buntu.core.domain.usecase.NextUpTiming
import com.pcoundia.buntu.core.platform.pip.PipHelper
import com.pcoundia.buntu.core.player.BuntuVideoSurface
import com.pcoundia.buntu.core.player.PlayerEngineState
import com.pcoundia.buntu.core.player.VideoAspectMode
import kotlinx.collections.immutable.ImmutableList
import kotlinx.coroutines.delay

/** Same step as YouTube and the Apple player (`gobackward.10` / `goforward.10`). */
private const val SEEK_STEP_MS = 10_000L

/** Controls hide after this delay while the video plays (a bit longer on TV, read from the sofa). */
private const val AUTO_HIDE_MS = 4_000L
private const val AUTO_HIDE_TV_MS = 6_000L

/** Which sheet is open over the video; one at a time. */
private enum class PlayerSheet { NONE, TRACKS, SETTINGS, VERSIONS, MIRRORS, CHANNELS }

/**
 * PRD-37 § 5.2: a player laid out like YouTube.
 * - Phone in portrait: the video in 16:9 at the top, then the title, the actions and the "À suivre" list.
 * - Landscape, tablet, Android TV: the video full screen, controls over it that hide by themselves.
 * Double tap on the left or right half seeks 10 s; on TV, left/right seek while nothing has the focus.
 */
@Composable
fun PlayerRoute(
    onBack: () -> Unit,
    onNavigateToDownloads: () -> Unit,
    viewModel: PlayerViewModel = hiltViewModel(),
) {
    val screenState by viewModel.screenState.collectAsStateWithLifecycle()
    val engineState by viewModel.engineState.collectAsStateWithLifecycle()
    val peers by viewModel.availablePeers.collectAsStateWithLifecycle()
    val handoffStatus by viewModel.handoffStatus.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val activity = context as? Activity

    var showRemoteDialog by remember { mutableStateOf(false) }
    var dismissCandidate by remember { mutableStateOf<UpNextItem?>(null) }
    var settingsOpen by remember { mutableStateOf(false) }
    var mirrorsOpen by remember { mutableStateOf(false) }
    // Focus inside the controls, a sheet or the end card: the remote then moves the focus instead of seeking.
    var overlayHasFocus by remember { mutableStateOf(false) }
    // Bumped on every touch or key, so the auto-hide timer restarts.
    var interactionTick by remember { mutableIntStateOf(0) }

    val stream = engineState.activeStream
    val isLive = stream?.kind == StreamKind.LIVE
    val isCatchupReplay = stream?.kind == StreamKind.CATCHUP
    val onlinePeers = peers.filter { it.state != "offline" }
    // Not for local files and downloads (PRD-42 § 1.3): the other device cannot open them.
    val canPlayElsewhere = onlinePeers.isNotEmpty() && stream?.kind != StreamKind.LOCAL_FILE
    val canPip = activity != null && PipHelper.isSupported(activity, screenState.isTv)

    LaunchedEffect(screenState.statusToast) {
        if (screenState.statusToast != null) {
            delay(3_000L)
            viewModel.dismissStatusToast()
        }
    }

    val openSheet = when {
        screenState.showChannelDrawer -> PlayerSheet.CHANNELS
        screenState.showTrackSheet -> PlayerSheet.TRACKS
        screenState.showVersionsSheet -> PlayerSheet.VERSIONS
        mirrorsOpen -> PlayerSheet.MIRRORS
        settingsOpen -> PlayerSheet.SETTINGS
        else -> PlayerSheet.NONE
    }
    val closeSheet = {
        viewModel.toggleChannelDrawer(false)
        viewModel.toggleTrackSheet(false)
        viewModel.toggleVersionsSheet(false)
        mirrorsOpen = false
        settingsOpen = false
    }

    DisposableEffect(activity, engineState.isPlaying, screenState.isTv) {
        if (activity != null) {
            PipHelper.updateAutoEnter(activity, screenState.isTv, engineState.isPlaying)
        }
        onDispose {
            if (activity != null) {
                PipHelper.updateAutoEnter(activity, screenState.isTv, false)
            }
        }
    }

    LaunchedEffect(
        screenState.controlsVisible,
        screenState.isScreenLocked,
        engineState.isPlaying,
        interactionTick,
        overlayHasFocus,
        openSheet,
        screenState.nextUpCard,
    ) {
        val keepVisible = !screenState.isScreenLocked && (
            !engineState.isPlaying || overlayHasFocus || openSheet != PlayerSheet.NONE ||
                screenState.nextUpCard != null
            )
        if (screenState.controlsVisible && !keepVisible) {
            delay(if (screenState.isTv) AUTO_HIDE_TV_MS else AUTO_HIDE_MS)
            viewModel.hideControls()
        }
    }

    val exit = {
        viewModel.stopPlaybackAndCleanup()
        onBack()
    }

    BackHandler {
        when {
            screenState.isScreenLocked -> {
                interactionTick++
                viewModel.showControls()
            }
            screenState.nextUpCard != null -> viewModel.closeNextUpCard()
            openSheet != PlayerSheet.NONE -> closeSheet()
            else -> exit()
        }
    }

    val actions = PlayerActions(
        onBack = exit,
        onTogglePlay = { viewModel.videoEngine.togglePlayPause() },
        onSeek = { delta -> viewModel.videoEngine.seekBy(delta) },
        onSeekTo = { pos -> viewModel.videoEngine.seekTo(pos) },
        onZap = viewModel::zapAdjacentLive,
        onToggleFavorite = viewModel::toggleFavorite,
        onLockScreen = {
            closeSheet()
            viewModel.lockScreen()
        },
        onUnlockScreen = {
            interactionTick++
            viewModel.unlockScreen()
        },
        onOpenTracks = {
            closeSheet()
            viewModel.toggleTrackSheet(true)
        },
        onOpenSettings = {
            closeSheet()
            settingsOpen = true
        },
        onOpenVersions = {
            closeSheet()
            viewModel.toggleVersionsSheet(true)
        },
        onPlayElsewhere = { showRemoteDialog = true },
        onPip = { if (activity != null) PipHelper.enterPipNow(activity, screenState.isTv) },
        onDownload = { viewModel.downloadInsteadAndExit(onNavigateToDownloads) },
        onPlayUpNext = viewModel::playUpNextItem,
        onUpNextMenu = { dismissCandidate = it },
        onRecall = viewModel::recallPreviousChannel,
        onStartOver = viewModel::startOverCurrentProgram,
        onReturnToLive = viewModel::returnToLive,
        onSeekToLiveEdge = { viewModel.videoEngine.seekToLiveEdge() },
        onOpenMirrors = {
            closeSheet()
            mirrorsOpen = true
        },
        onOpenChannelsDrawer = {
            closeSheet()
            viewModel.toggleChannelDrawer(true)
        },
        onCycleAspect = viewModel::cycleAspectMode,
    )
    val capabilities = PlayerCapabilities(
        isLive = isLive,
        isCatchupReplay = isCatchupReplay,
        canRecall = isLive && screenState.canRecallLive,
        hasMirrors = isLive && screenState.liveMirrors.size > 1,
        sleepTimerRemainingSeconds = screenState.sleepTimerRemainingSeconds,
        canFavorite = screenState.canToggleFavorite,
        isFavorite = screenState.isFavorite,
        hasTracks = engineState.audioTracks.isNotEmpty() || engineState.subtitleTracks.isNotEmpty(),
        hasVersions = screenState.otherVersions.isNotEmpty(),
        canPlayElsewhere = canPlayElsewhere,
        canPip = canPip,
        canDownload = !screenState.isTv &&
            (stream?.kind == StreamKind.VOD_MOVIE || stream?.kind == StreamKind.VOD_EPISODE),
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                if (screenState.isScreenLocked) {
                    interactionTick++
                    viewModel.showControls()
                    return@onPreviewKeyEvent false
                }
                val wasHidden = !screenState.controlsVisible
                interactionTick++
                viewModel.showControls()
                val seekAllowed = !isLive && (wasHidden || !overlayHasFocus)
                val zapAllowed = isLive && (wasHidden || !overlayHasFocus)
                when (event.key) {
                    Key.MediaPlayPause, Key.Spacebar -> {
                        viewModel.videoEngine.togglePlayPause()
                        true
                    }
                    Key.MediaPlay -> {
                        viewModel.videoEngine.resume()
                        true
                    }
                    Key.MediaPause -> {
                        viewModel.videoEngine.pause()
                        true
                    }
                    Key.MediaRewind -> if (!isLive) {
                        viewModel.videoEngine.seekBy(-SEEK_STEP_MS)
                        true
                    } else false
                    Key.MediaFastForward -> if (!isLive) {
                        viewModel.videoEngine.seekBy(SEEK_STEP_MS)
                        true
                    } else false
                    Key.DirectionLeft -> if (seekAllowed) {
                        viewModel.videoEngine.seekBy(-SEEK_STEP_MS)
                        true
                    } else false
                    Key.DirectionRight -> if (seekAllowed) {
                        viewModel.videoEngine.seekBy(SEEK_STEP_MS)
                        true
                    } else false
                    Key.ChannelUp -> if (isLive) {
                        viewModel.zapAdjacentLive(-1)
                        true
                    } else false
                    Key.ChannelDown -> if (isLive) {
                        viewModel.zapAdjacentLive(+1)
                        true
                    } else false
                    Key.DirectionUp -> if (zapAllowed) {
                        viewModel.zapAdjacentLive(-1)
                        true
                    } else false
                    Key.DirectionDown -> if (zapAllowed) {
                        viewModel.zapAdjacentLive(+1)
                        true
                    } else false
                    Key.Zero, Key.NumPad0 -> if (isLive) { viewModel.appendChannelDigit(0); true } else false
                    Key.One, Key.NumPad1 -> if (isLive) { viewModel.appendChannelDigit(1); true } else false
                    Key.Two, Key.NumPad2 -> if (isLive) { viewModel.appendChannelDigit(2); true } else false
                    Key.Three, Key.NumPad3 -> if (isLive) { viewModel.appendChannelDigit(3); true } else false
                    Key.Four, Key.NumPad4 -> if (isLive) { viewModel.appendChannelDigit(4); true } else false
                    Key.Five, Key.NumPad5 -> if (isLive) { viewModel.appendChannelDigit(5); true } else false
                    Key.Six, Key.NumPad6 -> if (isLive) { viewModel.appendChannelDigit(6); true } else false
                    Key.Seven, Key.NumPad7 -> if (isLive) { viewModel.appendChannelDigit(7); true } else false
                    Key.Eight, Key.NumPad8 -> if (isLive) { viewModel.appendChannelDigit(8); true } else false
                    Key.Nine, Key.NumPad9 -> if (isLive) { viewModel.appendChannelDigit(9); true } else false
                    Key.Enter, Key.NumPadEnter -> if (isLive && screenState.channelDigitBuffer.isNotEmpty()) {
                        viewModel.commitChannelNumber()
                        true
                    } else false
                    Key.Guide -> if (isLive) {
                        viewModel.toggleChannelDrawer()
                        true
                    } else false
                    else -> false
                }
            },
    ) {
        // A PiP window is tiny: video only, no controls.
        val isPip = maxWidth < 320.dp
        val portrait = !screenState.isTv && !isPip && maxHeight > maxWidth

        ImmersiveSystemBars(enabled = !portrait && !screenState.isTv)

        if (portrait) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(BuntuPalette.Midnight),
            ) {
                VideoStage(
                    viewModel = viewModel,
                    engineState = engineState,
                    isFullscreen = false,
                    isPip = false,
                    capabilities = capabilities,
                    actions = actions,
                    upNextShelf = null,
                    onInteraction = { interactionTick++ },
                    onOverlayFocus = { overlayHasFocus = it },
                    modifier = Modifier
                        .background(Color.Black)
                        .statusBarsPadding()
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f),
                )
                Box(modifier = Modifier.weight(1f)) {
                    PortraitDetails(
                        engineState = engineState,
                        capabilities = capabilities,
                        actions = actions,
                        upNext = screenState.upNextShelf,
                        modifier = Modifier.fillMaxSize(),
                    )
                    if (screenState.isScreenLocked) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(Color.Black.copy(alpha = 0.45f))
                                .pointerInput(Unit) {
                                    detectTapGestures(
                                        onTap = {
                                            interactionTick++
                                            viewModel.showControls()
                                        },
                                    )
                                },
                        )
                    }
                }
            }
        } else {
            VideoStage(
                viewModel = viewModel,
                engineState = engineState,
                isFullscreen = true,
                isPip = isPip,
                capabilities = capabilities,
                actions = actions,
                upNextShelf = screenState.upNextShelf,
                onInteraction = { interactionTick++ },
                onOverlayFocus = { overlayHasFocus = it },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (!isPip) {
            // Insufficient bandwidth (PRD-37 § 4.3 & § 5.4).
            engineState.bandwidthWarning?.let { bw ->
                BandwidthBanner(
                    measuredMbps = bw.measuredMbps,
                    requiredMbps = bw.requiredMbps,
                    hasVersions = capabilities.hasVersions,
                    canDownload = capabilities.canDownload,
                    onVersions = actions.onOpenVersions,
                    onDownload = actions.onDownload,
                    onContinue = { viewModel.videoEngine.dismissBandwidthWarning() },
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .statusBarsPadding()
                        .padding(12.dp)
                        .widthIn(max = 560.dp)
                        .fillMaxWidth(),
                )
            }

            if (isLive && engineState.isBroken) {
                Text(
                    text = "⚠ HORS SERVICE",
                    color = BuntuPalette.DangerRed,
                    modifier = Modifier.align(Alignment.TopCenter).padding(top = 72.dp),
                )
            }

            if (screenState.channelDigitBuffer.isNotEmpty()) {
                Surface(
                    color = Color.Black.copy(alpha = 0.84f),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(20.dp),
                ) {
                    Text(
                        text = "CH ${screenState.channelDigitBuffer}",
                        color = BuntuPalette.PureWhite,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }

            val topBanner = screenState.pendingZapTitle?.let { "Zap → $it…" }
                ?: screenState.failoverBanner
                ?: screenState.statusToast
            topBanner?.let { text ->
                Surface(
                    color = Color.Black.copy(alpha = 0.85f),
                    shape = RoundedCornerShape(50),
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .statusBarsPadding()
                        .padding(top = 56.dp),
                ) {
                    Text(
                        text = text,
                        color = BuntuPalette.PureWhite,
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                    )
                }
            }

            engineState.diagnosis?.let { diagnosis ->
                Box(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(24.dp)
                        .widthIn(max = 520.dp),
                ) {
                    BuntuErrorBanner(message = diagnosis.userMessage, actionLabel = "Retour", onAction = exit)
                }
            }

            screenState.nextUpCard?.let { card ->
                NextUpCardOverlay(
                    card = card,
                    isEnded = engineState.isEnded,
                    isTv = screenState.isTv,
                    onPlayNow = viewModel::playNextUpNow,
                    onCredits = viewModel::dismissNextUpForCredits,
                    onCancelCountdown = viewModel::cancelNextUpCountdown,
                    onClose = viewModel::closeNextUpCard,
                    onStillWatching = viewModel::confirmStillWatching,
                    modifier = Modifier
                        .align(if (portrait) Alignment.BottomCenter else Alignment.BottomEnd)
                        .padding(16.dp)
                        .widthIn(max = 380.dp)
                        .fillMaxWidth()
                        .onFocusChanged { overlayHasFocus = it.hasFocus },
                )
            }

            if (openSheet != PlayerSheet.NONE) {
                PlayerSheetHost(
                    sheet = openSheet,
                    engineState = engineState,
                    screenState = screenState,
                    otherVersions = screenState.otherVersions,
                    capabilities = capabilities,
                    actions = actions,
                    onSpeed = { speed -> viewModel.setPlaybackSpeed(speed) },
                    onSelectAudio = { g, t -> viewModel.videoEngine.selectAudioTrack(g, t) },
                    onSelectSubtitle = { g, t -> viewModel.videoEngine.selectSubtitleTrack(g, t) },
                    onSubtitleOffset = { viewModel.videoEngine.setSubtitleOffsetMs(it) },
                    onSwitchVersion = {
                        viewModel.switchVersion(it)
                        closeSheet()
                    },
                    onSelectAspect = viewModel::setAspectMode,
                    onSleepTimer = viewModel::setSleepTimer,
                    onSwitchMirror = {
                        viewModel.switchLiveMirror(it)
                        closeSheet()
                    },
                    onSelectChannel = viewModel::selectChannelFromDrawer,
                    onClose = closeSheet,
                    modifier = Modifier
                        .align(
                            when {
                                openSheet == PlayerSheet.CHANNELS && !portrait -> Alignment.CenterStart
                                portrait -> Alignment.BottomCenter
                                else -> Alignment.CenterEnd
                            }
                        )
                        .padding(12.dp)
                        .widthIn(max = 420.dp)
                        .fillMaxWidth()
                        .heightIn(max = maxHeight * 0.85f)
                        .onFocusChanged { overlayHasFocus = it.hasFocus },
                )
            }
        }
    }

    dismissCandidate?.let { item ->
        AlertDialog(
            onDismissRequest = { dismissCandidate = null },
            title = { Text("Pas intéressé ?") },
            text = { Text("« ${item.title} » ne sera plus proposé dans « À suivre » pour ce profil.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.dismissUpNextItem(item)
                        dismissCandidate = null
                    },
                ) { Text("Pas intéressé") }
            },
            dismissButton = { TextButton(onClick = { dismissCandidate = null }) { Text("Annuler") } },
        )
    }

    if (showRemoteDialog) {
        PlayElsewhereDialog(
            peers = onlinePeers,
            status = handoffStatus,
            onPick = { peer ->
                viewModel.playOnPeer(peer.id) {
                    showRemoteDialog = false
                    onBack()
                }
            },
            onDismiss = { showRemoteDialog = false },
        )
    }
}

private class PlayerActions(
    val onBack: () -> Unit,
    val onTogglePlay: () -> Unit,
    val onSeek: (Long) -> Unit,
    val onSeekTo: (Long) -> Unit,
    val onZap: (Int) -> Unit,
    val onToggleFavorite: () -> Unit,
    val onLockScreen: () -> Unit,
    val onUnlockScreen: () -> Unit,
    val onOpenTracks: () -> Unit,
    val onOpenSettings: () -> Unit,
    val onOpenVersions: () -> Unit,
    val onPlayElsewhere: () -> Unit,
    val onPip: () -> Unit,
    val onDownload: () -> Unit,
    val onPlayUpNext: (UpNextItem) -> Unit,
    val onUpNextMenu: (UpNextItem) -> Unit,
    val onRecall: () -> Unit,
    val onStartOver: () -> Unit,
    val onReturnToLive: () -> Unit,
    val onSeekToLiveEdge: () -> Unit,
    val onOpenMirrors: () -> Unit,
    val onOpenChannelsDrawer: () -> Unit,
    val onCycleAspect: () -> Unit,
)

private data class PlayerCapabilities(
    val isLive: Boolean,
    val isCatchupReplay: Boolean,
    val canRecall: Boolean,
    val hasMirrors: Boolean,
    val sleepTimerRemainingSeconds: Int?,
    val canFavorite: Boolean,
    val isFavorite: Boolean,
    val hasTracks: Boolean,
    val hasVersions: Boolean,
    val canPlayElsewhere: Boolean,
    val canPip: Boolean,
    val canDownload: Boolean,
)

/** Full screen on a phone in landscape: status and navigation bars hide, a swipe brings them back. */
@Composable
private fun ImmersiveSystemBars(enabled: Boolean) {
    val activity = LocalContext.current as? Activity ?: return
    DisposableEffect(enabled, activity) {
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        if (enabled) {
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { controller.show(WindowInsetsCompat.Type.systemBars()) }
    }
}

/** The video with its controls: tap shows or hides them, double tap seeks 10 s. */
@Composable
private fun VideoStage(
    viewModel: PlayerViewModel,
    engineState: PlayerEngineState,
    isFullscreen: Boolean,
    isPip: Boolean,
    capabilities: PlayerCapabilities,
    actions: PlayerActions,
    upNextShelf: ImmutableList<UpNextItem>?,
    onInteraction: () -> Unit,
    onOverlayFocus: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val screenState by viewModel.screenState.collectAsStateWithLifecycle()
    val isLive = engineState.activeStream?.kind == StreamKind.LIVE
    // -1 = just went back 10 s, +1 = forward, 0 = nothing to show.
    var seekFeedback by remember { mutableIntStateOf(0) }
    var seekFeedbackTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(seekFeedbackTick) {
        if (seekFeedback != 0) {
            delay(650)
            seekFeedback = 0
        }
    }

    BoxWithConstraints(
        modifier = modifier.pointerInput(isLive, screenState.isScreenLocked) {
            detectTapGestures(
                onTap = {
                    onInteraction()
                    viewModel.toggleControls()
                },
                onDoubleTap = { offset ->
                    onInteraction()
                    if (screenState.isScreenLocked) {
                        viewModel.showControls()
                    } else if (!isLive) {
                        val forward = offset.x > size.width / 2f
                        actions.onSeek(if (forward) SEEK_STEP_MS else -SEEK_STEP_MS)
                        seekFeedback = if (forward) 1 else -1
                        seekFeedbackTick++
                    }
                },
            )
        },
    ) {
        BuntuVideoSurface(videoEngine = viewModel.videoEngine, modifier = Modifier.fillMaxSize())

        if (engineState.isBuffering) {
            CircularProgressIndicator(
                color = BuntuPalette.TerangaGold,
                modifier = Modifier
                    .size(48.dp)
                    .align(Alignment.Center),
            )
        }

        if (seekFeedback != 0) {
            Surface(
                color = Color.Black.copy(alpha = 0.55f),
                shape = CircleShape,
                modifier = Modifier
                    .align(if (seekFeedback > 0) Alignment.CenterEnd else Alignment.CenterStart)
                    .padding(horizontal = maxWidth * 0.12f),
            ) {
                Text(
                    text = if (seekFeedback > 0) "+10 s" else "−10 s",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                )
            }
        }

        if (!isPip) {
            // Smaller controls in the 16:9 strip of a phone in portrait than on a TV or in landscape.
            val compact = maxWidth < 480.dp
            val bigIcon: Dp = if (compact) 40.dp else 56.dp
            val smallIcon: Dp = if (compact) 30.dp else 40.dp

            AnimatedVisibility(
                visible = screenState.controlsVisible,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.fillMaxSize(),
            ) {
                if (screenState.isScreenLocked) {
                    LockedScreenOverlay(
                        isTv = screenState.isTv,
                        onUnlock = actions.onUnlockScreen,
                        onOverlayFocus = onOverlayFocus,
                    )
                } else {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .onFocusChanged { onOverlayFocus(it.hasFocus) },
                    ) {
                        // YouTube-like scrims: dark at the top and the bottom only, the picture stays visible.
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .fillMaxHeight(0.35f)
                                .align(Alignment.TopCenter)
                                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent))),
                        )
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .fillMaxHeight(if (isFullscreen && !upNextShelf.isNullOrEmpty()) 0.6f else 0.4f)
                                .align(Alignment.BottomCenter)
                                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f)))),
                        )

                        TopBar(
                            title = engineState.activeStream?.title,
                            subtitle = engineState.activeStream?.subtitle,
                            showTitle = isFullscreen,
                            capabilities = capabilities,
                            actions = actions,
                            modifier = Modifier
                                .align(Alignment.TopCenter)
                                .fillMaxWidth()
                                .padding(
                                    horizontal = if (isFullscreen) 16.dp else 4.dp,
                                    vertical = if (isFullscreen) 12.dp else 2.dp,
                                ),
                        )

                        CenterControls(
                            isLive = isLive,
                            isPlaying = engineState.isPlaying,
                            bigIcon = bigIcon,
                            smallIcon = smallIcon,
                            actions = actions,
                            modifier = Modifier.align(Alignment.Center),
                        )

                        Column(
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .fillMaxWidth()
                                .padding(
                                    horizontal = if (isFullscreen) 16.dp else 8.dp,
                                    vertical = if (isFullscreen) 12.dp else 0.dp,
                                ),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            if (isFullscreen && !upNextShelf.isNullOrEmpty() && screenState.nextUpCard == null) {
                                UpNextShelfRow(
                                    items = upNextShelf,
                                    onPlay = actions.onPlayUpNext,
                                    onLongPress = actions.onUpNextMenu,
                                )
                            }
                            SeekBar(
                                engineState = engineState,
                                screenState = screenState,
                                isLive = isLive,
                                actions = actions,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TopBar(
    title: String?,
    subtitle: String?,
    showTitle: Boolean,
    capabilities: PlayerCapabilities,
    actions: PlayerActions,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        OverlayIcon(Icons.AutoMirrored.Filled.ArrowBack, "Retour", onClick = actions.onBack)
        if (showTitle) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
            ) {
                Text(
                    text = title ?: "Lecture en cours",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                subtitle?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.75f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (capabilities.isCatchupReplay) {
                Surface(
                    color = BuntuPalette.TerangaGold,
                    shape = RoundedCornerShape(50),
                ) {
                    Text(
                        text = "REPLAY",
                        color = Color.Black,
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                }
                Spacer(modifier = Modifier.width(6.dp))
                OutlinedButton(onClick = actions.onReturnToLive) {
                    Text("Direct", color = Color.White)
                }
            }
            capabilities.sleepTimerRemainingSeconds?.let { remaining ->
                val min = remaining / 60
                val sec = remaining % 60
                Surface(
                    color = Color(0xFF312E81),
                    shape = RoundedCornerShape(50),
                    modifier = Modifier.padding(end = 4.dp),
                ) {
                    Text(
                        text = "Veille %d:%02d".format(min, sec),
                        color = Color.White,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
            if (capabilities.canRecall) {
                OverlayIcon(Icons.Filled.Replay, "Dernière chaîne", onClick = actions.onRecall)
            }
            if (capabilities.isLive) {
                OverlayIcon(Icons.Filled.List, "Mini-Guide chaînes", onClick = actions.onOpenChannelsDrawer)
            }
            if (capabilities.hasMirrors) {
                OverlayIcon(Icons.Filled.Tune, "Qualité et miroirs", onClick = actions.onOpenMirrors)
            }
            if (capabilities.canFavorite) {
                OverlayIcon(
                    icon = if (capabilities.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                    label = if (capabilities.isFavorite) "Retirer des favoris" else "Ajouter aux favoris",
                    tint = if (capabilities.isFavorite) BuntuPalette.TerangaGold else Color.White,
                    onClick = actions.onToggleFavorite,
                )
            }
            if (capabilities.canPlayElsewhere) {
                OverlayIcon(Icons.Filled.Cast, "Lire sur un autre appareil", onClick = actions.onPlayElsewhere)
            }
            if (capabilities.canPip) {
                OverlayIcon(Icons.Filled.PictureInPictureAlt, "Image dans l'image", onClick = actions.onPip)
            }
        } else {
            Spacer(modifier = Modifier.weight(1f))
        }
        OverlayIcon(Icons.Filled.AspectRatio, "Format vidéo", onClick = actions.onCycleAspect)
        if (capabilities.hasTracks) {
            OverlayIcon(Icons.Filled.ClosedCaption, "Audio et sous-titres", onClick = actions.onOpenTracks)
        }
        OverlayIcon(Icons.Filled.Lock, "Verrouiller l'écran", onClick = actions.onLockScreen)
        OverlayIcon(Icons.Filled.Settings, "Réglages de lecture", onClick = actions.onOpenSettings)
    }
}

/**
 * YouTube-style screen lock overlay: all playback controls are hidden and accidental taps/seeks are
 * ignored; only a compact pill at the bottom allows unlocking the screen.
 */
@Composable
private fun LockedScreenOverlay(
    isTv: Boolean,
    onUnlock: () -> Unit,
    onOverlayFocus: (Boolean) -> Unit,
) {
    val unlockFocus = remember { FocusRequester() }
    LaunchedEffect(isTv) {
        if (isTv) runCatching { unlockFocus.requestFocus() }
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .onFocusChanged { onOverlayFocus(it.hasFocus) },
    ) {
        Surface(
            onClick = onUnlock,
            color = Color.Black.copy(alpha = 0.78f),
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 24.dp)
                .focusRequester(unlockFocus),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.LockOpen,
                    contentDescription = null,
                    tint = BuntuPalette.TerangaGold,
                )
                Column {
                    Text(
                        text = "Écran verrouillé",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                    )
                    Text(
                        text = "Appuyer pour déverrouiller",
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.78f),
                    )
                }
            }
        }
    }
}

@Composable
private fun CenterControls(
    isLive: Boolean,
    isPlaying: Boolean,
    bigIcon: Dp,
    smallIcon: Dp,
    actions: PlayerActions,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(bigIcon),
    ) {
        if (isLive) {
            RoundControl(Icons.Filled.SkipPrevious, "Chaîne précédente", smallIcon) { actions.onZap(-1) }
        } else {
            RoundControl(Icons.Filled.Replay10, "Reculer de 10 secondes", smallIcon) { actions.onSeek(-SEEK_STEP_MS) }
        }
        RoundControl(
            icon = if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
            label = if (isPlaying) "Pause" else "Lecture",
            iconSize = bigIcon,
            onClick = actions.onTogglePlay,
        )
        if (isLive) {
            RoundControl(Icons.Filled.SkipNext, "Chaîne suivante", smallIcon) { actions.onZap(+1) }
        } else {
            RoundControl(Icons.Filled.Forward10, "Avancer de 10 secondes", smallIcon) { actions.onSeek(SEEK_STEP_MS) }
        }
    }
}

/** Progress bar with the time, like YouTube; the seek happens when the finger is lifted. */
@Composable
private fun SeekBar(
    engineState: PlayerEngineState,
    screenState: PlayerScreenUiState,
    isLive: Boolean,
    actions: PlayerActions,
) {
    if (isLive) {
        Column(modifier = Modifier.padding(bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                val behindLive = engineState.isLiveSeekable && engineState.liveOffsetMs > 10_000L
                if (behindLive) {
                    OutlinedButton(onClick = actions.onSeekToLiveEdge) {
                        Text("REVENIR AU DIRECT", color = Color.White, style = MaterialTheme.typography.labelSmall)
                    }
                } else {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .background(BuntuPalette.DangerRed, CircleShape),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "EN DIRECT",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.labelMedium,
                    )
                }
                screenState.liveNowSlot?.let { slot ->
                    Spacer(modifier = Modifier.width(10.dp))
                    Text(
                        text = slot.title,
                        color = Color.White,
                        style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                } ?: Spacer(modifier = Modifier.weight(1f))
                screenState.liveRemainingMinutes?.let { min ->
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "($min min rest.)",
                        color = Color.White.copy(alpha = 0.75f),
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
                if (screenState.liveNowSlot != null) {
                    Spacer(modifier = Modifier.weight(1f))
                }
                if (screenState.canStartOverLive) {
                    OutlinedButton(onClick = actions.onStartOver) {
                        Icon(Icons.Filled.Replay, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Revoir depuis le début", color = Color.White, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if (screenState.liveNowSlot != null || screenState.liveProgramProgress > 0f) {
                LinearProgressIndicator(
                    progress = { screenState.liveProgramProgress.coerceIn(0f, 1f) },
                    color = BuntuPalette.DangerRed,
                    trackColor = Color.White.copy(alpha = 0.25f),
                    modifier = Modifier.fillMaxWidth().height(4.dp),
                )
            }
            screenState.liveNextSlot?.let { next ->
                Text(
                    text = "À suivre : ${next.title}",
                    color = Color.White.copy(alpha = 0.78f),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        return
    }
    val onSeekTo = actions.onSeekTo
    val duration = engineState.durationMs
    var dragFraction by remember { mutableStateOf<Float?>(null) }
    val fraction = dragFraction ?: if (duration > 0L) {
        (engineState.positionMs.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
    } else {
        0f
    }
    val shownPosition = dragFraction?.let { (it * duration).toLong() } ?: engineState.positionMs
    Column {
        Text(
            text = "${formatDurationMs(shownPosition)} / ${formatDurationMs(duration)}",
            style = MaterialTheme.typography.labelMedium,
            color = Color.White,
        )
        Slider(
            value = fraction,
            enabled = duration > 0L,
            onValueChange = { dragFraction = it },
            onValueChangeFinished = {
                dragFraction?.let { onSeekTo((it * duration).toLong()) }
                dragFraction = null
            },
            colors = SliderDefaults.colors(
                thumbColor = BuntuPalette.TerangaGold,
                activeTrackColor = BuntuPalette.TerangaGold,
                inactiveTrackColor = Color.White.copy(alpha = 0.3f),
            ),
            modifier = Modifier
                .fillMaxWidth()
                .height(28.dp),
        )
    }
}

/** Below the video in portrait: title, actions as chips, then the "À suivre" list (YouTube's layout). */
@Composable
private fun PortraitDetails(
    engineState: PlayerEngineState,
    capabilities: PlayerCapabilities,
    actions: PlayerActions,
    upNext: ImmutableList<UpNextItem>,
    modifier: Modifier = Modifier,
) {
    val stream = engineState.activeStream
    LazyColumn(
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item(key = "title", contentType = "title") {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Text(
                    text = stream?.title ?: "Lecture en cours",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                val meta = listOfNotNull(
                    stream?.subtitle,
                    if (stream?.kind == StreamKind.LIVE) "En direct" else null,
                    if (engineState.playbackSpeed != 1.0f) NextUpTiming.speedLabel(engineState.playbackSpeed) else null,
                ).joinToString(" · ")
                if (meta.isNotBlank()) {
                    Text(text = meta, style = MaterialTheme.typography.bodySmall, color = BuntuPalette.MutedSilver)
                }
            }
        }
        item(key = "actions", contentType = "actions") {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ActionChip(Icons.Filled.Lock, "Verrouiller", onClick = actions.onLockScreen)
                if (capabilities.canFavorite) {
                    ActionChip(
                        icon = if (capabilities.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                        label = if (capabilities.isFavorite) "Favori" else "Ajouter aux favoris",
                        highlighted = capabilities.isFavorite,
                        onClick = actions.onToggleFavorite,
                    )
                }
                if (capabilities.canPlayElsewhere) {
                    ActionChip(Icons.Filled.Cast, "Lire sur…", onClick = actions.onPlayElsewhere)
                }
                if (capabilities.hasTracks) {
                    ActionChip(Icons.Filled.ClosedCaption, "Audio et sous-titres", onClick = actions.onOpenTracks)
                }
                if (stream?.kind != StreamKind.LIVE) {
                    ActionChip(
                        icon = Icons.Filled.Speed,
                        label = "Vitesse ${NextUpTiming.speedLabel(engineState.playbackSpeed)}",
                        onClick = actions.onOpenSettings,
                    )
                }
                if (capabilities.hasVersions) {
                    ActionChip(Icons.Filled.SwapHoriz, "Autre version", onClick = actions.onOpenVersions)
                }
                if (capabilities.canDownload) {
                    ActionChip(Icons.Filled.Download, "Télécharger", onClick = actions.onDownload)
                }
                if (capabilities.canPip) {
                    ActionChip(Icons.Filled.PictureInPictureAlt, "Image dans l'image", onClick = actions.onPip)
                }
            }
        }
        if (upNext.isNotEmpty()) {
            item(key = "upnext_header", contentType = "header") {
                Text(
                    text = "À suivre",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                )
            }
            items(items = upNext, key = { it.stableHash }, contentType = { "up_next_row" }) { item ->
                UpNextListRow(item = item, onPlay = actions.onPlayUpNext, onLongPress = actions.onUpNextMenu)
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun UpNextListRow(
    item: UpNextItem,
    onPlay: (UpNextItem) -> Unit,
    onLongPress: (UpNextItem) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClickLabel = "Lire",
                onLongClickLabel = "Pas intéressé",
                onClick = { onPlay(item) },
                onLongClick = { onLongPress(item) },
            )
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(140.dp)
                .aspectRatio(16f / 9f)
                .background(BuntuPalette.SlateElevated, RoundedCornerShape(8.dp)),
        ) {
            AsyncImage(
                model = item.posterUrl,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
            if (item.progressFraction > 0f) {
                LinearProgressIndicator(
                    progress = { item.progressFraction },
                    color = BuntuPalette.DangerRed,
                    trackColor = Color.White.copy(alpha = 0.3f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(3.dp)
                        .align(Alignment.BottomCenter),
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = BuntuPalette.PureWhite,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val meta = listOfNotNull(
                item.subtitle,
                item.reasonText.takeIf { it.isNotBlank() },
                if (item.alreadyWatched) "Vu" else null,
            ).joinToString(" · ")
            if (meta.isNotBlank()) {
                Text(
                    text = meta,
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.MutedSilver,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** PRD-27: "À suivre" row over a full-screen video; a long press (Menu key on TV) offers "Pas intéressé". */
@Composable
private fun UpNextShelfRow(
    items: ImmutableList<UpNextItem>,
    onPlay: (UpNextItem) -> Unit,
    onLongPress: (UpNextItem) -> Unit,
) {
    val metrics = LocalBuntuMetrics.current
    Column(verticalArrangement = Arrangement.spacedBy(metrics.spacingXS)) {
        Text(
            text = "À suivre",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = Color.White,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(metrics.spacingS)) {
            items(items = items, key = { it.stableHash }, contentType = { "up_next_card" }) { item ->
                BuntuPosterCard(
                    title = item.title,
                    posterUrl = item.posterUrl,
                    subtitle = listOfNotNull(item.subtitle, item.reasonText.takeIf { it.isNotBlank() })
                        .joinToString(" · ")
                        .ifBlank { null },
                    badge = if (item.alreadyWatched) "Vu" else null,
                    progressFraction = item.progressFraction,
                    onClick = { onPlay(item) },
                    onLongClick = { onLongPress(item) },
                )
            }
        }
    }
}

/** Speed, versions, audio and subtitles: one sheet at a time, at the bottom in portrait, on the right otherwise. */
@Composable
private fun PlayerSheetHost(
    sheet: PlayerSheet,
    engineState: PlayerEngineState,
    screenState: PlayerScreenUiState,
    otherVersions: ImmutableList<MovieItem>,
    capabilities: PlayerCapabilities,
    actions: PlayerActions,
    onSpeed: (Float) -> Unit,
    onSelectAudio: (Int, Int) -> Unit,
    onSelectSubtitle: (Int?, Int?) -> Unit,
    onSubtitleOffset: (Long) -> Unit,
    onSwitchVersion: (MovieItem) -> Unit,
    onSelectAspect: (VideoAspectMode) -> Unit,
    onSleepTimer: (Int?) -> Unit,
    onSwitchMirror: (ChannelItem) -> Unit,
    onSelectChannel: (ChannelItem) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isLive = engineState.activeStream?.kind == StreamKind.LIVE
    val currentStreamId = engineState.activeStream?.itemId
    Surface(
        color = BuntuPalette.Slate.copy(alpha = 0.98f),
        shape = RoundedCornerShape(16.dp),
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item(key = "sheet_title") {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = when (sheet) {
                            PlayerSheet.TRACKS -> "Audio et sous-titres"
                            PlayerSheet.VERSIONS -> "Choisir une autre version"
                            PlayerSheet.MIRRORS -> "Qualité et miroirs"
                            PlayerSheet.CHANNELS -> "Chaînes en direct"
                            else -> "Réglages de lecture"
                        },
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = BuntuPalette.PureWhite,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onClose) { Text("Fermer") }
                }
            }
            when (sheet) {
                PlayerSheet.SETTINGS -> {
                    item(key = "lock_screen") {
                        SheetRow(
                            icon = Icons.Filled.Lock,
                            label = "Verrouiller l'écran",
                            onClick = actions.onLockScreen,
                        )
                    }
                    item(key = "aspect_hdr") { SheetHeader("Format vidéo") }
                    item(key = "aspect_chips") {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            VideoAspectMode.entries.forEach { mode ->
                                FilterChip(
                                    selected = mode == engineState.aspectMode,
                                    onClick = { onSelectAspect(mode) },
                                    label = { Text(mode.label) },
                                )
                            }
                        }
                    }
                    item(key = "sleep_hdr") { SheetHeader("Minuteur de veille") }
                    item(key = "sleep_chips") {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FilterChip(
                                selected = screenState.sleepTimerMinutes == null,
                                onClick = { onSleepTimer(null) },
                                label = { Text("Désactivé") },
                            )
                            listOf(15, 30, 60, 90).forEach { minutes ->
                                FilterChip(
                                    selected = screenState.sleepTimerMinutes == minutes,
                                    onClick = { onSleepTimer(minutes) },
                                    label = { Text("$minutes min") },
                                )
                            }
                        }
                    }
                    if (isLive) {
                        item(key = "to_drawer") {
                            SheetRow(Icons.Filled.List, "Mini-Guide chaînes", onClick = actions.onOpenChannelsDrawer)
                        }
                        if (capabilities.hasMirrors) {
                            item(key = "to_mirrors") {
                                SheetRow(Icons.Filled.Tune, "Qualité / Miroirs", onClick = actions.onOpenMirrors)
                            }
                        }
                    }
                    if (!isLive) {
                        item(key = "speed_hdr") { SheetHeader("Vitesse de lecture") }
                        item(key = "speeds") {
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                NextUpTiming.PLAYBACK_SPEEDS.forEach { speed ->
                                    FilterChip(
                                        selected = speed == engineState.playbackSpeed,
                                        onClick = { onSpeed(speed) },
                                        label = { Text(NextUpTiming.speedLabel(speed)) },
                                    )
                                }
                            }
                        }
                    }
                    if (capabilities.hasTracks) {
                        item(key = "to_tracks") {
                            SheetRow(Icons.Filled.ClosedCaption, "Audio et sous-titres", onClick = actions.onOpenTracks)
                        }
                    }
                    if (capabilities.hasVersions) {
                        item(key = "to_versions") {
                            SheetRow(Icons.Filled.SwapHoriz, "Autre version", onClick = actions.onOpenVersions)
                        }
                    }
                    if (capabilities.canPlayElsewhere) {
                        item(key = "to_remote") {
                            SheetRow(
                                icon = Icons.Filled.Cast,
                                label = "Lire sur un autre appareil",
                                onClick = {
                                    onClose()
                                    actions.onPlayElsewhere()
                                },
                            )
                        }
                    }
                    if (capabilities.canFavorite) {
                        item(key = "fav") {
                            SheetRow(
                                icon = if (capabilities.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
                                label = if (capabilities.isFavorite) "Retirer des favoris" else "Ajouter aux favoris",
                                onClick = actions.onToggleFavorite,
                            )
                        }
                    }
                }
                PlayerSheet.TRACKS -> {
                    if (engineState.audioTracks.isNotEmpty()) {
                        item(key = "audio_hdr") { SheetHeader("Audio") }
                        items(items = engineState.audioTracks, key = { "aud_${it.id}" }) { track ->
                            FilterChip(
                                selected = track.isSelected,
                                onClick = { onSelectAudio(track.groupIndex, track.trackIndex) },
                                label = { Text(track.label) },
                            )
                        }
                    }
                    item(key = "sub_hdr") { SheetHeader("Sous-titres") }
                    item(key = "sub_off") {
                        FilterChip(
                            selected = engineState.subtitlesDisabled,
                            onClick = { onSelectSubtitle(null, null) },
                            label = { Text("Désactivés") },
                        )
                    }
                    items(items = engineState.subtitleTracks, key = { "sub_${it.id}" }) { track ->
                        FilterChip(
                            selected = track.isSelected && !engineState.subtitlesDisabled,
                            onClick = { onSelectSubtitle(track.groupIndex, track.trackIndex) },
                            label = { Text(track.label) },
                        )
                    }
                    item(key = "sub_offset") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            OutlinedButton(onClick = { onSubtitleOffset(engineState.subtitleOffsetMs - 250L) }) {
                                Text("−0,25 s", color = BuntuPalette.PureWhite)
                            }
                            Text("${engineState.subtitleOffsetMs} ms", color = BuntuPalette.MutedSilver)
                            OutlinedButton(onClick = { onSubtitleOffset(engineState.subtitleOffsetMs + 250L) }) {
                                Text("+0,25 s", color = BuntuPalette.PureWhite)
                            }
                        }
                    }
                }
                PlayerSheet.VERSIONS -> {
                    items(items = otherVersions, key = { it.id }) { ver ->
                        OutlinedButton(onClick = { onSwitchVersion(ver) }, modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = "${ver.title} (${ver.containerExtension?.uppercase() ?: "VOD"})",
                                color = BuntuPalette.PureWhite,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                PlayerSheet.MIRRORS -> {
                    items(items = screenState.liveMirrors, key = { it.id }) { mirror ->
                        val active = mirror.id == currentStreamId
                        OutlinedButton(
                            onClick = { onSwitchMirror(mirror) },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = if (active) "✓ ${mirror.name}" else mirror.name,
                                color = if (active) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                PlayerSheet.CHANNELS -> {
                    items(items = screenState.drawerChannels, key = { it.id }) { channel ->
                        val active = channel.id == currentStreamId
                        OutlinedButton(
                            onClick = { onSelectChannel(channel) },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(modifier = Modifier.fillMaxWidth()) {
                                val prefix = channel.channelNumber?.let { "$it · " } ?: ""
                                Text(
                                    text = if (active) "▶ $prefix${channel.name}" else "$prefix${channel.name}",
                                    color = if (active) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
                                    fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                channel.nowTitle?.takeIf(String::isNotBlank)?.let { now ->
                                    Text(
                                        text = now,
                                        color = BuntuPalette.MutedSilver,
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
                PlayerSheet.NONE -> Unit
            }
        }
    }
}

@Composable
private fun SheetHeader(text: String) {
    Text(text, color = BuntuPalette.TerangaGold, fontWeight = FontWeight.Bold)
}

@Composable
private fun SheetRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Icon(icon, contentDescription = null, tint = BuntuPalette.PureWhite)
        Spacer(modifier = Modifier.width(12.dp))
        Text(label, color = BuntuPalette.PureWhite, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun OverlayIcon(
    icon: ImageVector,
    label: String,
    tint: Color = Color.White,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .background(if (focused) BuntuPalette.TerangaGold.copy(alpha = 0.85f) else Color.Transparent, CircleShape)
            .onFocusChanged { focused = it.isFocused },
    ) {
        Icon(icon, contentDescription = label, tint = tint)
    }
}

@Composable
private fun RoundControl(icon: ImageVector, label: String, iconSize: Dp, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(iconSize + 24.dp)
            .background(
                color = if (focused) BuntuPalette.TerangaGold.copy(alpha = 0.85f) else Color.Black.copy(alpha = 0.35f),
                shape = CircleShape,
            )
            .onFocusChanged { focused = it.isFocused },
    ) {
        Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(iconSize))
    }
}

@Composable
private fun ActionChip(
    icon: ImageVector,
    label: String,
    highlighted: Boolean = false,
    onClick: () -> Unit,
) {
    AssistChip(
        onClick = onClick,
        label = { Text(label) },
        leadingIcon = {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (highlighted) BuntuPalette.TerangaGold else BuntuPalette.PureWhite,
            )
        },
        colors = AssistChipDefaults.assistChipColors(
            containerColor = BuntuPalette.SlateElevated,
            labelColor = BuntuPalette.PureWhite,
        ),
        border = null,
        shape = RoundedCornerShape(50),
    )
}

@Composable
private fun BandwidthBanner(
    measuredMbps: Double,
    requiredMbps: Double,
    hasVersions: Boolean,
    canDownload: Boolean,
    onVersions: () -> Unit,
    onDownload: () -> Unit,
    onContinue: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = BuntuPalette.SlateElevated.copy(alpha = 0.96f),
        shape = RoundedCornerShape(14.dp),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Débit insuffisant (%.1f Mb/s mesurés pour ~%.1f Mb/s requis)".format(measuredMbps, requiredMbps),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = BuntuPalette.TerangaGold,
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (hasVersions) {
                    BuntuPrimaryActionButton(label = "Autre version", onClick = onVersions)
                }
                if (canDownload) {
                    OutlinedButton(onClick = onDownload) {
                        Text("Télécharger puis regarder", color = BuntuPalette.PureWhite)
                    }
                }
                OutlinedButton(onClick = onContinue) {
                    Text("Continuer", color = BuntuPalette.MutedSilver)
                }
            }
        }
    }
}

@Composable
private fun PlayElsewhereDialog(
    peers: List<DiscoveredPeer>,
    status: String?,
    onPick: (DiscoveredPeer) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lire sur un autre appareil") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                status?.let { Text(it, color = BuntuPalette.LeerCyan, style = MaterialTheme.typography.bodyMedium) }
                if (peers.isEmpty()) {
                    Text("Aucun appareil du foyer joignable.", style = MaterialTheme.typography.bodySmall)
                } else {
                    peers.forEach { peer ->
                        TextButton(onClick = { onPick(peer) }, modifier = Modifier.fillMaxWidth()) {
                            Icon(
                                imageVector = if (peer.deviceType == "tv") Icons.Filled.Tv else Icons.Filled.PhoneAndroid,
                                contentDescription = null,
                            )
                            Spacer(modifier = Modifier.width(10.dp))
                            Text(peer.name, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Fermer") } },
    )
}

/** PRD-27: "Film suivant / Épisode suivant" card, with Apple's countdown and "Êtes-vous toujours là ?". */
@Composable
private fun NextUpCardOverlay(
    card: NextUpCardState,
    isEnded: Boolean,
    isTv: Boolean,
    onPlayNow: () -> Unit,
    onCredits: () -> Unit,
    onCancelCountdown: () -> Unit,
    onClose: () -> Unit,
    onStillWatching: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val primaryFocus = remember { FocusRequester() }
    // TV: the remote lands on the main button as soon as the card appears.
    LaunchedEffect(isTv, card.item.stableHash, card.askStillWatching) {
        if (isTv) runCatching { primaryFocus.requestFocus() }
    }
    Surface(
        color = BuntuPalette.SlateElevated.copy(alpha = 0.96f),
        shape = RoundedCornerShape(16.dp),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (card.askStillWatching) {
                Text(
                    text = "Êtes-vous toujours là ?",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                )
                Text(
                    text = "La lecture a été suspendue après ${NextUpTiming.MAX_AUTO_CHAIN} enchaînements automatiques.",
                    style = MaterialTheme.typography.bodySmall,
                    color = BuntuPalette.MutedSilver,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    BuntuPrimaryActionButton(
                        label = "Continuer",
                        onClick = onStillWatching,
                        modifier = Modifier.focusRequester(primaryFocus),
                    )
                    OutlinedButton(onClick = onClose) { Text("Arrêter", color = BuntuPalette.PureWhite) }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = card.item.reasonText.ifBlank {
                            if (card.item.kind == StreamKind.VOD_EPISODE) "Épisode suivant" else "Film suivant"
                        },
                        style = MaterialTheme.typography.labelLarge,
                        color = BuntuPalette.LeerCyan,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    card.countdownSecondsRemaining?.let { secs ->
                        Text(
                            text = "${secs}s",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Bold,
                            color = BuntuPalette.TerangaGold,
                        )
                    }
                }
                Text(
                    text = card.item.title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = BuntuPalette.PureWhite,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                card.item.subtitle?.let { sub ->
                    Text(text = sub, style = MaterialTheme.typography.bodySmall, color = BuntuPalette.MutedSilver)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    BuntuPrimaryActionButton(
                        label = "▶ Lire maintenant",
                        onClick = onPlayNow,
                        modifier = Modifier.focusRequester(primaryFocus),
                    )
                    when {
                        card.countdownSecondsRemaining != null ->
                            OutlinedButton(onClick = onCancelCountdown) { Text("Annuler", color = BuntuPalette.PureWhite) }
                        isEnded ->
                            OutlinedButton(onClick = onClose) { Text("Fermer", color = BuntuPalette.PureWhite) }
                        else ->
                            OutlinedButton(onClick = onCredits) { Text("Générique", color = BuntuPalette.PureWhite) }
                    }
                }
            }
        }
    }
}

private fun formatDurationMs(ms: Long): String {
    val totalSecs = (ms / 1_000L).coerceAtLeast(0L)
    val h = totalSecs / 3600L
    val m = (totalSecs % 3600L) / 60L
    val s = totalSecs % 60L
    return if (h > 0L) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}
