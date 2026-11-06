package com.pcoundia.buntu.core.platform.device

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * PRD-37 § 5.2, § 5.3, § 8:
 * Detects Android TV / Google TV (`LEANBACK`), low-RAM devices (Android Go / 2 GB TV boxes),
 * and metered cellular connections.
 */
@Singleton
class DeviceCapabilities private constructor(
    private val isTelevisionProvider: () -> Boolean,
    private val isLowRamProvider: () -> Boolean,
    private val isMeteredProvider: () -> Boolean,
) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        isTelevisionProvider = {
            val pm = context.packageManager
            val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        },
        isLowRamProvider = {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            am?.isLowRamDevice == true
        },
        isMeteredProvider = {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            cm?.isActiveNetworkMetered == true
        },
    )

    constructor(
        isTelevision: Boolean,
        isLowRamDevice: Boolean = false,
        isMetered: Boolean = false,
    ) : this(
        isTelevisionProvider = { isTelevision },
        isLowRamProvider = { isLowRamDevice },
        isMeteredProvider = { isMetered },
    )

    val isTelevision: Boolean by lazy(isTelevisionProvider)

    val isLowRamDevice: Boolean by lazy(isLowRamProvider)

    fun isMeteredNetwork(): Boolean = isMeteredProvider()
}
