package com.pcoundia.buntu

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.rememberNavController
import com.pcoundia.buntu.core.designsystem.BuntuMetrics
import com.pcoundia.buntu.core.designsystem.BuntuTheme
import com.pcoundia.buntu.core.designsystem.BuntuWindowWidth
import com.pcoundia.buntu.core.domain.model.AppPreferences
import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.logging.RedactedAppLogger
import com.pcoundia.buntu.core.platform.sync.LocalSyncService
import com.pcoundia.buntu.core.player.VideoEngine
import com.pcoundia.buntu.navigation.BuntuRoutes
import com.pcoundia.buntu.ui.MobileShell
import com.pcoundia.buntu.ui.TvShell
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject
    lateinit var settingsRepository: SettingsRepository

    @Inject
    lateinit var sourcesRepository: SourcesRepository

    @Inject
    lateinit var deviceCapabilities: DeviceCapabilities

    @Inject
    lateinit var appLogger: RedactedAppLogger

    @Inject
    lateinit var videoEngine: VideoEngine

    @Inject
    lateinit var householdRepo: HouseholdRepository

    @Inject
    lateinit var remotePlaybackRepo: RemotePlaybackRepository

    @Inject
    lateinit var localSyncService: LocalSyncService

    private var pendingDeepLinkPlayId by mutableStateOf<Long?>(null)
    private var pendingDeepLinkPairUri by mutableStateOf<String?>(null)

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!deviceCapabilities.isTelevision) {
            enableEdgeToEdge()
        }
        extractDeepLinks(intent)
        householdRepo.startSyncService()

        setContent {
            val prefs by settingsRepository.preferencesFlow.collectAsStateWithLifecycle(
                initialValue = AppPreferences(onboardingCompleted = true),
            )
            val sources by sourcesRepository.sourcesFlow.collectAsStateWithLifecycle(
                initialValue = persistentListOf(),
            )
            val sizeClass = calculateWindowSizeClass(this)
            val windowWidth = when (sizeClass.widthSizeClass) {
                WindowWidthSizeClass.Compact -> BuntuWindowWidth.COMPACT
                WindowWidthSizeClass.Medium -> BuntuWindowWidth.MEDIUM
                else -> BuntuWindowWidth.EXPANDED
            }

            val metrics = remember(
                prefs.uiScale,
                windowWidth,
                deviceCapabilities.isTelevision,
                deviceCapabilities.isLowRamDevice,
            ) {
                BuntuMetrics(
                    scale = prefs.uiScale,
                    windowWidth = windowWidth,
                    isTv = deviceCapabilities.isTelevision,
                    isLowRamDevice = deviceCapabilities.isLowRamDevice,
                )
            }

            val navController = rememberNavController()
            val startDest = remember {
                if (prefs.onboardingCompleted || sources.isNotEmpty()) {
                    BuntuRoutes.LIVE
                } else {
                    BuntuRoutes.ONBOARDING
                }
            }

            LaunchedEffect(Unit) {
                sourcesRepository.refreshSourcesList()
                launch {
                    remotePlaybackRepo.incomingPlayInstructions.collect { instruction ->
                        videoEngine.stop()
                        navController.navigate(
                            BuntuRoutes.player(
                                itemId = instruction.itemId,
                                startPositionMs = instruction.positionMs,
                            )
                        )
                    }
                }
                launch {
                    remotePlaybackRepo.streamInterruptedByPeer.collect {
                        videoEngine.stop()
                    }
                }
                launch {
                    videoEngine.state.collect { state ->
                        val active = state.activeStream
                        if (state.isPlaying && active != null) {
                            remotePlaybackRepo.setLocalPlaybackActive(
                                contentKey = active.stableHash,
                                title = active.title,
                                sourceKey = active.host,
                            )
                        } else {
                            remotePlaybackRepo.onLocalPlaybackStopped()
                        }
                    }
                }
            }

            LaunchedEffect(pendingDeepLinkPlayId) {
                val targetId = pendingDeepLinkPlayId ?: return@LaunchedEffect
                pendingDeepLinkPlayId = null
                navController.navigate(BuntuRoutes.player(itemId = targetId))
            }

            LaunchedEffect(pendingDeepLinkPairUri) {
                val pairUri = pendingDeepLinkPairUri ?: return@LaunchedEffect
                pendingDeepLinkPairUri = null
                navController.navigate(BuntuRoutes.sources(pairLink = pairUri)) {
                    popUpTo(BuntuRoutes.SOURCES_PATTERN) { inclusive = true }
                }
            }

            BuntuTheme(metrics = metrics) {
                if (deviceCapabilities.isTelevision) {
                    TvShell(
                        navController = navController,
                        startDestination = startDest,
                        onExitApp = { finish() },
                    )
                } else {
                    MobileShell(
                        navController = navController,
                        startDestination = startDest,
                        windowWidth = windowWidth,
                    )
                }
            }
        }

        window?.let { win ->
            runCatching { appLogger.attachJankStats(win) }
        }
    }

    override fun onResume() {
        super.onResume()
        localSyncService.ensureRunning()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        extractDeepLinks(intent)
    }

    override fun onStop() {
        super.onStop()
        // PRD-37 § 8: On Android TV HDMI standby/sleep, pause active stream so single-connection slot is freed
        if (deviceCapabilities.isTelevision && !isChangingConfigurations) {
            videoEngine.stop()
        }
    }

    private fun extractDeepLinks(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "buntu") return
        when (data.host) {
            "play" -> {
                val id = data.lastPathSegment?.toLongOrNull()
                if (id != null && id > 0L) {
                    pendingDeepLinkPlayId = id
                }
            }
            "pair" -> {
                if (!deviceCapabilities.isTelevision) {
                    pendingDeepLinkPairUri = data.toString()
                }
            }
        }
    }
}

