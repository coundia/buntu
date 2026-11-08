package com.pcoundia.buntu.core.data.sync

import com.pcoundia.buntu.core.data.repository.RustHouseholdSyncRepository
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteParityTest {

    private val repo = RustHouseholdSyncRepository()

    @Test
    fun testPlayRequestSealAndOpenRoundtrip() {
        val keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        val senderId = "dev_android_01"
        val nonce = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
        val msgJson = """{"type":"play_request","target_device_id":"dev_tv_samsung_01","request_id":"req_abc123","content_key":"eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe","source_key":"09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42","item_kind":"movie","provider_ref":"5002","title":"Inception","position_ms":45200,"profile_uuid":"u_dad","replace":true}"""

        val sealed = repo.sealEnvelope(
            householdKeyHex = keyHex,
            senderDeviceId = senderId,
            sequence = 15u,
            nonceBytes = nonce,
            messageJson = msgJson,
        )

        val openedJson = repo.openEnvelope(
            householdKeyHex = keyHex,
            envelope = sealed,
            lastSeenSequence = 14u,
        )

        assertTrue(openedJson.contains("\"type\":\"play_request\""))
        assertTrue(openedJson.contains("\"target_device_id\":\"dev_tv_samsung_01\""))
        assertTrue(openedJson.contains("\"position_ms\":45200"))
        assertTrue(openedJson.contains("\"request_id\":\"req_abc123\""))
    }

    @Test
    fun testSingleStreamRuleLogic() {
        val currentSourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        val releaseSourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        val otherSourceKey = "50da872e2da3b988f27f58dcbb926897ce56a8349fcc842b8a00352799fd8f82"

        assertTrue(currentSourceKey.equals(releaseSourceKey, ignoreCase = true))
        assertFalse(currentSourceKey.equals(otherSourceKey, ignoreCase = true))
    }

    @Test
    fun testXtreamUrlReconstruction() {
        val server = "http://my-iptv-server.com:8080/".trimEnd('/')
        val username = "user123"
        val password = "pass456_fake_placeholder"
        val kind = "live"
        val providerRef = "1001"

        val reconstructed = "$server/live/$username/$password/$providerRef.ts"
        assertEquals("http://my-iptv-server.com:8080/live/user123/pass456_fake_placeholder/1001.ts", reconstructed)
    }
}
