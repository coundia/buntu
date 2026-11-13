package com.pcoundia.buntu.core.player

import org.junit.Assert.assertEquals
import org.junit.Test

class LiveStreamHealthObserverTest {
    @Test fun `error then advancing audio clears broken status without any video event`() {
        val changes = mutableListOf<Pair<String, Boolean>>()
        val observer = LiveStreamHealthObserver { hash, broken -> changes += hash to broken }
        observer.open("channel")
        observer.failed()
        observer.progress(0, true)
        observer.progress(1000, true)
        observer.progress(2000, true)
        assertEquals(listOf("channel" to true, "channel" to false), changes)
    }
    @Test fun `changing channels and stopping cannot carry old status to the next stream`() {
        val changes = mutableListOf<Pair<String, Boolean>>()
        val observer = LiveStreamHealthObserver { hash, broken -> changes += hash to broken }
        observer.open("first"); observer.failed()
        observer.open("second"); observer.progress(0, true); observer.progress(1000, true)
        observer.open(null); observer.failed(); observer.progress(2000, true)
        assertEquals(listOf("first" to true, "second" to false), changes)
    }
    @Test fun `a seek or repeated timestamp while paused is not recovery`() {
        val changes = mutableListOf<Boolean>()
        val observer = LiveStreamHealthObserver { _, broken -> changes += broken }
        observer.open("channel"); observer.failed()
        observer.progress(5000, false)
        observer.progress(5000, true)
        assertEquals(listOf(true), changes)
        observer.progress(6000, true)
        assertEquals(listOf(true, false), changes)
    }
}
