package com.pcoundia.buntu.feature.devices

import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdCredentials
import com.pcoundia.buntu.core.domain.repository.HouseholdInviteCodec
import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import com.pcoundia.buntu.core.platform.device.DeviceCapabilities
import com.pcoundia.buntu.core.platform.phone.PhoneQrScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DevicesViewModelTest {

    private val dispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `a pasted household link joins with the key decoded by the shared rule`() = runTest {
        val repo = FakeHousehold()
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.joinHousehold("buntu://household?key=$KEY")
        advanceUntilIdle()

        assertEquals(listOf(KEY), repo.joinedKeys)
        assertNull(vm.uiState.value.errorMessage)
        collector.cancel()
    }

    @Test
    fun `a code that is not a household one is refused without joining`() = runTest {
        val repo = FakeHousehold()
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.joinHousehold("buntu://pair?x=1")
        advanceUntilIdle()

        assertTrue(repo.joinedKeys.isEmpty())
        assertNotNull(vm.uiState.value.errorMessage)
        collector.cancel()
    }

    @Test
    fun `the QR code is built from the current key and hidden on request`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.showInviteQr()
        // The encoding runs on Dispatchers.Default: wait for the state, not for virtual time.
        val qr = vm.uiState.first { it.inviteQr != null }.inviteQr
        assertNotNull(qr)
        assertEquals(qr!!.size * qr.size, qr.pixels.size)
        assertTrue(qr.pixels.any { it })

        vm.hideInviteQr()
        assertNull(vm.uiState.value.inviteQr)
        collector.cancel()
    }

    @Test
    fun `without a household no QR code is shown`() = runTest {
        val vm = viewModel(FakeHousehold(currentKey = null))
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.showInviteQr()
        advanceUntilIdle()

        assertNull(vm.uiState.value.inviteQr)
        assertNotNull(vm.uiState.value.errorMessage)
        collector.cancel()
    }

    @Test
    fun `scanned TV receives data without joining the phone to another household`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }
        vm.sendScannedTv("buntu://pair?test")
        advanceUntilIdle()
        assertEquals("Données envoyées à Salon TV.", vm.uiState.value.infoMessage)
        assertNull(vm.uiState.value.errorMessage)
        assertTrue(repo.joinedKeys.isEmpty())
        collector.cancel()
    }

    @Test
    fun `sendRemoteText forwards trimmed text and ignores blank input`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.sendRemoteText("   ")
        vm.sendRemoteText("")
        advanceUntilIdle()
        assertTrue(repo.sentRemoteTexts.isEmpty())
        assertNull(vm.uiState.value.infoMessage)

        vm.sendRemoteText("Mets France 2")
        vm.sendRemoteText("  Ouvre Arte  ")
        advanceUntilIdle()
        assertEquals(listOf("Mets France 2", "Ouvre Arte"), repo.sentRemoteTexts)
        assertEquals("Commande envoyée à la TV.", vm.uiState.value.infoMessage)
        assertNull(vm.uiState.value.errorMessage)
        collector.cancel()
    }

    @Test
    fun `sendRemoteText failure sets errorMessage and clears infoMessage`() = runTest {
        val repo = FakeHousehold(currentKey = KEY, sendRemoteTextError = IllegalStateException("réseau coupé"))
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }

        vm.sendRemoteText("Mets France 2")
        advanceUntilIdle()

        assertTrue(repo.sentRemoteTexts.isEmpty())
        assertNull(vm.uiState.value.infoMessage)
        assertEquals("Erreur d'envoi: réseau coupé", vm.uiState.value.errorMessage)
        collector.cancel()
    }

    @Test
    fun `unique connected peer is auto-selected and passed as targetPeerId`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        repo.activePeers.value = listOf(
            DiscoveredPeer(id = "tv-1", name = "Samsung TV", deviceType = "tv", state = "idle"),
            DiscoveredPeer(id = "tv-offline", name = "Ancienne TV", deviceType = "tv", state = "offline"),
        )
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }
        advanceUntilIdle()

        assertEquals(1, vm.uiState.value.connectedPeers.size)
        assertEquals("tv-1", vm.uiState.value.selectedTargetId)

        vm.sendRemoteText("Mets France 2")
        advanceUntilIdle()

        assertEquals(listOf("Mets France 2" to "tv-1"), repo.sentRemoteCommands)
        collector.cancel()
    }

    @Test
    fun `multiple connected peers default to all (null) and support explicit selection`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        repo.activePeers.value = listOf(
            DiscoveredPeer(id = "tv-1", name = "TV Salon", deviceType = "tv", state = "idle"),
            DiscoveredPeer(id = "tv-2", name = "TV Chambre", deviceType = "tv", state = "playing"),
        )
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }
        advanceUntilIdle()

        assertEquals(2, vm.uiState.value.connectedPeers.size)
        assertNull(vm.uiState.value.selectedTargetId)

        vm.sendRemoteText("Pause")
        advanceUntilIdle()
        assertEquals(listOf("Pause" to null), repo.sentRemoteCommands)

        vm.selectTargetDevice("tv-2")
        advanceUntilIdle()
        assertEquals("tv-2", vm.uiState.value.selectedTargetId)

        vm.sendRemoteText("Ouvre Arte")
        advanceUntilIdle()
        assertEquals(
            listOf("Pause" to null, "Ouvre Arte" to "tv-2"),
            repo.sentRemoteCommands,
        )

        vm.selectTargetDevice(null)
        advanceUntilIdle()
        assertNull(vm.uiState.value.selectedTargetId)
        collector.cancel()
    }

    @Test
    fun `no connected peers leaves selectedTargetId null`() = runTest {
        val repo = FakeHousehold(currentKey = KEY)
        repo.activePeers.value = listOf(
            DiscoveredPeer(id = "tv-1", name = "TV Salon", deviceType = "tv", state = "offline"),
        )
        val vm = viewModel(repo)
        val collector = backgroundScope.launch { vm.uiState.collect {} }
        advanceUntilIdle()

        assertTrue(vm.uiState.value.connectedPeers.isEmpty())
        assertNull(vm.uiState.value.selectedTargetId)
        collector.cancel()
    }

    @Test
    fun refreshPeersCallsRepository() = runTest {
        val fakeRepo = FakeHousehold()
        val vm = viewModel(fakeRepo)

        vm.refreshPeers()

        assertEquals(1, fakeRepo.refreshCount)
    }

    private fun viewModel(repo: FakeHousehold) = DevicesViewModel(
        householdRepo = repo,
        inviteCodec = FakeInviteCodec,
        qrScanner = PhoneQrScanner(),
        tvDataSender = object : com.pcoundia.buntu.core.domain.repository.TvDataSender {
            override suspend fun send(scannedLink: String) = com.pcoundia.buntu.core.domain.repository.TvDataSendResult.Sent("Salon TV")
        },
        deviceCapabilities = DeviceCapabilities(isTelevision = false),
    )

    private companion object {
        const val KEY = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    }
}

