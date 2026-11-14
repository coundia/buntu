package com.pcoundia.buntu.core.player

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView

/**
 * PRD-37 § 4.3:
 * Binds a hardware `SurfaceView`-backed `PlayerView` to the singleton `ExoPlayer`.
 * Reused across channel zapping without tearing down the surface!
 */
@OptIn(UnstableApi::class)
@Composable
fun BuntuVideoSurface(
    videoEngine: VideoEngine,
    modifier: Modifier = Modifier,
) {
    val exoEngine = videoEngine as? ExoPlayerVideoEngine ?: return
    val engineState by videoEngine.state.collectAsState()
    val resizeMode = when (engineState.aspectMode) {
        VideoAspectMode.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        VideoAspectMode.FILL -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        VideoAspectMode.STRETCH -> AspectRatioFrameLayout.RESIZE_MODE_FILL
    }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                this.resizeMode = resizeMode
                keepScreenOn = true
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                player = exoEngine.exoPlayer
            }
        },
        update = { view ->
            if (view.player !== exoEngine.exoPlayer) {
                view.player = exoEngine.exoPlayer
            }
            if (view.resizeMode != resizeMode) {
                view.resizeMode = resizeMode
            }
        },
    )
}

