package com.pcoundia.buntu.core.domain.repository

/** Adds the scanned TV to this phone's household, then sends the household data over encrypted sync. */
interface TvDataSender {
    suspend fun send(scannedLink: String): TvDataSendResult
}

sealed interface TvDataSendResult {
    data class Sent(val tvName: String) : TvDataSendResult
    data object Refused : TvDataSendResult
    data class Failed(val message: String) : TvDataSendResult
}
