package com.pcoundia.buntu.core.platform.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import com.pcoundia.buntu.core.domain.repository.DomainHouseholdSealedEnvelope
import com.pcoundia.buntu.core.domain.repository.HouseholdSyncRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

data class SyncPeer(
    val id: String,
    val name: String,
    val type: String,
    val host: String,
    val port: Int,
    val lastSeen: Long = System.currentTimeMillis(),
)

data class RemotePlayCommand(
    val contentKey: String,
    val positionMs: Long,
    val title: String?,
    val sourceKey: String?,
)

/**
 * Serverless local network continuity transport over mDNS/NSD (_buntu-sync._tcp) + TCP (PRD-41 Lot 41.4).
 * AES-256-GCM encrypted and authenticated using the shared 256-bit Household Key from [HouseholdStore].
 */
@Singleton
class LocalSyncService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val store: HouseholdStore,
    private val syncRepo: HouseholdSyncRepository,
) {
    companion object {
        const val SERVICE_TYPE = "_buntu-sync._tcp."
    }

    private val scope = CoroutineScope(Dispatchers.IO + Job())
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null

    private var serverSocket: ServerSocket? = null
    private var serverJob: Job? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    private val peers = ConcurrentHashMap<String, SyncPeer>()
    private val _activePeers = MutableStateFlow<List<SyncPeer>>(emptyList())
    val activePeers: StateFlow<List<SyncPeer>> = _activePeers.asStateFlow()

    private val _isListening = MutableStateFlow(false)
    val isListening: StateFlow<Boolean> = _isListening.asStateFlow()

    private val _isBrowsing = MutableStateFlow(false)
    val isBrowsing: StateFlow<Boolean> = _isBrowsing.asStateFlow()

    private val _syncStatus = MutableStateFlow("Prêt")
    val syncStatus: StateFlow<String> = _syncStatus.asStateFlow()

    private val _remotePlayCommands = MutableSharedFlow<RemotePlayCommand>(extraBufferCapacity = 16)
    val remotePlayCommands: SharedFlow<RemotePlayCommand> = _remotePlayCommands.asSharedFlow()

    fun start() {
        if (!store.isJoined.value) {
            _syncStatus.value = "Aucun foyer configuré"
            return
        }

        acquireMulticastLock()
        startServer()
        startDiscovery()
        _syncStatus.value = "Continuité active"
    }

    fun stop() {
        stopDiscovery()
        stopServer()
        releaseMulticastLock()
        peers.clear()
        _activePeers.value = emptyList()
        _syncStatus.value = "Arrêté"
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
            _isListening.value = true

            registerNsdService(localPort)

            serverJob = scope.launch {
                while (isActive) {
                    try {
                        val client = server.accept()
                        launch { handleIncomingSocket(client) }
                    } catch (_: Exception) {
                        break
                    }
                }
            }
        } catch (e: Exception) {
            _syncStatus.value = "Erreur démarrage serveur: ${e.message}"
            _isListening.value = false
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
        _isListening.value = false
    }

    private fun registerNsdService(port: Int) {
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "${store.deviceName} (${store.deviceId.take(6)})"
            serviceType = SERVICE_TYPE
            this.port = port
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                _syncStatus.value = "Enregistré sur le réseau local"
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

    private suspend fun handleIncomingSocket(socket: Socket) {
        socket.use { s ->
            val input = DataInputStream(s.getInputStream())
            val output = DataOutputStream(s.getOutputStream())

            while (scope.isActive && !s.isClosed) {
                val length = try {
                    input.readInt()
                } catch (_: Exception) {
                    break
                }
                if (length <= 0 || length > 10_000_000) break

                val payload = ByteArray(length)
                input.readFully(payload)

                val keyHex = store.currentHouseholdKeyHex() ?: break
                val envelopeJson = String(payload, Charsets.UTF_8)
                val envelopeObj = JSONObject(envelopeJson)

                val envelope = DomainHouseholdSealedEnvelope(
                    householdId = envelopeObj.getString("household_id"),
                    senderDeviceId = envelopeObj.getString("sender_device_id"),
                    sequence = envelopeObj.getLong("sequence").toULong(),
                    nonceHex = envelopeObj.getString("nonce_hex"),
                    ciphertextHex = envelopeObj.getString("ciphertext_hex"),
                )

                if (envelope.householdId != store.householdId.value) continue

                val lastSeen = store.lastSeenSequence(envelope.senderDeviceId)
                val messageJson = try {
                    syncRepo.openEnvelope(keyHex, envelope, lastSeen)
                } catch (_: Exception) {
                    continue
                }

                store.verifyAndAdvanceSequence(envelope.senderDeviceId, envelope.sequence)
                processDecryptedMessage(messageJson, envelope.senderDeviceId, output)
            }
        }
    }

    private suspend fun processDecryptedMessage(json: String, senderDeviceId: String, output: DataOutputStream) {
        try {
            val root = JSONObject(json)
            when (root.optString("type")) {
                "device_announce" -> {
                    val name = root.optString("device_name", "Appareil")
                    val devType = root.optString("device_type", "mobile")
                    val peer = SyncPeer(
                        id = senderDeviceId,
                        name = name,
                        type = devType,
                        host = "",
                        port = 0,
                    )
                    peers[senderDeviceId] = peer
                    _activePeers.value = peers.values.toList()
                }
                "play_remote" -> {
                    val cmd = RemotePlayCommand(
                        contentKey = root.getString("content_key"),
                        positionMs = root.getLong("position_ms"),
                        title = root.optString("title").takeIf { it.isNotEmpty() },
                        sourceKey = root.optString("source_key").takeIf { it.isNotEmpty() },
                    )
                    _remotePlayCommands.emit(cmd)
                }
                "ping" -> {
                    val pongJson = JSONObject().apply { put("type", "pong") }.toString()
                    val sealed = sealMessage(pongJson) ?: return
                    sendEnvelope(sealed, output)
                }
            }
        } catch (_: Exception) {}
    }

    // MARK: - NSD Discovery (Client)

    private fun startDiscovery() {
        if (discoveryListener != null) return

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                _isBrowsing.value = true
            }
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceName.contains(store.deviceId.take(6))) return
                resolveService(service)
            }
            override fun onServiceLost(service: NsdServiceInfo) {
                peers.remove(service.serviceName)
                _activePeers.value = peers.values.toList()
            }
            override fun onDiscoveryStopped(serviceType: String) {
                _isBrowsing.value = false
            }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                _isBrowsing.value = false
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                _isBrowsing.value = false
            }
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
        _isBrowsing.value = false
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val resolver = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
                val port = info.port
                val peer = SyncPeer(
                    id = info.serviceName,
                    name = info.serviceName,
                    type = "mobile",
                    host = host,
                    port = port,
                )
                peers[info.serviceName] = peer
                _activePeers.value = peers.values.toList()

                // Send Announce over TCP
                scope.launch {
                    sendAnnounceTo(host, port)
                }
            }
        }

        try {
            nsdManager?.resolveService(serviceInfo, resolver)
        } catch (_: Exception) {}
    }

    private suspend fun sendAnnounceTo(host: String, port: Int) {
        try {
            Socket(host, port).use { s ->
                val out = DataOutputStream(s.getOutputStream())
                val announceJson = JSONObject().apply {
                    put("type", "device_announce")
                    put("device_id", store.deviceId)
                    put("device_name", store.deviceName)
                    put("device_type", store.deviceType)
                    put("app_version", "1.1.0")
                }.toString()

                val sealed = sealMessage(announceJson) ?: return
                sendEnvelope(sealed, out)
            }
        } catch (_: Exception) {}
    }

    // MARK: - Sending Commands

    suspend fun playRemote(peer: SyncPeer, contentKey: String, positionMs: Long, title: String? = null, sourceKey: String? = null) {
        val dict = JSONObject().apply {
            put("type", "play_remote")
            put("content_key", contentKey)
            put("position_ms", positionMs)
            if (title != null) put("title", title)
            if (sourceKey != null) put("source_key", sourceKey)
        }
        sendMessageTo(peer.host, peer.port, dict.toString())
    }

    private suspend fun sendMessageTo(host: String, port: Int, messageJson: String) {
        val sealed = sealMessage(messageJson) ?: return
        try {
            Socket(host, port).use { s ->
                val out = DataOutputStream(s.getOutputStream())
                sendEnvelope(sealed, out)
            }
        } catch (_: Exception) {}
    }

    private suspend fun sealMessage(messageJson: String): DomainHouseholdSealedEnvelope? {
        val keyHex = store.currentHouseholdKeyHex() ?: return null
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)
        val seq = store.nextSequence()

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

    private fun sendEnvelope(envelope: DomainHouseholdSealedEnvelope, output: DataOutputStream) {
        val envelopeObj = JSONObject().apply {
            put("household_id", envelope.householdId)
            put("sender_device_id", envelope.senderDeviceId)
            put("sequence", envelope.sequence.toLong())
            put("nonce_hex", envelope.nonceHex)
            put("ciphertext_hex", envelope.ciphertextHex)
        }
        val bytes = envelopeObj.toString().toByteArray(Charsets.UTF_8)
        output.writeInt(bytes.size)
        output.write(bytes)
        output.flush()
    }
}
