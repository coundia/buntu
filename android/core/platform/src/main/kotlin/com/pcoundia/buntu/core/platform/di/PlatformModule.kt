package com.pcoundia.buntu.core.platform.di

import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.WatchNextPublisher
import com.pcoundia.buntu.core.platform.security.KeystoreSecretStore
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
    @Singleton
    abstract fun bindSecretStore(impl: KeystoreSecretStore): SecretStore

    @Binds
    @Singleton
    abstract fun bindWatchNextPublisher(impl: TvWatchNextPublisher): WatchNextPublisher
}

