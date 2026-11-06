package com.pcoundia.buntu.core.player.di

import com.pcoundia.buntu.core.player.ExoPlayerVideoEngine
import com.pcoundia.buntu.core.player.VideoEngine
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class PlayerModule {

    @Binds
    @Singleton
    abstract fun bindVideoEngine(impl: ExoPlayerVideoEngine): VideoEngine
}

