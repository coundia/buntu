package com.pcoundia.buntu.core.platform.work

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.hilt.work.HiltWorker
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.delay

/**
 * PRD-37 § 6 (37.6) & § 8:
 * Keeps Rust downloads alive when the phone screen turns off using `WorkManager` + a foreground
 * service of type `dataSync` (Android 14+ compliant).
 */
@HiltWorker
class DownloadForegroundWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val downloadsRepository: DownloadsRepository,
) : CoroutineWorker(appContext, params) {

    companion object {
        const val UNIQUE_WORK_NAME = "buntu_active_downloads_work"
        private const val CHANNEL_ID = "buntu_downloads"
        private const val NOTIFICATION_ID = 3706

        fun enqueue(context: Context, allowCellular: Boolean) {
            val networkType = if (allowCellular) NetworkType.CONNECTED else NetworkType.UNMETERED
            val request = OneTimeWorkRequestBuilder<DownloadForegroundWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(networkType)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                request,
            )
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = buildForegroundInfo("Téléchargement en cours…", 0)

    override suspend fun doWork(): Result {
        ensureNotificationChannel()
        runCatching { setForeground(getForegroundInfo()) }

        while (!isStopped) {
            val tasks = downloadsRepository.refreshDownloads()
            val active = tasks.filter {
                it.state == "downloading" || it.state == "queued" || it.state == "probing"
            }
            if (active.isEmpty()) {
                return Result.success()
            }
            val primary = active.first()
            val pct = (primary.progressFraction * 100f).toInt().coerceIn(0, 100)
            val label = if (active.size == 1) {
                primary.title
            } else {
                "${primary.title} (+${active.size - 1})"
            }
            runCatching { setForeground(buildForegroundInfo(label, pct)) }
            delay(1_500L)
        }
        return Result.retry()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Téléchargements Buntu",
                NotificationManager.IMPORTANCE_LOW,
            )
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildForegroundInfo(title: String, progressPercent: Int): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Buntu · Téléchargement hors-ligne")
            .setContentText(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, progressPercent, progressPercent == 0)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }
}

