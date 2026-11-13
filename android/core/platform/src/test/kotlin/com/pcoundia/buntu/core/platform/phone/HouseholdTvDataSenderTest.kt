package com.pcoundia.buntu.core.platform.phone

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import com.pcoundia.buntu.core.domain.repository.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy

class HouseholdTvDataSenderTest {
    @Test fun `household is sealed first and data is sent only after TV acceptance`() = runTest {
        val household = SendingHousehold()
        val calls = mutableListOf<String>()
        val result = transferHouseholdToTv("qr", pairing(), household, exchange = { _, message, name ->
            calls += "pair"
            val payload = Json.parseToJsonElement(message).jsonObject
            assertEquals("household-join", payload["type"]?.jsonPrimitive?.content)
            assertEquals("test-house", payload["household_id"]?.jsonPrimitive?.content)
            assertEquals("phone", payload["sender_device_id"]?.jsonPrimitive?.content)
            assertEquals("Téléphone", name)
            assertFalse(message.contains("password"))
            PairingSendResult.Added(1)
        }, sendData = { host ->
            calls += "data"
            assertEquals("192.0.2.1", host)
            true
        })
        assertEquals(listOf("pair", "data"), calls)
        assertEquals(TvDataSendResult.Sent("Salon TV"), result)
        assertEquals(0, household.created)
    }

    @Test fun `refusal on TV sends no data`() = runTest {
        var sent = false
        val result = transferHouseholdToTv("qr", pairing(), SendingHousehold(),
            exchange = { _, _, _ -> PairingSendResult.Refused }, sendData = { sent = true; true })
        assertEquals(TvDataSendResult.Refused, result)
        assertFalse(sent)
    }

    @Test fun `invalid QR does not create a household or send anything`() = runTest {
        val household = SendingHousehold(joined = false)
        val result = transferHouseholdToTv("invalid", pairing(valid = false), household,
            exchange = { _, _, _ -> error("must not send") }, sendData = { error("must not send") })
        assertTrue(result is TvDataSendResult.Failed)
        assertEquals(0, household.created)
    }

    @Test fun `a phone without a household creates one after validating the TV QR`() = runTest {
        val household = SendingHousehold(joined = false)
        val result = transferHouseholdToTv("qr", pairing(), household,
            exchange = { _, _, _ -> PairingSendResult.Added(1) }, sendData = { true })
        assertTrue(result is TvDataSendResult.Sent)
        assertEquals(1, household.created)
    }

    @Test fun `failure to send data never reports a successful transfer`() = runTest {
        val result = transferHouseholdToTv("qr", pairing(), SendingHousehold(),
            exchange = { _, _, _ -> PairingSendResult.Added(1) }, sendData = { false })
        assertTrue(result is TvDataSendResult.Failed)
        assertTrue((result as TvDataSendResult.Failed).message.contains("données non envoyées"))
    }

    private fun pairing(valid: Boolean = true) = Proxy.newProxyInstance(
        PairingRepository::class.java.classLoader, arrayOf(PairingRepository::class.java),
    ) { _, method, _ ->
        check(valid && method.name == "parseLink")
        PairingLink("test", "Salon TV", "msf", "192.0.2.1", 8001, 9999999999)
    } as PairingRepository
}

private class SendingHousehold(joined: Boolean = true) : HouseholdRepository {
    override val isJoined = MutableStateFlow(joined)
    override val householdId = MutableStateFlow<String?>(if (joined) "test-house" else null)
    override val deviceId = "phone"
    override val deviceName = "Téléphone"
    override val deviceType = "mobile"
    override val syncStatus = MutableStateFlow("Prêt")
    override val activePeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    override val syncLog = MutableStateFlow<List<SyncLogEntry>>(emptyList())
    var created = 0
    override suspend fun createHousehold(): DomainHouseholdCredentials {
        created++
        isJoined.value = true
        householdId.value = "test-house"
        return DomainHouseholdCredentials("test-house", "fixture-key")
    }
    override suspend fun currentHouseholdKeyHex(): String? = if (isJoined.value) "fixture-key" else null
    override suspend fun joinHousehold(keyHex: String): String = error("must not replace phone household")
    override suspend fun leaveHousehold() = Unit
    override suspend fun sendNow() = Unit
    override suspend fun receiveNow() = Unit
    override fun startSyncService() = Unit
    override fun stopSyncService() = Unit
}
