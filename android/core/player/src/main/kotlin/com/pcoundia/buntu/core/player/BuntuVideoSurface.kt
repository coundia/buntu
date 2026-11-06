package com.pcoundia.buntu.core.player

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.compose.runtime.Composable
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

    AndroidView(
        modifier = modifier,
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
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
        },
    )
}

