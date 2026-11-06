package com.pcoundia.buntu.core.platform.tv

import android.annotation.SuppressLint
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * PRD-37 § 5.3 & § 10 (37.8):
 * Publishes in-progress movies and series episodes to the Google TV / Android TV
 * "Continue Watching" (`Watch Next`) launcher row. Safe no-op on phones.
 */
@Singleton
class TvWatchNextPublisher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val deviceCapabilities: DeviceCapabilities,
) : WatchNextPublisher {

    @SuppressLint("RestrictedApi")
    override suspend fun publishContinueWatching(
        itemId: Long,
        title: String,
        posterUrl: String?,
        positionMs: Long,
        durationMs: Long,
        isEpisode: Boolean,
    ) {
        if (!deviceCapabilities.isTelevision || durationMs <= 0L) return
        withContext(Dispatchers.IO) {
            runCatching {
                val ratio = positionMs.toDouble() / durationMs.toDouble()
                if (ratio >= 0.94) {
                    removeFromWatchNext(itemId)
                    return@runCatching
                }

                val internalId = "buntu_item_$itemId"
                val deepLinkIntent = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("buntu://play/$itemId"),
                ).setPackage(context.packageName)

                val builder = WatchNextProgram.Builder()
                    .setType(
                        if (isEpisode) {
                            TvContractCompat.WatchNextPrograms.TYPE_TV_EPISODE
                        } else {
                            TvContractCompat.WatchNextPrograms.TYPE_MOVIE
                        }
                    )
                    .setWatchNextType(TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE)
                    .setLastEngagementTimeUtcMillis(System.currentTimeMillis())
                    .setTitle(title)
                    .setInternalProviderId(internalId)
                    .setIntentUri(Uri.parse(deepLinkIntent.toUri(Intent.URI_INTENT_SCHEME)))
                    .setLastPlaybackPositionMillis(positionMs.toInt())
                    .setDurationMillis(durationMs.toInt())

                if (!posterUrl.isNullOrBlank()) {
                    builder.setPosterArtUri(Uri.parse(posterUrl))
                }

                val values = builder.build().toContentValues()
                val existingId = findWatchNextId(internalId)
                if (existingId != null) {
                    context.contentResolver.update(
                        TvContractCompat.buildWatchNextProgramUri(existingId),
                        values,
                        null,
                        null,
                    )
                } else {
                    context.contentResolver.insert(
                        TvContractCompat.WatchNextPrograms.CONTENT_URI,
                        values,
                    )
                }
            }
        }
    }

    override suspend fun removeFromWatchNext(itemId: Long) {
        if (!deviceCapabilities.isTelevision) return
        withContext(Dispatchers.IO) {
            runCatching {
                val existingId = findWatchNextId("buntu_item_$itemId") ?: return@runCatching
                val uri = ContentUris.withAppendedId(
                    TvContractCompat.WatchNextPrograms.CONTENT_URI,
                    existingId,
                )
                context.contentResolver.delete(uri, null, null)
            }
        }
    }

    private fun findWatchNextId(internalProviderId: String): Long? {
        val projection = arrayOf(
            TvContractCompat.WatchNextPrograms._ID,
            TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID,
        )
        context.contentResolver.query(
            TvContractCompat.WatchNextPrograms.CONTENT_URI,
            projection,
            null,
            null,
            null,
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(TvContractCompat.WatchNextPrograms._ID)
            val providerIdx = cursor.getColumnIndex(TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID)
            while (cursor.moveToNext()) {
                if (idIdx >= 0 && providerIdx >= 0 && cursor.getString(providerIdx) == internalProviderId) {
                    return cursor.getLong(idIdx)
                }
            }
        }
        return null
    }
}

