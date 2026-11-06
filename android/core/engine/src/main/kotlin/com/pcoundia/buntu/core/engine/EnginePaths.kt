package com.pcoundia.buntu.core.engine

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * PRD-37 § 3 & § 7:
 * Resolves SQLite database, cache, downloads, recordings, and share-import directories
 * from Android's `Context` (`filesDir` / `cacheDir`) — zero hardcoded paths in Rust.
 */
@Singleton
class EnginePaths @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    val dbFile: File
        get() = File(context.filesDir, "buntu_catalog.sqlite3")

    val dbPath: String
        get() = dbFile.absolutePath

    val cacheDir: File
        get() = File(context.cacheDir, "cnd_cache").apply { mkdirs() }

    val downloadsDir: File
        get() = File(context.getExternalFilesDir(null) ?: context.filesDir, "downloads").apply { mkdirs() }

    val recordingsDir: File
        get() = File(context.getExternalFilesDir(null) ?: context.filesDir, "recordings").apply { mkdirs() }

    val importsDir: File
        get() = File(context.filesDir, "share_imports").apply { mkdirs() }
}

