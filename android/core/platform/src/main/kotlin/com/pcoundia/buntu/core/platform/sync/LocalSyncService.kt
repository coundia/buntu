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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Serverless local network continuity transport over NSD (_buntu-sync._tcp) + TCP.
 * Full parity with Apple LocalSyncService and RemotePlaybackCoordinator (PRD-41, PRD-42, PRD-44).
 * AES-256-GCM encrypted and authenticated using the shared 256-bit Household Key from [HouseholdStore].
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
        private const val HEARTBEAT_SECONDS = 30L
        private const val OFFLINE_THRESHOLD_MS = 120_000L
        private const val MAX_PAYLOAD_SIZE = 10_000_000
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

    private val scope = CoroutineScope(Dispatchers.IO + Job())
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null

    private var serverSocket: ServerSocket? = null
    private var serverJob: Job? = null
    private var heartbeatJob: Job? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // Persistent Connections
    private val connections = ConcurrentHashMap<String, PeerConnection>()
    private val deviceConnections = ConcurrentHashMap<String, PeerConnection>()
    private val incomingConnections = ConcurrentHashMap<PeerConnection, Boolean>()
    private val announcedConnections = ConcurrentHashMap.newKeySet<PeerConnection>()
    private val connectionDeviceIds = ConcurrentHashMap<PeerConnection, String>()
    private val peerEndpoints = ConcurrentHashMap<String, Pair<String, Int>>()

    // Handoff state
    private val pendingReservations = ConcurrentHashMap<String, PendingReservation>()
    private val pendingHandoffs = ConcurrentHashMap<String, PendingHandoff>()

    // Local playback state for single-stream enforcement
    @Volatile private var currentLocalContentKey: String? = null
    @Volatile private var currentLocalTitle: String? = null
    @Volatile private var currentLocalSourceKey: String? = null

    // Sequence & Export cursor
    private var lastExportTimestamp: Long = 0L

    // HouseholdRepository properties
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

    // RemotePlaybackRepository properties
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

    private val ownUniqueSuffix: String
        get() = store.deviceId.substringAfter("_").take(8)

    private val ownServiceName: String
        get() = "${store.deviceName} ($ownUniqueSuffix)"

    // MARK: - Lifecycle

    override fun startSyncService() {
        start()
    }

    override fun stopSyncService() {
        stop()
    }

    fun start() {
        if (!store.isJoined.value) {
            _syncStatus.value = "Aucun foyer configuré"
            return
        }

        log("Recherche des appareils du foyer sur le réseau local…")
        acquireMulticastLock()
        startServer()
        startDiscovery()
        val hId = store.householdId.value
        startHeartbeat()
        _syncStatus.value = "Synchronisation active"
    }

    fun stop() {
        stopHeartbeat()
        stopDiscovery()
        stopServer()
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

        _activePeers.value = emptyList()
        _syncStatus.value = "Arrêté"
    }

    fun ensureRunning() {
        if (!store.isJoined.value) return
        if (serverSocket == null || serverSocket?.isClosed == true) {
            stopServer()
            startServer()
        }
        if (discoveryListener == null) {
            startDiscovery()
        }
        heartbeat()
    }

    private fun acquireMulticastLock() {
        try {
            if (multicastLock == null) {
                multicastLock = wifiManager?.createMulticastLock("buntu_sync_multicast")?.apply {
                    setReferenceCounted(true)
                    acquire()
                }
            }
        } catch (_: Exception) {}
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let {
                if (it.isHeld) it.release()
            }
            multicastLock = null
        } catch (_: Exception) {}
    }

    // MARK: - TCP Server & NSD Registration

    private fun startServer() {
        if (serverSocket != null) return

        try {
            val server = ServerSocket(0)
            serverSocket = server
            val localPort = server.localPort

            registerNsdService(localPort)

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
        } catch (e: Exception) {
            _syncStatus.value = "Erreur démarrage serveur: ${e.message}"
        }
    }

    private fun stopServer() {
        unregisterNsdService()
        serverJob?.cancel()
        serverJob = null
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null
    }

    private fun registerNsdService(port: Int) {
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = ownServiceName
            serviceType = SERVICE_TYPE
            this.port = port
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                _syncStatus.value = "Synchronisation active"
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                _syncStatus.value = "Échec enregistrement NSD ($errorCode)"
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }

        try {
            nsdManager?.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (_: Exception) {}
    }

    private fun unregisterNsdService() {
        registrationListener?.let {
            try {
                nsdManager?.unregisterService(it)
            } catch (_: Exception) {}
        }
        registrationListener = null
    }

    // MARK: - NSD Discovery (Client)

    private fun startDiscovery() {
        if (discoveryListener != null) return

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}

            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceName == ownServiceName || service.serviceName.contains(ownUniqueSuffix)) return
                resolveService(service)
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                peerEndpoints.remove(service.serviceName)
                connections.remove(service.serviceName)?.close()
                refreshActivePeers()
            }

            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        try {
            nsdManager?.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (_: Exception) {}
    }

    private fun stopDiscovery() {
        discoveryListener?.let {
            try {
                nsdManager?.stopServiceDiscovery(it)
            } catch (_: Exception) {}
        }
        discoveryListener = null
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val resolver = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
                val port = info.port
                val serviceName = info.serviceName
                peerEndpoints[serviceName] = Pair(host, port)

                if (connections[serviceName]?.isAlive != true) {
                    log("Appareil trouvé sur le réseau : $serviceName.")
                    connectToPeer(serviceName, host, port)
                }
            }
        }

        try {
            nsdManager?.resolveService(serviceInfo, resolver)
        } catch (_: Exception) {}
    }

    private fun connectToPeer(serviceName: String, host: String, port: Int) {
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

                sendAnnounce(connection)
                readLoop(connection)
            } catch (_: Exception) {
                connections.remove(serviceName)?.close()
            }
        }
    }

    // MARK: - Wire Loop & Routing

    private suspend fun readLoop(connection: PeerConnection) {
        try {
            while (scope.isActive && connection.isAlive) {
                val length = try {
                    connection.input.readInt()
                } catch (_: Exception) {
                    break
                }
                if (length <= 0 || length > MAX_PAYLOAD_SIZE) break

                val payload = ByteArray(length)
                try {
                    connection.input.readFully(payload)
                } catch (_: Exception) {
                    break
                }

                processIncomingPayload(payload, connection)
            }
        } finally {
            connectionClosed(connection)
        }
    }

    private suspend fun processIncomingPayload(payload: ByteArray, connection: PeerConnection) {
        val keyHex = store.currentHouseholdKeyHex() ?: return

        try {
            val envelopeObj = JSONObject(String(payload, Charsets.UTF_8))
            val envelope = DomainHouseholdSealedEnvelope(
                householdId = envelopeObj.getString("household_id"),
                senderDeviceId = envelopeObj.getString("sender_device_id"),
                sequence = envelopeObj.getLong("sequence").toULong(),
                nonceHex = envelopeObj.getString("nonce_hex"),
                ciphertextHex = envelopeObj.getString("ciphertext_hex"),
            )

            if (envelope.householdId != store.householdId.value) return

            val lastSeen = store.lastSeenSequence(envelope.senderDeviceId)
            val messageJson = try {
                syncRepo.openEnvelope(keyHex, envelope, lastSeen)
            } catch (e: Exception) {
                log("Message reçu illisible : l'autre appareil a peut-être une autre clé de foyer.", isWarning = true)
                return
            }

            if (!store.verifyAndAdvanceSequence(envelope.senderDeviceId, envelope.sequence)) {
                return
            }

            handleDecryptedMessageJson(messageJson, envelope.senderDeviceId, connection)
        } catch (_: Exception) {}
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
                val name = peerName(deviceId)
                log("$name n'est plus joignable.")
            }
        }

        connections.entries.removeIf { it.value == connection }
        refreshActivePeers()
    }

    // MARK: - Message Handling

    private suspend fun handleDecryptedMessageJson(json: String, senderDeviceId: String, connection: PeerConnection?) {
        if (connection != null) {
            deviceConnections[senderDeviceId] = connection
            connectionDeviceIds[connection] = senderDeviceId
        }

        val root = try {
            JSONObject(json)
        } catch (_: Exception) {
            return
        }

        when (val type = root.optString("type")) {
            "device_announce" -> {
                if (connection != null && announcedConnections.add(connection)) {
                    sendAnnounce(connection)
                }

                val name = root.optString("device_name", "Appareil")
                val devType = root.optString("device_type", "mobile")
                val canPlay = root.optBoolean("can_play", true)
                val state = root.optString("state", "idle")
                val caps = mutableListOf<String>()
                root.optJSONArray("capabilities")?.let { arr ->
                    for (i in 0 until arr.length()) caps.add(arr.getString(i))
                }

                val previous = store.knownDevices.value.firstOrNull { it.id == senderDeviceId }
                val isNewOrBack = previous == null || (System.currentTimeMillis() - previous.lastSeen > OFFLINE_THRESHOLD_MS)

                store.rememberDevice(senderDeviceId, name, devType, System.currentTimeMillis())
                refreshActivePeers()

                if (previous == null) {
                    log("$name est connecté.")
                }

                if (isNewOrBack) {
                    sendFullSync(senderDeviceId)
                }
            }

            "household_data_delta" -> {
                val deltaObj = root.optJSONObject("delta") ?: return
                try {
                    val success = engineBridge.importHouseholdDelta(deltaObj.toString())
                    val sender = peerName(senderDeviceId)
                    if (success) {
                        log("Données du foyer reçues de $sender et appliquées.")
                        _syncStatus.value = "Données synchronisées avec $sender"
                    } else {
                        log("Données reçues de $sender mais non appliquées.", isWarning = true)
                    }
                } catch (e: Exception) {
                    log("Erreur application données du foyer: ${e.message}", isWarning = true)
                }
            }

            "sync_request" -> {
                log("${peerName(senderDeviceId)} demande les données du foyer.")
                sendFullSync(senderDeviceId)
            }

            "play_request" -> {
                val targetDeviceId = root.optString("target_device_id")
                if (targetDeviceId != store.deviceId) return

                val requestId = root.getString("request_id")
                val contentKey = root.getString("content_key")
                val sourceKey = root.optString("source_key").takeIf { it.isNotEmpty() }
                val itemKind = root.optString("item_kind").takeIf { it.isNotEmpty() }
                val providerRef = root.optString("provider_ref").takeIf { it.isNotEmpty() }
                val title = root.optString("title").takeIf { it.isNotEmpty() }
                val positionMs = root.optLong("position_ms", 0L)

                // Resolve item locally
                val itemId = engineBridge.resolveItemByContentKey(
                    contentKey = contentKey,
                    sourceKey = sourceKey,
                    providerRef = providerRef,
                    itemKind = itemKind,
                )

                if (itemId != null) {
                    // Zero-prompt replacement in household (PRD-44 § 1.1 & § 3.4)
                    pendingReservations[requestId] = PendingReservation(
                        requestId = requestId,
                        itemId = itemId,
                        title = title,
                        positionMs = positionMs,
                        sourceKey = sourceKey,
                    )
                    val readyMsg = JSONObject().apply {
                        put("type", "play_ready")
                        put("request_id", requestId)
                    }.toString()
                    sendToPeer(senderDeviceId, readyMsg)
                    log("Lecture demandée par ${peerName(senderDeviceId)} acceptée.")
                } else {
                    val refuseMsg = JSONObject().apply {
                        put("type", "play_refused")
                        put("request_id", requestId)
                        put("reason", "Contenu introuvable sur cet appareil")
                    }.toString()
                    sendToPeer(senderDeviceId, refuseMsg)
                    log("Lecture demandée par ${peerName(senderDeviceId)} refusée : contenu introuvable.", isWarning = true)
                }
            }

            "play_ready" -> {
                val requestId = root.getString("request_id")
                val handoff = pendingHandoffs[requestId]
                if (handoff != null) {
                    handoff.readyDeferred.complete(Unit)
                }
            }

            "play_refused" -> {
                val requestId = root.getString("request_id")
                val reason = root.optString("reason", "Refusé par la cible")
                val handoff = pendingHandoffs[requestId]
                if (handoff != null) {
                    _activeHandoffStatus.value = "Refusé : $reason"
                    handoff.readyDeferred.cancel()
                }
            }

            "play_go" -> {
                val requestId = root.getString("request_id")
                val positionMs = root.optLong("position_ms", 0L)
                val reservation = pendingReservations.remove(requestId)
                if (reservation != null) {
                    // Single-stream rule: release stream across the household
                    if (!reservation.sourceKey.isNullOrEmpty()) {
                        val releaseMsg = JSONObject().apply {
                            put("type", "release_stream")
                            put("source_key", reservation.sourceKey)
                        }.toString()
                        broadcastMessage(releaseMsg)
                    }

                    _incomingPlayInstructions.emit(
                        IncomingPlayInstruction(
                            itemId = reservation.itemId,
                            title = reservation.title,
                            positionMs = if (positionMs > 0) positionMs else reservation.positionMs,
                            sourceKey = reservation.sourceKey,
                        )
                    )
                    log("Lecture démarrée depuis ${peerName(senderDeviceId)}.")
                }
            }

            "playback_state" -> {
                val devId = root.optString("device_id")
                val session = _activeRemoteSession.value
                if (session != null && session.targetPeerId == devId) {
                    _activeRemoteSession.value = session.copy(
                        state = root.optString("state", session.state),
                        positionMs = root.optLong("position_ms", session.positionMs),
                        durationMs = root.optLong("duration_ms", session.durationMs),
                        lastUpdate = System.currentTimeMillis(),
                    )
                }
            }

            "playback_control" -> {
                val targetDeviceId = root.optString("target_device_id")
                if (targetDeviceId == store.deviceId) {
                    val action = root.optString("action")
                    val value = if (root.has("value")) root.getLong("value") else null
                    log("Commande reçue de ${peerName(senderDeviceId)} : $action")
                }
            }

            "release_stream" -> {
                val sourceKey = root.optString("source_key")
                if (sourceKey.isNotEmpty() && sourceKey == currentLocalSourceKey) {
                    log("Flux arrêté : un autre appareil du foyer utilise ce compte.")
                    _streamInterruptedByPeer.emit(sourceKey)
                }
            }

            "ping" -> {
                val pongJson = JSONObject().apply { put("type", "pong") }.toString()
                sendToPeer(senderDeviceId, pongJson)
            }
        }
    }

    // MARK: - Sending Messages & Deltas

    fun sendAnnounce(connection: PeerConnection) {
        val announce = JSONObject().apply {
            put("type", "device_announce")
            put("device_id", store.deviceId)
            put("device_name", store.deviceName)
            put("device_type", store.deviceType)
            put("can_play", true)
            put("capabilities", org.json.JSONArray(listOf("play", "remote_control")))
            put("state", if (currentLocalContentKey != null) "playing" else "idle")
            put("app_version", "1.1.0")
        }.toString()

        val sealed = sealMessage(announce) ?: return
        sendEnvelope(sealed, connection)
    }

    override suspend fun syncNow() {
        if (!store.isJoined.value) return
        val peers = reachableConnections()
        if (peers.isEmpty()) {
            _syncStatus.value = "Aucun autre appareil joignable"
            log("Synchroniser : aucun autre appareil joignable (même Wi‑Fi ?).", isWarning = true)
            return
        }

        val deltaJson = engineBridge.exportHouseholdDelta(lastExportTimestamp)
        if (deltaJson.isNotEmpty()) {
            val wrapped = JSONObject().apply {
                put("type", "household_data_delta")
                put("delta", JSONObject(deltaJson))
            }.toString()
            val sealed = sealMessage(wrapped)
            if (sealed != null) {
                for (c in peers) sendEnvelope(sealed, c)
            }
        }

        val req = JSONObject().apply { put("type", "sync_request") }.toString()
        val sealedReq = sealMessage(req)
        if (sealedReq != null) {
            for (c in peers) sendEnvelope(sealedReq, c)
            log("Synchroniser : données demandées à ${peers.size} connexion(s).")
        }

        lastExportTimestamp = System.currentTimeMillis() / 1000
        _syncStatus.value = "Synchronisation demandée à ${peers.size} connexion(s)…"
    }

    private fun sendFullSync(peerId: String) {
        if (!store.isJoined.value) return
        scope.launch {
            val deltaJson = engineBridge.exportHouseholdDelta(0L)
            if (deltaJson.isNotEmpty()) {
                val wrapped = JSONObject().apply {
                    put("type", "household_data_delta")
                    put("delta", JSONObject(deltaJson))
                }.toString()
                if (sendToPeer(peerId, wrapped)) {
                    log("Envoi de toutes les données du foyer à ${peerName(peerId)}.")
                }
            }
        }
    }

    private fun sendToPeer(peerId: String, messageJson: String): Boolean {
        val sealed = sealMessage(messageJson) ?: return false
        val conn = deviceConnections[peerId] ?: connections[peerId]
        return if (conn != null && conn.isAlive) {
            sendEnvelope(sealed, conn)
            true
        } else {
            false
        }
    }

    fun broadcastMessage(messageJson: String) {
        val sealed = sealMessage(messageJson) ?: return
        for (c in reachableConnections()) {
            sendEnvelope(sealed, c)
        }
    }

    private fun sendEnvelope(envelope: DomainHouseholdSealedEnvelope, connection: PeerConnection) {
        scope.launch {
            try {
                connection.writeMutex.withLock {
                    val envelopeObj = JSONObject().apply {
                        put("household_id", envelope.householdId)
                        put("sender_device_id", envelope.senderDeviceId)
                        put("sequence", envelope.sequence.toLong())
                        put("nonce_hex", envelope.nonceHex)
                        put("ciphertext_hex", envelope.ciphertextHex)
                    }
                    val bytes = envelopeObj.toString().toByteArray(Charsets.UTF_8)
                    connection.output.writeInt(bytes.size)
                    connection.output.write(bytes)
                    connection.output.flush()
                }
            } catch (_: Exception) {
                connectionClosed(connection)
            }
        }
    }

    private fun sealMessage(messageJson: String): DomainHouseholdSealedEnvelope? {
        val keyHex = kotlinx.coroutines.runBlocking { store.currentHouseholdKeyHex() } ?: return null
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)
        val seq = kotlinx.coroutines.runBlocking { store.nextSequence() }

        return try {
            syncRepo.sealEnvelope(
                householdKeyHex = keyHex,
                senderDeviceId = store.deviceId,
                sequence = seq,
                nonceBytes = nonce,
                messageJson = messageJson,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun reachableConnections(): List<PeerConnection> {
        val list = mutableListOf<PeerConnection>()
        val seen = mutableSetOf<Socket>()
        for (c in connections.values + deviceConnections.values + incomingConnections.keys) {
            if (c.isAlive && seen.add(c.socket)) {
                list.add(c)
            }
        }
        return list
    }

    // MARK: - Heartbeat & Pruning

    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatJob = scope.launch {
            var ticks = 0
            while (isActive) {
                delay(HEARTBEAT_SECONDS * 1000)
                heartbeat()
                ticks++
                if (ticks % 2 == 0) {
                    syncNow()
                }
            }
        }
    }

    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    private fun heartbeat() {
        if (!store.isJoined.value) return

        for (c in reachableConnections()) {
            sendAnnounce(c)
        }

        // Reconnect to discovered peers that dropped
        for ((serviceName, endpoint) in peerEndpoints) {
            if (connections[serviceName]?.isAlive != true) {
                connectToPeer(serviceName, endpoint.first, endpoint.second)
            }
        }

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

    private fun refreshActivePeers() {
        val now = System.currentTimeMillis()
        val connectedDeviceIds = deviceConnections.filter { it.value.isAlive }.keys

        val list = store.knownDevices.value.map { known ->
            val isOnline = connectedDeviceIds.contains(known.id) && (now - known.lastSeen <= OFFLINE_THRESHOLD_MS)
            DiscoveredPeer(
                id = known.id,
                name = known.name,
                deviceType = known.deviceType,
                canPlay = true,
                state = if (isOnline) "idle" else "offline",
                lastSeen = known.lastSeen,
            )
        }
        _activePeers.value = list
    }

    private fun peerName(deviceId: String): String {
        return store.knownDevices.value.firstOrNull { it.id == deviceId }?.name
            ?: "l'appareil ${deviceId.takeLast(6)}"
    }

    private fun log(text: String, isWarning: Boolean = false) {
        val entry = SyncLogEntry(message = text, isWarning = isWarning)
        val current = _syncLog.value.toMutableList()
        current.add(0, entry)
        if (current.size > 100) current.removeAt(current.size - 1)
        _syncLog.value = current
    }

    // MARK: - RemotePlaybackRepository Implementation

    override suspend fun startHandoff(
        targetPeerId: String,
        contentKey: String,
        sourceKey: String?,
        itemKind: String,
        providerRef: String?,
        title: String?,
        positionMs: Long,
    ): Boolean {
        val conn = deviceConnections[targetPeerId] ?: connections[targetPeerId]
        if (conn == null || !conn.isAlive) {
            _activeHandoffStatus.value = "Appareil non joignable"
            return false
        }

        val targetName = peerName(targetPeerId)
        _activeHandoffStatus.value = "Connexion à $targetName…"

        val requestId = UUID.randomUUID().toString()
        val readyDeferred = CompletableDeferred<Unit>()
        pendingHandoffs[requestId] = PendingHandoff(requestId, targetPeerId, readyDeferred)

        val req = JSONObject().apply {
            put("type", "play_request")
            put("target_device_id", targetPeerId)
            put("request_id", requestId)
            put("content_key", contentKey)
            if (sourceKey != null) put("source_key", sourceKey)
            put("item_kind", itemKind)
            if (providerRef != null) put("provider_ref", providerRef)
            if (title != null) put("title", title)
            put("position_ms", positionMs)
            put("replace", true)
        }.toString()

        if (!sendToPeer(targetPeerId, req)) {
            pendingHandoffs.remove(requestId)
            _activeHandoffStatus.value = "Échec envoi de la demande"
            return false
        }

        val ready = withTimeoutOrNull(6000) {
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

        // Send play_go
        val go = JSONObject().apply {
            put("type", "play_go")
            put("request_id", requestId)
            put("position_ms", positionMs)
        }.toString()

        sendToPeer(targetPeerId, go)
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
        currentLocalTitle = title
        currentLocalSourceKey = sourceKey
    }

    override fun onLocalPlaybackStopped() {
        currentLocalContentKey = null
        currentLocalTitle = null
        currentLocalSourceKey = null
    }

    // MARK: - HouseholdRepository methods

    override suspend fun createHousehold(): DomainHouseholdCredentials {
        val creds = store.createHousehold()
        start()
        return creds
    }

    override suspend fun joinHousehold(keyHex: String): String {
        val id = store.joinHousehold(keyHex)
        start()
        return id
    }

    override suspend fun leaveHousehold() {
        stop()
        store.leaveHousehold()
    }

    override suspend fun currentHouseholdKeyHex(): String? {
        return store.currentHouseholdKeyHex()
    }
}
