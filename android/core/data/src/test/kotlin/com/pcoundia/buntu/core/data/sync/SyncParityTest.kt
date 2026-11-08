package com.pcoundia.buntu.core.data.sync

import com.pcoundia.buntu.core.data.repository.RustHouseholdSyncRepository
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SyncParityTest {

    private val repo = RustHouseholdSyncRepository()

    @Test
    fun testSourceKeyXtreamParity() {
        val server = "http://My-Provider.COM:8080/path/"
        val username = "UserTest1"
        val key = repo.computeSourceKey("xtream", server, username)
        assertEquals("09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42", key)
    }

    @Test
    fun testSourceKeyM3uParity() {
        val url = "http://my-iptv.net:8000/get.php?username=alice&password=secret&type=m3u_plus"
        val key = repo.computeSourceKey("m3u", url, null)
        assertEquals("50da872e2da3b988f27f58dcbb926897ce56a8349fcc842b8a00352799fd8f82", key)
    }

    @Test
    fun testContentKeyLiveParity() {
        val sourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        val contentKey = repo.computeContentKey(sourceKey, "live", "1001")
        assertEquals("eeeb12e4004a2cc37dbf6b5a296d06cf9540088628158a4ed8eb2cbec359ebfe", contentKey)
    }

    @Test
    fun testContentKeyMovieParity() {
        val sourceKey = "09aaef741e3cdf73c3d8422cc78912c9d9e31c389e3438539833056f8f3fcb42"
        val contentKey = repo.computeContentKey(sourceKey, "movie", "5002")
        assertEquals("f842040521748226742432154eb9904ccd45b2e598bd8b42bfca99dd1e62237b", contentKey)
    }

    @Test
    fun testHouseholdIdDerivationParity() {
        val keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        val hhId = repo.deriveHouseholdId(keyHex)
        assertEquals("buntu_hh_8c587a530f9f3a19", hhId)
    }

    @Test
    fun testEnvelopeSealAndOpenRoundtrip() {
        val keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        val senderId = "dev_android_test_1"
        val nonce = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
        val msgJson = "{\"type\":\"play_remote\",\"content_key\":\"test_key_1\",\"position_ms\":42000,\"title\":null,\"source_key\":null}"

        val env = repo.sealEnvelope(
            householdKeyHex = keyHex,
            senderDeviceId = senderId,
            sequence = 1uL,
            nonceBytes = nonce,
            messageJson = msgJson,
        )

        assertEquals("buntu_hh_8c587a530f9f3a19", env.householdId)
        assertEquals(senderId, env.senderDeviceId)
        assertEquals(1uL, env.sequence)

        val opened = repo.openEnvelope(
            householdKeyHex = keyHex,
            envelope = env,
            lastSeenSequence = 0uL,
        )
        assertEquals(msgJson, opened)
    }

    @Test
    fun testEnvelopeReplayRejected() {
        val keyHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
        val senderId = "dev_android_test_1"
        val nonce = byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
        val msgJson = "{\"type\":\"ping\"}"

        val env = repo.sealEnvelope(
            householdKeyHex = keyHex,
            senderDeviceId = senderId,
            sequence = 5uL,
            nonceBytes = nonce,
            messageJson = msgJson,
        )

        assertThrows(Exception::class.java) {
            repo.openEnvelope(
                householdKeyHex = keyHex,
                envelope = env,
                lastSeenSequence = 5uL,
            )
        }
    }
}

