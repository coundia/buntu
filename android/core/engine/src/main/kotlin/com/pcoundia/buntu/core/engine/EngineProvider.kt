package com.pcoundia.buntu.core.engine

import com.pcoundia.buntu.core.engine.ffi.CndEngine
import kotlinx.coroutines.flow.StateFlow

/**
 * PRD-37 § 2.1:
 * `:core:engine` has ONE responsibility: load the native Rust library, expose UniFFI bindings,
 * and initialize a single `CndEngine` off the main thread.
 */
interface EngineProvider {
    val isReady: StateFlow<Boolean>
    val downloadsDirPath: String
    val importsDirPath: String
    suspend fun awaitEngine(): CndEngine
}

