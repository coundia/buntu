package com.pcoundia.buntu.core.platform.di

import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.platform.security.KeystoreSecretStore
import com.pcoundia.buntu.core.platform.sync.LocalSyncService
import com.pcoundia.buntu.core.platform.tv.TvWatchNextPublisher
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class PlatformModule {

    @Binds
    abstract fun bindTvDataSender(impl: com.pcoundia.buntu.core.platform.phone.HouseholdTvDataSender): com.pcoundia.buntu.core.domain.repository.TvDataSender

    @Binds
    @Singleton
    abstract fun bindSecretStore(impl: KeystoreSecretStore): SecretStore

    @Binds
    @Singleton
    abstract fun bindWatchNextPublisher(impl: TvWatchNextPublisher): WatchNextPublisher

    @Binds
    @Singleton
    abstract fun bindHouseholdRepository(impl: LocalSyncService): HouseholdRepository

    @Binds
    @Singleton
    abstract fun bindRemotePlaybackRepository(impl: LocalSyncService): RemotePlaybackRepository
}

