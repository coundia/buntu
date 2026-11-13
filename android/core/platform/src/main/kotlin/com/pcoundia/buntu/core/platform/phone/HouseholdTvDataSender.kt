package com.pcoundia.buntu.core.platform.phone

import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.TvDataSender
import com.pcoundia.buntu.core.domain.repository.TvDataSendResult
import com.pcoundia.buntu.core.platform.sync.LocalSyncService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

class HouseholdTvDataSender @Inject constructor(
    private val pairing: PairingRepository,
    private val sender: PairingSender,
    private val household: HouseholdRepository,
    private val sync: LocalSyncService,
) : TvDataSender {
    override suspend fun send(scannedLink: String): TvDataSendResult = withContext(Dispatchers.IO) {
        transferHouseholdToTv(scannedLink, pairing, household,
            exchange = { link, message, name -> sender.send(link, message, name) },
            sendData = sync::sendDataToSamsung,
        )
    }
}

/** Testable orchestration; protocol validation and encryption remain in the shared pairing engine. */
internal suspend fun transferHouseholdToTv(
    scannedLink: String,
    pairing: PairingRepository,
    household: HouseholdRepository,
    exchange: suspend (String, String, String) -> PairingSendResult,
    sendData: suspend (String) -> Boolean,
): TvDataSendResult {
    // Link validation and encryption use the existing shared Rust pairing protocol.
    val link = runCatching { pairing.parseLink(scannedLink, System.currentTimeMillis() / 1000) }
        .recoverCatching { pairing.parseLink(scannedLink, 0) }.getOrNull()
        ?: return TvDataSendResult.Failed(PairingFailure.InvalidLink.userMessage())
    if (link.transport != "msf") return TvDataSendResult.Failed("Scannez le QR « Ajouter cette TV à votre foyer » sur la TV Samsung.")
    try {
        if (!household.isJoined.value) household.createHousehold()
        val id = household.householdId.value
            ?: return TvDataSendResult.Failed("Aucun foyer disponible sur ce téléphone.")
        val key = household.currentHouseholdKeyHex()
            ?: return TvDataSendResult.Failed("Aucun foyer disponible sur ce téléphone.")
        val message = buildJsonObject {
            put("type", "household-join")
            put("household_id", id)
            put("household_key", key)
            put("household_name", "Maison")
            put("sender_device_id", household.deviceId)
            put("sender_device_name", household.deviceName)
        }.toString()
        return when (val result = exchange(scannedLink, message, household.deviceName)) {
            is PairingSendResult.Added -> if (sendData(link.host)) {
                TvDataSendResult.Sent(link.tvName)
            } else {
                TvDataSendResult.Failed("TV ajoutée au foyer, mais données non envoyées. Gardez Buntu ouvert sur la TV puis réessayez « Envoyer mes données ».")
            }
            PairingSendResult.Refused -> TvDataSendResult.Refused
            is PairingSendResult.Failed -> TvDataSendResult.Failed(result.reason.userMessage())
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        return TvDataSendResult.Failed("Impossible d’envoyer les données à la TV. Réessayez.")
    }
}
