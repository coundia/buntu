package com.pcoundia.buntu.core.platform.pip

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational

/**
 * PRD-37 § 6 (37.6) & § 8:
 * Configures Picture-in-Picture on phones & tablets (never enabled on Android TV).
 */
object PipHelper {

    fun isSupported(activity: Activity, isTv: Boolean): Boolean {
        if (isTv || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    fun updateAutoEnter(activity: Activity, isTv: Boolean, isPlayingVideo: Boolean) {
        if (!isSupported(activity, isTv) || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(isPlayingVideo)
            builder.setSeamlessResizeEnabled(true)
        }
        runCatching { activity.setPictureInPictureParams(builder.build()) }
    }

    fun enterPipNow(activity: Activity, isTv: Boolean): Boolean {
        if (!isSupported(activity, isTv) || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .build()
        return runCatching { activity.enterPictureInPictureMode(params) }.getOrDefault(false)
    }
}

