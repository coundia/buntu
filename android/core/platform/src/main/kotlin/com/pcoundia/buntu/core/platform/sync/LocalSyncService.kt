package com.pcoundia.buntu.core.platform.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import com.pcoundia.buntu.core.domain.model.ActiveRemoteControlSession
import com.pcoundia.buntu.core.domain.model.DiscoveredPeer
import com.pcoundia.buntu.core.domain.model.IncomingPlayInstruction
import com.pcoundia.buntu.core.domain.model.SyncLogEntry
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdCredentials
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import com.pcoundia.buntu.core.domain.repository.HouseholdRepository
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncEngineBridge
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncRepository
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume

/**
 * Household transport of Android (PRD-41, PRD-42, PRD-44), aligned on Apple `LocalSyncService.swift`:
 * NSD `_buntu-sync._tcp` + persistent TCP connections (4-byte big-endian length + envelope JSON),
 * presence every 30 s, "offline" after 120 s, and the Samsung TV reached through its channel
 * (PRD-45 lot 45.4, [SamsungChannelTransport]).
 *
 * Nothing here runs on the main thread: every public entry point hops to [scope] (`Dispatchers.IO`).
 * Envelopes are sealed and opened in Rust ([HouseholdSyncRepository]); no stream URL, password or key
 * is ever written to the journal.
 */