/** Stands in for the Rust rule (`cnd_domain::sync::invite`, tested in Rust): the native library is not loaded here. */
private object FakeInviteCodec : HouseholdInviteCodec {
    private const val PREFIX = "buntu://household?key="

    override suspend fun inviteLink(keyHex: String): String? =
        keyHex.takeIf { it.length == 64 }?.let { PREFIX + it }

    override suspend fun keyFromScanned(text: String): String? = when {
        text.length == 64 -> text
        text.startsWith(PREFIX) -> text.removePrefix(PREFIX).takeIf { it.length == 64 }
        else -> null
    }
}

private class FakeHousehold(
    private val currentKey: String? = null,
    private val sendRemoteTextError: Throwable? = null,
) : HouseholdRepository {
    val joinedKeys = mutableListOf<String>()
    val sentRemoteCommands = mutableListOf<Pair<String, String?>>()
    val sentRemoteTexts: List<String> get() = sentRemoteCommands.map { it.first }
    var refreshCount = 0

    override val isJoined: StateFlow<Boolean> = MutableStateFlow(currentKey != null)
    override val householdId: StateFlow<String?> = MutableStateFlow(null)
    override val deviceId: String = "device-1"
    override val deviceName: String = "Téléphone"
    override val deviceType: String = "mobile"
    override val syncStatus: StateFlow<String> = MutableStateFlow("Prêt")
    override val activePeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    override val syncLog: StateFlow<List<SyncLogEntry>> = MutableStateFlow(emptyList())

    override suspend fun createHousehold(): DomainHouseholdCredentials = DomainHouseholdCredentials("h", "k")
    override suspend fun joinHousehold(keyHex: String): String {
        joinedKeys += keyHex
        return "household-1"
    }
    override suspend fun leaveHousehold() = Unit
    override suspend fun sendNow() = Unit
    override suspend fun receiveNow() = Unit
    override suspend fun sendRemoteText(text: String, targetPeerId: String?) {
        sendRemoteTextError?.let { throw it }
        sentRemoteCommands += text to targetPeerId
    }
    override suspend fun refreshPeers() {
        refreshCount += 1
    }
    override suspend fun currentHouseholdKeyHex(): String? = currentKey
    override fun startSyncService() = Unit
    override fun stopSyncService() = Unit
}
