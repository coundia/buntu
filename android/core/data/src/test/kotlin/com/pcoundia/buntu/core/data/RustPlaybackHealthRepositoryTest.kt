package com.pcoundia.buntu.core.data

import com.pcoundia.buntu.core.data.repository.RustPlaybackHealthRepository
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.CndEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RustPlaybackHealthRepositoryTest {
    @Test fun `failure and recovery persist in Rust and update displayed statuses`() = runBlocking {
        val engine = CndEngine.inMemory()
        val provider = object : EngineProvider {
            override val isReady = MutableStateFlow(true)
            override val downloadsDirPath = ""
            override val importsDirPath = ""
            override suspend fun awaitEngine() = engine
        }
        val repo = RustPlaybackHealthRepository(provider)
        repo.setLiveBroken("health-live", true)
        assertTrue(engine.isBroken("health-live"))
        assertEquals(true, repo.brokenChannels.value["health-live"])
        repo.setLiveBroken("health-live", false)
        assertFalse(engine.isBroken("health-live"))
        assertEquals(false, repo.brokenChannels.value["health-live"])
    }
}
