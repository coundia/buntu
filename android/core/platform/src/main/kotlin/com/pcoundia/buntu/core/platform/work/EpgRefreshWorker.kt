package com.pcoundia.buntu.core.platform.work

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.pcoundia.buntu.core.domain.usecase.SyncSourceUseCase
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import java.util.concurrent.TimeUnit

/**
 * PRD-37 § 8:
 * Periodically refreshes stale EPG TV guides in the background via WorkManager.
 */
@HiltWorker
class EpgRefreshWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val syncSourceUseCase: SyncSourceUseCase,
) : CoroutineWorker(appContext, params) {

    companion object {
        private const val UNIQUE_PERIODIC_NAME = "buntu_periodic_epg_refresh"

        fun schedulePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<EpgRefreshWorker>(12, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.UNMETERED)
                        .setRequiresBatteryNotLow(true)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_PERIODIC_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }

    override suspend fun doWork(): Result {
        return runCatching {
            syncSourceUseCase.syncAllStaleEpg()
            Result.success()
        }.getOrElse {
            Result.retry()
        }
    }
}

