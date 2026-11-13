package com.pcoundia.buntu.core.player

/** Adapter for actual player events: a ready decoder alone does not prove that audio is running. */
internal class LiveStreamHealthObserver(private val report: (String, Boolean) -> Unit) {
    private var hash: String? = null
    private var position = 0L
    private var broken: Boolean? = null
    fun open(liveHash: String?) { hash = liveHash; position = 0; broken = null }
    fun failed() = publish(true)
    fun progress(timeMs: Long, playing: Boolean) {
        if (playing && timeMs > position) publish(false)
        position = timeMs
    }
    private fun publish(value: Boolean) {
        val key = hash ?: return
        if (broken == value) return
        broken = value
        report(key, value)
    }
}