@Singleton
class LocalSyncService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val store: HouseholdStore,
    private val syncRepo: HouseholdSyncRepository,
    private val engineBridge: HouseholdSyncEngineBridge,
) : HouseholdRepository, RemotePlaybackRepository {

    companion object {
        const val SERVICE_TYPE = "_buntu-sync._tcp."
        private const val HEARTBEAT_MS = 30_000L
        private const val OFFLINE_THRESHOLD_MS = 120_000L
        private const val MAX_PAYLOAD_SIZE = 10_000_000
        /** PRD-42 § 5.2: one request every 2 s per sender. */
        private const val MIN_REQUEST_INTERVAL_MS = 2_000L
        /** PRD-42 § 3.2: a `play_ready` holds the target 10 s, waiting for `play_go`. */
        private const val RESERVATION_TTL_MS = 10_000L
    }

    class PeerConnection(
        val socket: Socket,
        val input: DataInputStream,
        val output: DataOutputStream,
    ) {
        val writeMutex = Mutex()
        val isAlive: Boolean
            get() = socket.isConnected && !socket.isClosed

        fun close() {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private data class PendingReservation(
        val requestId: String,
        val senderId: String,
        val itemId: Long,
        val title: String?,
        val positionMs: Long,
        val sourceKey: String?,
        val createdAt: Long = System.currentTimeMillis(),
    )

    private data class PendingHandoff(
        val requestId: String,
        val targetPeerId: String,
        val readyDeferred: CompletableDeferred<Unit>,
    )

    private data class PeerPresence(val state: String, val canPlay: Boolean)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = Mutex()
    private val resolveMutex = Mutex()
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null

    @Volatile private var running = false
    private var serverSocket: ServerSocket? = null
    private var serverJob: Job? = null
    private var heartbeatJob: Job? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var syncDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var tvDiscoveryListener: NsdManager.DiscoveryListener? = null

    private val samsung = SamsungChannelTransport(scope)

    // Persistent connections
    private val connections = ConcurrentHashMap<String, PeerConnection>()
    private val connecting = ConcurrentHashMap.newKeySet<String>()
    private val deviceConnections = ConcurrentHashMap<String, PeerConnection>()
    private val incomingConnections = ConcurrentHashMap<PeerConnection, Boolean>()
    private val announcedConnections = ConcurrentHashMap.newKeySet<PeerConnection>()
    private val connectionDeviceIds = ConcurrentHashMap<PeerConnection, String>()
    private val peerEndpoints = ConcurrentHashMap<String, Pair<String, Int>>()
    /** Devices already answered on the Samsung channel (once per channel connection, PRD-45 § 3.3). */
    private val channelAnsweredDevices = ConcurrentHashMap.newKeySet<String>()
    private val peerPresence = ConcurrentHashMap<String, PeerPresence>()

    // Handoff state
    private val pendingReservations = ConcurrentHashMap<String, PendingReservation>()
    private val pendingHandoffs = ConcurrentHashMap<String, PendingHandoff>()
    private val lastRequestAt = ConcurrentHashMap<String, Long>()

    // Local playback, for the "one stream per account" rule
    @Volatile private var currentLocalContentKey: String? = null
    @Volatile private var currentLocalSourceKey: String? = null

    @Volatile private var lastExportTimestamp: Long = 0L

    // HouseholdRepository
    override val isJoined: StateFlow<Boolean> = store.isJoined
    override val householdId: StateFlow<String?> = store.householdId
    override val deviceId: String get() = store.deviceId
    override val deviceName: String get() = store.deviceName
    override val deviceType: String get() = store.deviceType

    private val _syncStatus = MutableStateFlow("Prêt")
    override val syncStatus: StateFlow<String> = _syncStatus.asStateFlow()

    private val _activePeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    override val activePeers: StateFlow<List<DiscoveredPeer>> = _activePeers.asStateFlow()

    private val _syncLog = MutableStateFlow<List<SyncLogEntry>>(emptyList())
    override val syncLog: StateFlow<List<SyncLogEntry>> = _syncLog.asStateFlow()

    // RemotePlaybackRepository
    override val availablePeers: StateFlow<List<DiscoveredPeer>> = _activePeers.asStateFlow()
    override val isHouseholdActive: StateFlow<Boolean> = store.isJoined

    private val _activeHandoffStatus = MutableStateFlow<String?>(null)
    override val activeHandoffStatus: StateFlow<String?> = _activeHandoffStatus.asStateFlow()

    private val _activeRemoteSession = MutableStateFlow<ActiveRemoteControlSession?>(null)
    override val activeRemoteSession: StateFlow<ActiveRemoteControlSession?> = _activeRemoteSession.asStateFlow()

    private val _incomingPlayInstructions = MutableSharedFlow<IncomingPlayInstruction>(extraBufferCapacity = 16)
    override val incomingPlayInstructions: SharedFlow<IncomingPlayInstruction> = _incomingPlayInstructions.asSharedFlow()

    private val _streamInterruptedByPeer = MutableSharedFlow<String>(extraBufferCapacity = 16)
    override val streamInterruptedByPeer: SharedFlow<String> = _streamInterruptedByPeer.asSharedFlow()

    /** Unique per device (PRD-44 § 3.2.5): the random part of the device id, not its "android_" prefix. */
    private val ownUniqueSuffix: String
        get() = store.deviceId.substringAfter("_").take(8)

    private val ownServiceName: String
        get() = "${store.deviceName} ($ownUniqueSuffix)"

    init {
        samsung.onConnected = {
            channelAnsweredDevices.clear()
            scope.launch { sendAnnounceOnChannel() }
        }
        samsung.onDisconnected = { tvs ->
            tvs.forEach { log("${peerName(it)} n'est plus joignable.") }
            refreshActivePeers()
        }
        samsung.onEnvelopeReceived = { envelope -> scope.launch { processChannelEnvelope(envelope) } }
    }

    // MARK: - Lifecycle (never on the caller's thread)

    /** At app start: reloads the household from the Keystore, then starts if this device is in one. */
    override fun startSyncService() {
        scope.launch { lifecycleMutex.withLock { if (!running) { store.loadFromStore(); startLocked() } } }
    }

    override fun stopSyncService() {
        scope.launch { lifecycleMutex.withLock { stopLocked() } }
    }

    /** Back in the foreground (like `ensureRunning()` on Apple): restarts what the system closed. */
    fun ensureRunning() {
        scope.launch {
            lifecycleMutex.withLock {
                if (!running) {
                    store.loadFromStore()
                    startLocked()
                    return@withLock
                }
                if (serverSocket == null || serverSocket?.isClosed == true) {
                    stopServer()
                    startServer()
                }
                if (syncDiscoveryListener == null || tvDiscoveryListener == null) startDiscovery()
            }
            if (running) heartbeat()
        }
    }

    private fun startLocked() {
        if (!store.isJoined.value) {
            _syncStatus.value = "Aucun foyer configuré"
            return
        }
        running = true
        log("Recherche des appareils du foyer sur le réseau local…")
        acquireMulticastLock()
        startServer()
        startDiscovery()
        store.householdId.value?.takeIf { it.isNotEmpty() }?.let { samsung.start(it) }
        startHeartbeat()
        _syncStatus.value = "Synchronisation active"
    }

    private fun stopLocked() {
        running = false
        stopHeartbeat()
        stopDiscovery()
        stopServer()
        samsung.stop()
        releaseMulticastLock()

        connections.values.forEach { it.close() }
        connections.clear()
        incomingConnections.keys.forEach { it.close() }
        incomingConnections.clear()
        deviceConnections.clear()
        announcedConnections.clear()
        connectionDeviceIds.clear()
        peerEndpoints.clear()
        pendingReservations.clear()
        pendingHandoffs.clear()
        channelAnsweredDevices.clear()
        peerPresence.clear()

        _activePeers.value = emptyList()
        _syncStatus.value = "Arrêté"
    }

    private fun acquireMulticastLock() {
        try {
            if (multicastLock == null) {
                multicastLock = wifiManager?.createMulticastLock("buntu_sync_multicast")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        multicastLock = null
    }

    // MARK: - TCP server & NSD registration

    private fun startServer() {
        if (serverSocket != null) return
        try {
            val server = ServerSocket(0)
            serverSocket = server
            registerNsdService(server.localPort)
            serverJob = scope.launch {
                while (isActive && !server.isClosed) {
                    try {
                        val client = server.accept()
                        val connection = PeerConnection(
                            socket = client,
                            input = DataInputStream(client.getInputStream()),
                            output = DataOutputStream(client.getOutputStream()),
                        )
                        incomingConnections[connection] = true
                        launch { readLoop(connection) }
                    } catch (_: Exception) {
                        break
                    }
                }
            }
        } catch (_: Exception) {
            _syncStatus.value = "Erreur au démarrage du service local"
        }
    }

    private fun stopServer() {
        unregisterNsdService()
        serverJob?.cancel()
        serverJob = null
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
    }

    private fun registerNsdService(port: Int) {
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = ownServiceName
            serviceType = SERVICE_TYPE
            this.port = port
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                _syncStatus.value = "Synchronisation active"
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                _syncStatus.value = "Échec de l'annonce sur le réseau local ($errorCode)"
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registrationListener = listener
        try {
            nsdManager?.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {}
    }

    private fun unregisterNsdService() {
        registrationListener?.let { try { nsdManager?.unregisterService(it) } catch (_: Exception) {} }
        registrationListener = null
    }

    // MARK: - NSD discovery

    private fun startDiscovery() {
        if (syncDiscoveryListener == null) {
            syncDiscoveryListener = discover(SERVICE_TYPE,
                onFound = { service ->
                    if (service.serviceName == ownServiceName || service.serviceName.contains(ownUniqueSuffix)) return@discover
                    scope.launch { resolveSyncPeer(service) }
                },
                onLost = { service ->
                    peerEndpoints.remove(service.serviceName)
                    connections.remove(service.serviceName)?.close()
                    refreshActivePeers()
                },
            )
        }
        if (tvDiscoveryListener == null) {
            tvDiscoveryListener = discover(SamsungChannelTransport.SERVICE_TYPE,
                onFound = { service -> scope.launch { resolveTv(service) } },
                onLost = {},
            )
        }
    }

    private fun discover(
        type: String,
        onFound: (NsdServiceInfo) -> Unit,
        onLost: (NsdServiceInfo) -> Unit,
    ): NsdManager.DiscoveryListener? {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onServiceFound(service: NsdServiceInfo) = onFound(service)
            override fun onServiceLost(service: NsdServiceInfo) = onLost(service)
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        return try {
            nsdManager?.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            listener
        } catch (_: Exception) {
            null
        }
    }

    private fun stopDiscovery() {
        listOfNotNull(syncDiscoveryListener, tvDiscoveryListener).forEach {
            try { nsdManager?.stopServiceDiscovery(it) } catch (_: Exception) {}
        }
        syncDiscoveryListener = null
        tvDiscoveryListener = null
    }

    /**
     * NsdManager resolves one service at a time before Android 14 (`FAILURE_ALREADY_ACTIVE`): resolutions
     * are queued here and retried, or a device found at the same time as another would never be reached.
     */
    @Suppress("DEPRECATION")
    private suspend fun resolve(service: NsdServiceInfo): NsdServiceInfo? = resolveMutex.withLock {
        val manager = nsdManager ?: return@withLock null
        repeat(3) { attempt ->
            val outcome = withTimeoutOrNull(6_000) {
                suspendCancellableCoroutine<Pair<NsdServiceInfo?, Int>> { cont ->
                    val listener = object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                            if (cont.isActive) cont.resume(null to errorCode)
                        }
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            if (cont.isActive) cont.resume(info to 0)
                        }
                    }
                    try {
                        manager.resolveService(service, listener)
                    } catch (_: Exception) {
                        if (cont.isActive) cont.resume(null to -1)
                    }
                }
            }
            outcome?.first?.let { return@withLock it }
            if (outcome != null && outcome.second != NsdManager.FAILURE_ALREADY_ACTIVE) return@withLock null
            delay(500L * (attempt + 1))
        }
        null
    }

    private suspend fun resolveSyncPeer(service: NsdServiceInfo) {
        val info = resolve(service) ?: return
        val host = info.host?.hostAddress ?: return
        val name = info.serviceName
        peerEndpoints[name] = host to info.port
        if (connections[name]?.isAlive != true) {
            log("Appareil trouvé sur le réseau : $name.")
            connectToPeer(name, host, info.port)
        }
    }

    private suspend fun resolveTv(service: NsdServiceInfo) {
        if (!running || samsung.isConnected) return
        val info = resolve(service) ?: return
        // IPv4 only: a link-local IPv6 with its scope does not fit in a ws:// URL.
        val address = info.host as? Inet4Address ?: return
        address.hostAddress?.let { samsung.connectToTv(it) }
    }

    private fun connectToPeer(serviceName: String, host: String, port: Int) {
        if (!connecting.add(serviceName)) return
        scope.launch {
            try {
                val socket = Socket()
                socket.connect(InetSocketAddress(host, port), 5000)
                val connection = PeerConnection(
                    socket = socket,
                    input = DataInputStream(socket.getInputStream()),
                    output = DataOutputStream(socket.getOutputStream()),
                )
                connections[serviceName] = connection
                connecting.remove(serviceName)
                sendAnnounce(connection)
                readLoop(connection)
            } catch (_: Exception) {
                connections.remove(serviceName)?.close()
            } finally {
                connecting.remove(serviceName)
            }
        }
    }

    // MARK: - Reading

    private suspend fun readLoop(connection: PeerConnection) {
        try {
            while (scope.isActive && connection.isAlive) {
                val length = try { connection.input.readInt() } catch (_: Exception) { break }
                if (length <= 0 || length > MAX_PAYLOAD_SIZE) break
                val payload = ByteArray(length)
                try { connection.input.readFully(payload) } catch (_: Exception) { break }
                processIncomingPayload(payload, connection)
            }
        } finally {
            connectionClosed(connection)
        }
    }

    private suspend fun processIncomingPayload(payload: ByteArray, connection: PeerConnection) {
        val envelope = try {
            val obj = JSONObject(String(payload, Charsets.UTF_8))
            DomainHouseholdSealedEnvelope(
                householdId = obj.getString("household_id"),
                senderDeviceId = obj.getString("sender_device_id"),
                sequence = obj.getLong("sequence").toULong(),
                nonceHex = obj.getString("nonce_hex"),
                ciphertextHex = obj.getString("ciphertext_hex"),
            )
        } catch (_: Exception) {
            return
        }
        openAndHandle(envelope, connection, warnIfUnreadable = true)
    }

    private suspend fun processChannelEnvelope(envelope: DomainHouseholdSealedEnvelope) {
        // Our own messages come back from the relay.
        if (envelope.senderDeviceId == store.deviceId) return
        // Broadcasts of the NSD devices also come through the relay: the copy fails the replay check, quietly.
        openAndHandle(envelope, connection = null, warnIfUnreadable = false)
    }

    private suspend fun openAndHandle(
        envelope: DomainHouseholdSealedEnvelope,
        connection: PeerConnection?,
        warnIfUnreadable: Boolean,
    ) {
        val keyHex = store.currentHouseholdKeyHex() ?: return
        if (envelope.householdId != store.householdId.value) return
        val messageJson = try {
            syncRepo.openEnvelope(keyHex, envelope, store.lastSeenSequence(envelope.senderDeviceId))
        } catch (_: Exception) {
            if (warnIfUnreadable) {
                log("Message reçu illisible : l'autre appareil a peut-être une autre clé de foyer.", isWarning = true)
            }
            return
        }
        if (!store.verifyAndAdvanceSequence(envelope.senderDeviceId, envelope.sequence)) return
        try {
            handleDecryptedMessageJson(messageJson, envelope.senderDeviceId, connection)
        } catch (_: Exception) {
            // Malformed message: ignored, like on Apple.
        }
    }

    private fun connectionClosed(connection: PeerConnection) {
        connection.close()
        announcedConnections.remove(connection)
        incomingConnections.remove(connection)

        val deviceId = connectionDeviceIds.remove(connection)
        if (deviceId != null && deviceConnections[deviceId] == connection) {
            val live = reachableConnections().firstOrNull { connectionDeviceIds[it] == deviceId }
            if (live != null) {
                deviceConnections[deviceId] = live
            } else {
                deviceConnections.remove(deviceId)
                log("${peerName(deviceId)} n'est plus joignable.")
            }
        }
        connections.entries.removeIf { it.value == connection }
        refreshActivePeers()
    }

    // MARK: - Messages

    private suspend fun handleDecryptedMessageJson(json: String, senderDeviceId: String, connection: PeerConnection?) {
        if (connection != null) {
            deviceConnections[senderDeviceId] = connection
            connectionDeviceIds[connection] = senderDeviceId
        }
        val root = try { JSONObject(json) } catch (_: Exception) { return }

        if (connection != null) {
            deviceConnections[senderDeviceId] = connection
        } else {
            samsung.markTv(senderDeviceId)
        }

        when (root.optString("type")) {
            "device_announce" -> handleAnnounce(root, senderDeviceId, connection)

            "household_data_delta" -> {
                val deltaObj = root.optJSONObject("delta") ?: return
                val sender = peerName(senderDeviceId)
                if (engineBridge.importHouseholdDelta(deltaObj.toString())) {
                    log("Données du foyer reçues de $sender et appliquées.")
                    _syncStatus.value = "Données synchronisées avec $sender"
                } else {
                    log("Données reçues de $sender mais non appliquées.", isWarning = true)
                }
            }

            "sync_request" -> {
                log("${peerName(senderDeviceId)} demande les données du foyer.")
                sendFullSync(senderDeviceId)
            }

            "play_request" -> if (root.optString("target_device_id") == store.deviceId) {
                handlePlayRequest(root, senderDeviceId)
            }

            "play_ready" -> pendingHandoffs[root.optString("request_id")]?.readyDeferred?.complete(Unit)

            "play_refused" -> {
                val handoff = pendingHandoffs[root.optString("request_id")] ?: return
                _activeHandoffStatus.value = "Refusé : ${refusalText(root.optString("reason"))}"
                handoff.readyDeferred.cancel()
            }

            "play_go" -> handlePlayGo(root, senderDeviceId)

            "playback_state" -> {
                val session = _activeRemoteSession.value ?: return
                if (session.targetPeerId != senderDeviceId) return
                _activeRemoteSession.value = session.copy(
                    state = root.optString("state", session.state),
                    positionMs = root.optLong("position_ms", session.positionMs),
                    durationMs = root.optLong("duration_ms", session.durationMs),
                    lastUpdate = System.currentTimeMillis(),
                )
            }

            "playback_control" -> if (root.optString("target_device_id") == store.deviceId) {
                // Remote control of this player (PRD-42 § 4) is not wired on Android yet.
                log("Commande « ${root.optString("action")} » reçue de ${peerName(senderDeviceId)} : non prise en charge sur Android.")
            }

            "release_stream" -> {
                val sourceKey = root.optString("source_key").trim()
                val mine = currentLocalSourceKey
                if (sourceKey.isNotEmpty() && mine != null && sourceKey.equals(mine.trim(), ignoreCase = true)) {
                    log("Lecture arrêtée : un autre appareil du foyer utilise ce compte.")
                    _streamInterruptedByPeer.emit(sourceKey)
                }
            }

            "ping" -> sendToPeer(senderDeviceId, JSONObject().put("type", "pong").toString())
        }
    }

    private suspend fun handleAnnounce(root: JSONObject, senderDeviceId: String, connection: PeerConnection?) {
        // Answer once per connection (once per device on the channel, which broadcasts), so the sender sees
        // this device too; the announces that follow are the 30 s heartbeats.
        if (connection != null) {
            if (announcedConnections.add(connection)) sendAnnounce(connection)
        } else if (channelAnsweredDevices.add(senderDeviceId)) {
            sendAnnounceOnChannel()
        }

        val name = root.optString("device_name", "Appareil")
        val devType = root.optString("device_type", "mobile")
        // Reachable only through the Samsung channel: the TV (PRD-45), decided after decryption.
        val channelTv = connection == null && devType == "tv"
        if (channelTv) samsung.markTv(senderDeviceId)
        peerPresence[senderDeviceId] = PeerPresence(
            state = root.optString("state", "idle"),
            canPlay = root.optBoolean("can_play", true),
        )

        val previous = store.knownDevices.value.firstOrNull { it.id == senderDeviceId }
        val wasOnline = _activePeers.value.any { it.id == senderDeviceId && it.state != "offline" }
        val isNewOrBack = previous == null || !wasOnline ||
            System.currentTimeMillis() - previous.lastSeen > OFFLINE_THRESHOLD_MS
        store.rememberDevice(senderDeviceId, name, devType, System.currentTimeMillis())
        refreshActivePeers()

        if (previous == null || !wasOnline) log("$name est connecté.")
        if (isNewOrBack) sendFullSync(senderDeviceId)
    }

    /**
     * Target side of PRD-42 § 3.2, household trust (PRD-44 § 1.1): a running playback is replaced without
     * asking. Same order of checks as `cnd-domain::remote::handoff::evaluate_request`. Android has no
     * "Qui peut lancer ici ?" setting nor Kids check here yet: policy `Open`.
     */
    private suspend fun handlePlayRequest(root: JSONObject, senderDeviceId: String) {
        val requestId = root.optString("request_id").takeIf { it.isNotEmpty() } ?: return
        val now = System.currentTimeMillis()

        val last = lastRequestAt[senderDeviceId] ?: 0L
        if (now - last < MIN_REQUEST_INTERVAL_MS) return refuse(senderDeviceId, requestId, "rate_limited")
        lastRequestAt[senderDeviceId] = now

        val contentKey = root.optString("content_key")
        val sourceKey = root.optString("source_key").takeIf { it.isNotEmpty() }
        val itemId = if (contentKey.isEmpty()) null else engineBridge.resolveItemByContentKey(
            contentKey = contentKey,
            sourceKey = sourceKey,
            providerRef = root.optString("provider_ref").takeIf { it.isNotEmpty() },
            itemKind = root.optString("item_kind").takeIf { it.isNotEmpty() },
        )
        if (itemId == null) {
            log("Lecture demandée par ${peerName(senderDeviceId)} refusée : contenu introuvable sur cet appareil.", isWarning = true)
            return refuse(senderDeviceId, requestId, "unknown_content")
        }

        // Another handoff waits for its play_go: do not steal it (the first origin would stop for nothing).
        pendingReservations.values.removeIf { now - it.createdAt > RESERVATION_TTL_MS }
        if (pendingReservations.values.any { it.requestId != requestId }) {
            return refuse(senderDeviceId, requestId, "busy")
        }

        pendingReservations[requestId] = PendingReservation(
            requestId = requestId,
            senderId = senderDeviceId,
            itemId = itemId,
            title = root.optString("title").takeIf { it.isNotEmpty() },
            positionMs = root.optLong("position_ms", 0L),
            sourceKey = sourceKey,
        )
        sendToPeer(senderDeviceId, JSONObject().put("type", "play_ready").put("request_id", requestId).toString())
    }

    private suspend fun handlePlayGo(root: JSONObject, senderDeviceId: String) {
        val reservation = pendingReservations.remove(root.optString("request_id")) ?: return
        if (reservation.senderId != senderDeviceId) return
        if (System.currentTimeMillis() - reservation.createdAt > RESERVATION_TTL_MS) return // the origin gave up

        // Everybody else stops streaming THIS account (PRD-42 § 3.4) before this device opens it.
        val sourceKey = reservation.sourceKey ?: engineBridge.sourceKeyForItem(reservation.itemId)
        if (!sourceKey.isNullOrEmpty()) {
            broadcastMessage(JSONObject().put("type", "release_stream").put("source_key", sourceKey).toString())
        }
        val positionMs = root.optLong("position_ms", 0L)
        _incomingPlayInstructions.emit(
            IncomingPlayInstruction(
                itemId = reservation.itemId,
                title = reservation.title,
                positionMs = if (positionMs > 0) positionMs else reservation.positionMs,
                sourceKey = sourceKey,
            )
        )
        log("Lecture lancée depuis ${peerName(senderDeviceId)}.")
    }

    private suspend fun refuse(peerId: String, requestId: String, reason: String) {
        sendToPeer(
            peerId,
            JSONObject().put("type", "play_refused").put("request_id", requestId).put("reason", reason).toString(),
        )
    }

    /** `PlayRefuseReason` codes of `cnd-domain::sync::envelope`, shown to the user of the origin. */
    private fun refusalText(code: String): String = when (code) {
        "busy" -> "l'appareil traite déjà une autre demande"
        "unknown_content" -> "contenu introuvable sur l'appareil"
        "source_missing" -> "compte absent sur l'appareil"
        "kids_restricted" -> "interdit par le profil Enfants"
        "not_allowed" -> "l'appareil n'accepte pas les lectures à distance"
        "declined_by_user" -> "refusé sur l'appareil"
        "rate_limited" -> "trop de demandes, réessayez"
        "app_not_ready" -> "l'app démarre encore"
        else -> "refusé par l'appareil"
    }

    // MARK: - Sending

    private fun announceJson(): String = JSONObject().apply {
        put("type", "device_announce")
        put("device_id", store.deviceId)
        put("device_name", store.deviceName)
        put("device_type", store.deviceType)
        put("can_play", true)
        put("capabilities", JSONArray(listOf("play")))
        put("state", if (currentLocalContentKey != null) "playing" else "idle")
        put("app_version", "1.1.0")
    }.toString()

    private suspend fun sendAnnounce(connection: PeerConnection) {
        val sealed = sealMessage(announceJson()) ?: return
        announcedConnections.add(connection)
        sendEnvelope(sealed, connection)
    }

    private suspend fun sendAnnounceOnChannel() {
        if (!samsung.isConnected) return
        sealMessage(announceJson())?.let { samsung.sendEnvelope(it) }
    }

    /** The scanned address avoids waiting for Bonjour after the TV accepted the phone's household. */
    suspend fun sendDataToSamsung(host: String): Boolean = withContext(Dispatchers.IO) {
        lifecycleMutex.withLock {
            if (!running) { store.loadFromStore(); startLocked() }
        }
        val id = store.householdId.value ?: return@withContext false
        samsung.start(id)
        samsung.connectToTv(host)
        val connected = withTimeoutOrNull(15_000) {
            // Channel membership alone does not mean the TV app has joined yet. Wait for its
            // authenticated presence before transmitting accounts and other household data.
            while (!samsung.isConnected || samsung.currentHost != host ||
                store.knownDevices.value.none { it.deviceType == "tv" && samsung.isTv(it.id) }
            ) delay(100)
            true
        } ?: false
        if (!connected) return@withContext false
        val delta = engineBridge.exportHouseholdDelta(0L)
        if (delta.isEmpty()) return@withContext false
        val message = JSONObject().put("type", "household_data_delta").put("delta", JSONObject(delta)).toString()
        val sealed = sealMessage(message) ?: return@withContext false
        samsung.sendEnvelope(sealed)
    }

    /** "Envoyer mes données": everything this device has, to every connected device; nothing is asked back. */
    override suspend fun sendNow() = sendDelta(full = true, askBack = false)

    /** "Recevoir les données": a `sync_request` to every connected device; each one answers with its data. */
    override suspend fun receiveNow() {
        if (!store.isJoined.value) return
        val peers = reachableConnections()
        val hasSamsung = samsung.isConnected
        if (peers.isEmpty() && !hasSamsung) {
            _syncStatus.value = "Aucun autre appareil joignable : ouvrez Buntu sur l'autre appareil, sur le même Wi‑Fi."
            log("Recevoir : aucun autre appareil joignable (même Wi‑Fi ?).", isWarning = true)
            return
        }
        sealMessage(JSONObject().put("type", "sync_request").toString())?.let { sealed ->
            peers.forEach { sendEnvelope(sealed, it) }
            if (hasSamsung) samsung.sendEnvelope(sealed)
        }
        val totalTargets = peers.size + (if (hasSamsung) 1 else 0)
        log("Recevoir : données demandées à $totalTargets connexion(s).")
        _syncStatus.value = "Données demandées à $totalTargets connexion(s)…"
    }

    /** Restarts NSD discovery and sends a heartbeat to check which household devices are online. */
    override suspend fun refreshPeers() {
        lifecycleMutex.withLock {
            if (!store.isJoined.value) return
            if (!running) {
                store.loadFromStore()
                startLocked()
                return@withLock
            }
            log("Actualisation des appareils du foyer…")
            stopDiscovery()
            startDiscovery()
            store.householdId.value?.takeIf { it.isNotEmpty() }?.let { samsung.start(it) }
        }
        if (running) heartbeat()
    }

    /**
     * `full` sends everything ("Envoyer mes données"); `askBack` also asks the others for theirs.
     * The 60 s round only sends what changed (a `sync_request` every minute would make every device
     * resend all its data, passwords included, every minute).
     */
    private suspend fun sendDelta(full: Boolean, askBack: Boolean = false) {
        if (!store.isJoined.value) return
        val peers = reachableConnections()
        val hasSamsung = samsung.isConnected
        if (peers.isEmpty() && !hasSamsung) {
            if (full) {
                _syncStatus.value = "Aucun autre appareil joignable : ouvrez Buntu sur l'autre appareil, sur le même Wi‑Fi."
                log("Synchroniser : aucun autre appareil joignable (même Wi‑Fi ?).", isWarning = true)
            }
            return
        }
        val nowTs = System.currentTimeMillis() / 1000
        val deltaJson = engineBridge.exportHouseholdDelta(if (full) 0L else lastExportTimestamp)
        if (deltaJson.isNotEmpty()) {
            val wrapped = JSONObject().put("type", "household_data_delta").put("delta", JSONObject(deltaJson)).toString()
            sealMessage(wrapped)?.let { sealed ->
                peers.forEach { sendEnvelope(sealed, it) }
                if (hasSamsung) samsung.sendEnvelope(sealed)
            }
        }
        if (full) {
            if (askBack) {
                sealMessage(JSONObject().put("type", "sync_request").toString())?.let { sealed ->
                    peers.forEach { sendEnvelope(sealed, it) }
                    if (hasSamsung) samsung.sendEnvelope(sealed)
                }
            }
            val totalTargets = peers.size + (if (hasSamsung) 1 else 0)
            log("Envoyer : toutes les données envoyées à $totalTargets connexion(s).")
            _syncStatus.value = "Données envoyées à $totalTargets connexion(s)."
        } else {
            lastExportTimestamp = nowTs
        }
    }

    private fun sendFullSync(peerId: String) {
        if (!store.isJoined.value) return
        scope.launch {
            val deltaJson = engineBridge.exportHouseholdDelta(0L)
            if (deltaJson.isEmpty()) return@launch
            val wrapped = JSONObject().put("type", "household_data_delta").put("delta", JSONObject(deltaJson)).toString()
            if (sendToPeer(peerId, wrapped)) log("Envoi de toutes les données du foyer à ${peerName(peerId)}.")
        }
    }

    /**
     * One device only; `false` (nothing sent) when it is not reachable: a targeted order such as
     * `play_request` never falls back to a broadcast. The TV has no TCP connection: it gets the message
     * through its channel, which broadcasts, but the message carries `target_device_id`.
     */
    private suspend fun sendToPeer(peerId: String, messageJson: String): Boolean {
        val conn = (deviceConnections[peerId] ?: connections[peerId])?.takeIf { it.isAlive }
        if (conn == null && !samsung.isTv(peerId) && !samsung.isConnected) return false
        val sealed = sealMessage(messageJson) ?: return false
        return if (conn != null) {
            sendEnvelope(sealed, conn)
            true
        } else {
            samsung.sendEnvelope(sealed)
        }
    }

    private suspend fun broadcastMessage(messageJson: String) {
        val sealed = sealMessage(messageJson) ?: return
        reachableConnections().forEach { sendEnvelope(sealed, it) }
        samsung.sendEnvelope(sealed)
    }

    private fun sendEnvelope(envelope: DomainHouseholdSealedEnvelope, connection: PeerConnection) {
        scope.launch {
            try {
                connection.writeMutex.withLock {
                    val bytes = JSONObject().apply {
                        put("household_id", envelope.householdId)
                        put("sender_device_id", envelope.senderDeviceId)
                        put("sequence", envelope.sequence.toLong())
                        put("nonce_hex", envelope.nonceHex)
                        put("ciphertext_hex", envelope.ciphertextHex)
                    }.toString().toByteArray(Charsets.UTF_8)
                    connection.output.writeInt(bytes.size)
                    connection.output.write(bytes)
                    connection.output.flush()
                }
            } catch (_: Exception) {
                connectionClosed(connection)
            }
        }
    }

    private suspend fun sealMessage(messageJson: String): DomainHouseholdSealedEnvelope? {
        val keyHex = store.currentHouseholdKeyHex() ?: return null
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        return try {
            syncRepo.sealEnvelope(
                householdKeyHex = keyHex,
                senderDeviceId = store.deviceId,
                sequence = store.nextSequence(),
                nonceBytes = nonce,
                messageJson = messageJson,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun reachableConnections(): List<PeerConnection> {
        val seen = mutableSetOf<Socket>()
        return (connections.values + deviceConnections.values + incomingConnections.keys)
            .filter { it.isAlive && seen.add(it.socket) }
    }

    // MARK: - Heartbeat

    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatJob = scope.launch {
            var ticks = 0
            delay(5_000)
            while (isActive) {
                heartbeat()
                // The data itself goes every 60 s (first tick, then every other one), like on Apple.
                if (ticks % 2 == 0) sendDelta(full = false)
                ticks++
                delay(HEARTBEAT_MS)
            }
        }
    }

    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    private suspend fun heartbeat() {
        if (!running || !store.isJoined.value) return
        reachableConnections().forEach { sendAnnounce(it) }
        sendAnnounceOnChannel()
        for ((serviceName, endpoint) in peerEndpoints) {
            if (connections[serviceName]?.isAlive != true) connectToPeer(serviceName, endpoint.first, endpoint.second)
        }
        // Expired reservations: the origin gave up.
        val now = System.currentTimeMillis()
        pendingReservations.values.removeIf { now - it.createdAt > RESERVATION_TTL_MS }
        pruneDeadConnections()
        refreshActivePeers()
    }

    private fun pruneDeadConnections() {
        connections.entries.removeIf { !it.value.isAlive }
        deviceConnections.entries.removeIf { !it.value.isAlive }
        incomingConnections.keys.removeIf { !it.isAlive }
        announcedConnections.removeIf { !it.isAlive }
        connectionDeviceIds.keys.removeIf { !it.isAlive }
    }

    /** "Disponible" = a live route (TCP or the TV channel) and news in the last 120 s. */
    private fun refreshActivePeers() {
        val now = System.currentTimeMillis()
        val connected = deviceConnections.filterValues { it.isAlive }.keys
        _activePeers.value = store.knownDevices.value.map { known ->
            val reachable = connected.contains(known.id) || samsung.isTv(known.id)
            val online = reachable && now - known.lastSeen <= OFFLINE_THRESHOLD_MS
            val presence = peerPresence[known.id]
            DiscoveredPeer(
                id = known.id,
                name = known.name,
                deviceType = known.deviceType,
                canPlay = presence?.canPlay ?: true,
                state = if (online) presence?.state ?: "idle" else "offline",
                lastSeen = known.lastSeen,
            )
        }
    }

    private fun peerName(deviceId: String): String =
        store.knownDevices.value.firstOrNull { it.id == deviceId }?.name ?: "l'appareil ${deviceId.takeLast(6)}"

    private fun log(text: String, isWarning: Boolean = false) {
        _syncLog.value = (listOf(SyncLogEntry(message = text, isWarning = isWarning)) + _syncLog.value).take(100)
    }

    // MARK: - RemotePlaybackRepository (origin side)

    override suspend fun startHandoff(
        targetPeerId: String,
        contentKey: String,
        sourceKey: String?,
        itemKind: String,
        providerRef: String?,
        title: String?,
        positionMs: Long,
    ): Boolean {
        val reachable = (deviceConnections[targetPeerId] ?: connections[targetPeerId])?.isAlive == true ||
            samsung.isTv(targetPeerId)
        if (!reachable) {
            _activeHandoffStatus.value = "Appareil non joignable"
            return false
        }

        val targetName = peerName(targetPeerId)
        _activeHandoffStatus.value = "Connexion à $targetName…"

        // The target does not know this device's item hash (it depends on the local account id): it finds
        // the item by the provider's stream id in the account named by its key (PRD-42 § 6). Every caller
        // (player, details, catalog menus) gets them here, read from the local item.
        val local = if (providerRef == null || sourceKey == null) {
            runCatching {
                engineBridge.resolveItemByContentKey(contentKey, null, null, null)?.let { engineBridge.remoteItem(it) }
            }.getOrNull()
        } else {
            null
        }
        val wireSourceKey = sourceKey ?: local?.sourceKey
        val wireProviderRef = providerRef ?: local?.providerRef
        val containerExt = local?.containerExt

        val requestId = UUID.randomUUID().toString()
        val readyDeferred = CompletableDeferred<Unit>()
        pendingHandoffs[requestId] = PendingHandoff(requestId, targetPeerId, readyDeferred)

        val req = JSONObject().apply {
            put("type", "play_request")
            put("target_device_id", targetPeerId)
            put("request_id", requestId)
            put("content_key", contentKey)
            if (wireSourceKey != null) put("source_key", wireSourceKey)
            put("item_kind", itemKind)
            if (wireProviderRef != null) put("provider_ref", wireProviderRef)
            if (containerExt != null) put("container_ext", containerExt)
            if (title != null) put("title", title)
            put("position_ms", positionMs)
            put("replace", true)
        }.toString()

        if (!sendToPeer(targetPeerId, req)) {
            pendingHandoffs.remove(requestId)
            _activeHandoffStatus.value = "Échec de l'envoi de la demande"
            return false
        }

        val ready = withTimeoutOrNull(6_000) {
            try {
                readyDeferred.await()
                true
            } catch (_: Exception) {
                false
            }
        } ?: false
        pendingHandoffs.remove(requestId)

        if (!ready) {
            if (_activeHandoffStatus.value?.startsWith("Refusé") != true) {
                _activeHandoffStatus.value = "Délai dépassé : $targetName ne répond pas."
            }
            return false
        }

        sendToPeer(
            targetPeerId,
            JSONObject().put("type", "play_go").put("request_id", requestId).put("position_ms", positionMs).toString(),
        )
        log("Lecture transférée à $targetName.")
        _activeHandoffStatus.value = null
        _activeRemoteSession.value = ActiveRemoteControlSession(
            targetPeerId = targetPeerId,
            targetPeerName = targetName,
            contentKey = contentKey,
            title = title ?: "",
            state = "playing",
            positionMs = positionMs,
            durationMs = 0L,
        )
        return true
    }

    override suspend fun sourceKeyForItem(itemId: Long): String? = engineBridge.sourceKeyForItem(itemId)

    override fun clearHandoffStatus() {
        _activeHandoffStatus.value = null
    }

    override suspend fun startHandoffForItem(targetPeerId: String, itemId: Long): Boolean {
        val item = engineBridge.remoteItem(itemId)
        if (item == null) {
            _activeHandoffStatus.value = "Ce contenu ne peut pas être lu sur un autre appareil."
            return false
        }
        return startHandoff(
            targetPeerId = targetPeerId,
            contentKey = item.contentKey,
            sourceKey = item.sourceKey,
            itemKind = item.itemKind,
            providerRef = item.providerRef,
            title = item.title,
            positionMs = item.resumePositionMs,
        )
    }

    override suspend fun sendPlaybackControl(targetPeerId: String, action: String, value: Long?) {
        val ctrl = JSONObject().apply {
            put("type", "playback_control")
            put("target_device_id", targetPeerId)
            put("action", action)
            if (value != null) put("value", value)
        }.toString()
        sendToPeer(targetPeerId, ctrl)
    }

    override fun setLocalPlaybackActive(contentKey: String?, title: String?, sourceKey: String?) {
        currentLocalContentKey = contentKey
        currentLocalSourceKey = sourceKey
    }

    override fun onLocalPlaybackStopped() {
        currentLocalContentKey = null
        currentLocalSourceKey = null
    }

    // MARK: - HouseholdRepository

    override suspend fun createHousehold(): DomainHouseholdCredentials {
        val creds = store.createHousehold()
        withContext(Dispatchers.IO) { lifecycleMutex.withLock { stopLocked(); startLocked() } }
        return creds
    }

    override suspend fun joinHousehold(keyHex: String): String {
        val id = store.joinHousehold(keyHex)
        withContext(Dispatchers.IO) { lifecycleMutex.withLock { stopLocked(); startLocked() } }
        return id
    }

    override suspend fun leaveHousehold() {
        withContext(Dispatchers.IO) { lifecycleMutex.withLock { stopLocked() } }
        store.leaveHousehold()
    }

    override suspend fun currentHouseholdKeyHex(): String? = store.currentHouseholdKeyHex()

    override suspend fun sendRemoteText(text: String, targetPeerId: String?) {
        withContext(Dispatchers.IO) {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) return@withContext
            val target = targetPeerId?.takeIf { it.isNotBlank() }
            val payload = JSONObject()
                .put("type", "remote_text")
                .put("text", trimmed)
                .apply {
                    if (target != null) {
                        put("target_device_id", target)
                    }
                }
                .toString()
            if (target != null) {
                sendToPeer(target, payload)
            } else {
                broadcastMessage(payload)
            }
        }
    }
}
