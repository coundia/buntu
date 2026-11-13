package com.pcoundia.buntu.core.data

import com.pcoundia.buntu.core.data.repository.ReceivedAiKey
import com.pcoundia.buntu.core.data.repository.applyReceivedAiKey
import com.pcoundia.buntu.core.data.repository.exportHouseholdAiKey
import com.pcoundia.buntu.core.domain.model.AiProviderType
import com.pcoundia.buntu.core.domain.model.AiSettingsConfig
import com.pcoundia.buntu.core.domain.repository.SecretStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class HouseholdAiCredentialsTest {
    private class Vault(var value: String? = null) : SecretStore {
        var reads = 0
        override suspend fun getSecret(alias: String): String? { reads++; return value }
        override suspend fun putSecret(alias: String, plaintext: String) = Unit
        override suspend fun deleteSecret(alias: String) = Unit
    }
    @Test fun `only saved keys are exported for the configured provider`() = runBlocking {
        val vault = Vault("test-only-value")
        for ((provider, wire) in listOf(AiProviderType.GEMINI to "gemini", AiProviderType.OPENAI_COMPATIBLE to "openai_compatible", AiProviderType.CLAUDE to "anthropic")) {
            val dto = exportHouseholdAiKey(AiSettingsConfig(provider = provider), vault)
            assertEquals(wire, dto?.get("provider"))
            assertEquals("test-only-value", dto?.get("api_key"))
        }
        val reads = vault.reads
        assertNull(exportHouseholdAiKey(AiSettingsConfig(provider = AiProviderType.NONE), vault))
        assertEquals(reads, vault.reads)
        vault.value = " "
        assertNull(exportHouseholdAiKey(AiSettingsConfig(provider = AiProviderType.GEMINI), vault))
    }

    private class MapVault(val map: MutableMap<String, String> = mutableMapOf()) : SecretStore {
        override suspend fun getSecret(alias: String) = map[alias]
        override suspend fun putSecret(alias: String, plaintext: String) { map[alias] = plaintext }
        override suspend fun deleteSecret(alias: String) { map.remove(alias) }
    }

    @Test fun `a received key is stored and its provider selected on a device without key`() = runBlocking {
        val vault = MapVault()
        val config = AiSettingsConfig()
        val saved = applyReceivedAiKey(listOf(ReceivedAiKey("anthropic", "test-only-value")), config, vault)
        assertEquals(AiProviderType.CLAUDE, saved?.provider)
        assertEquals("test-only-value", vault.map[config.keyAlias])
    }

    @Test fun `a key already saved on the device is never replaced`() = runBlocking {
        val config = AiSettingsConfig(provider = AiProviderType.GEMINI)
        val vault = MapVault(mutableMapOf(config.keyAlias to "mine"))
        assertNull(applyReceivedAiKey(listOf(ReceivedAiKey("anthropic", "other")), config, vault))
        assertEquals("mine", vault.map[config.keyAlias])
    }

    @Test fun `an unknown provider or a blank key stores nothing`() = runBlocking {
        val vault = MapVault()
        assertNull(applyReceivedAiKey(listOf(ReceivedAiKey("mystery", "x"), ReceivedAiKey("gemini", " ")), AiSettingsConfig(), vault))
        assertTrue(vault.map.isEmpty())
    }
}
