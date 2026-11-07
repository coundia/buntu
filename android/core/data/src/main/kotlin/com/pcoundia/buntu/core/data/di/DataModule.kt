package com.pcoundia.buntu.core.data.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import com.pcoundia.buntu.core.data.repository.DataStoreSettingsRepository
import com.pcoundia.buntu.core.data.repository.RustCatalogRepository
import com.pcoundia.buntu.core.data.repository.RustDiagnosticsRepository
import com.pcoundia.buntu.core.data.repository.RustDownloadsRepository
import com.pcoundia.buntu.core.data.repository.RustEpgRepository
import com.pcoundia.buntu.core.data.repository.RustProfilesRepository
import com.pcoundia.buntu.core.data.repository.RustRecommendationsRepository
import com.pcoundia.buntu.core.data.repository.RustSearchRepository
import com.pcoundia.buntu.core.data.repository.RustPairingRepository
import com.pcoundia.buntu.core.data.repository.RustSourcesRepository
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.DownloadsRepository
import com.pcoundia.buntu.core.domain.repository.EngineDiagnosticsRepository
import com.pcoundia.buntu.core.domain.repository.EpgRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.SearchRepository
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.SourcesRepository
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class DataModule {

    @Binds
    @Singleton
    abstract fun bindSourcesRepository(impl: RustSourcesRepository): SourcesRepository

    @Binds
    @Singleton
    abstract fun bindPairingRepository(impl: RustPairingRepository): PairingRepository

    @Binds
    @Singleton
    abstract fun bindCatalogRepository(impl: RustCatalogRepository): CatalogRepository

    @Binds
    @Singleton
    abstract fun bindEpgRepository(impl: RustEpgRepository): EpgRepository

    @Binds
    @Singleton
    abstract fun bindSearchRepository(impl: RustSearchRepository): SearchRepository

    @Binds
    @Singleton
    abstract fun bindRecommendationsRepository(impl: RustRecommendationsRepository): RecommendationsRepository

    @Binds
    @Singleton
    abstract fun bindDownloadsRepository(impl: RustDownloadsRepository): DownloadsRepository

    @Binds
    @Singleton
    abstract fun bindProfilesRepository(impl: RustProfilesRepository): ProfilesRepository

    @Binds
    @Singleton
    abstract fun bindSettingsRepository(impl: DataStoreSettingsRepository): SettingsRepository

    @Binds
    @Singleton
    abstract fun bindDiagnosticsRepository(impl: RustDiagnosticsRepository): EngineDiagnosticsRepository

    companion object {
        @Provides
        @Singleton
        fun providePreferencesDataStore(
            @ApplicationContext context: Context,
        ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            produceFile = { context.preferencesDataStoreFile("buntu_preferences") },
        )
    }
}

