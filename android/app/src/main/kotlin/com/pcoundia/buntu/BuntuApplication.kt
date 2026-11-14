package com.pcoundia.buntu

import android.app.Application
import android.os.StrictMode
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.memory.MemoryCache
import com.pcoundia.buntu.core.designsystem.i18n.AppLanguageState
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.work.EpgRefreshWorker
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

/**
 * PRD-37 § 5.1, § 8:
 * - Zero heavy initialization on main thread (`CndEngine` initializes lazily on `Dispatchers.IO`)
 * - Enables `StrictMode` in debug builds to catch any main-thread disk/network violation
 * - Configures Coil 3 memory (8% low-RAM / 15% standard) and 250 MB disk poster cache
 * - Provides `HiltWorkerFactory` and schedules periodic background EPG refresh
 */
@HiltAndroidApp
class BuntuApplication : Application(), Configuration.Provider, SingletonImageLoader.Factory {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    @Inject
    lateinit var deviceCapabilities: DeviceCapabilities

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()

    override fun onCreate() {
        super.onCreate()
        AppLanguageState.init(this)
        if (BuildConfig.DEBUG) {
            enableDebugStrictMode()
        }
        runCatching {
            EpgRefreshWorker.schedulePeriodic(this)
        }
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader {
        val ramFraction = if (deviceCapabilities.isLowRamDevice) 0.08 else 0.15
        return ImageLoader.Builder(context)
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizePercent(context, ramFraction)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("buntu_posters"))
                    .maxSizeBytes(250L * 1024L * 1024L)
                    .build()
            }
            .build()
    }

    private fun enableDebugStrictMode() {
        StrictMode.setThreadPolicy(
            StrictMode.ThreadPolicy.Builder()
                .detectNetwork()
                .penaltyLog()
                .build()
        )
        StrictMode.setVmPolicy(
            StrictMode.VmPolicy.Builder()
                .detectLeakedClosableObjects()
                .detectActivityLeaks()
                .penaltyLog()
                .build()
        )
    }
}

