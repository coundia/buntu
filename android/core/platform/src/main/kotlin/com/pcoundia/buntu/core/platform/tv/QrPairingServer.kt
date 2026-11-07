package com.pcoundia.buntu.core.platform.tv

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.pcoundia.buntu.core.domain.repository.PairingOpenOutcome
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

data class QrMatrix(
    val size: Int,
    val pixels: BooleanArray,
)

/** What the TV shows while it waits for a phone. */
data class PairingSession(
    val link: String,
    val qr: QrMatrix,
    val host: String,
    val port: Int,
    val expiresAtSeconds: Long,
)

/** A phone sent sources. The user must decide with the remote before anything is added. */
data class IncomingPairing(val shareJson: String, val from: String)

sealed interface PairingDecision {
    data class Added(val count: Int) : PairingDecision
    data object Refused : PairingDecision
    data object Failed : PairingDecision
}

enum class PairingClosedReason { Expired, Closed, Done }

/**
 * PRD-39 § 3, § 5.2: the Android TV receives accounts from a phone.
 *
 * It serves ONE endpoint, `POST /pair`, that accepts only messages sealed by the shared Rust protocol:
 * encrypted end to end with a key only the QR code carries, one message per session, three bad ones close
 * it. Nothing readable crosses the network, and nothing is added before [onIncoming] answers (the
 * confirmation on the TV screen). The old plain-text form is gone: a password never travels in clear.
 */
@Singleton
class QrPairingServer @Inject constructor(
    private val pairing: PairingRepository,
) {
    private val random = SecureRandom()
    private val lock = Mutex()
    private var serverSocket: ServerSocket? = null
    private var acceptJob: Job? = null
    private var expiryJob: Job? = null

    @Volatile private var state: String = ""
    @Volatile private var session: String = ""

    fun encodeQrMatrix(content: String, sizePx: Int = 256): QrMatrix {
        val hints = mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 4)
        val bitMatrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
        val w = bitMatrix.width
        val h = bitMatrix.height
        val out = BooleanArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                out[y * w + x] = bitMatrix.get(x, y)
            }
        }
        return QrMatrix(size = w, pixels = out)
    }

    /**
     * Starts a session and returns what to display, or null when the TV has no network address.
     * [onIncoming] suspends until the user decided; [onClosed] tells the screen to show a new code.
     */
    fun start(
        scope: CoroutineScope,
        nowSeconds: () -> Long = { System.currentTimeMillis() / 1000 },
        tvName: String = "Android TV",
        onIncoming: suspend (IncomingPairing) -> PairingDecision,
        onClosed: (PairingClosedReason) -> Unit,
    ): PairingSession? {
        stop()
        val lanIp = findLanIpv4Address() ?: return null
        val socket = runCatching { ServerSocket(0) }.getOrNull() ?: return null
        serverSocket = socket

        val entropy = ByteArray(OFFER_ENTROPY).also(random::nextBytes)
        val offer = runCatching {
            pairing.createOffer(entropy, tvName, "http", lanIp, socket.localPort, nowSeconds())
        }.getOrElse {
            runCatching { socket.close() }
            serverSocket = null
            return null
        }
        state = offer.state
        session = offer.session

        expiryJob = scope.launch(Dispatchers.Default) {
            delay(((offer.expiresAt - nowSeconds()) * 1000).coerceAtLeast(0))
            if (isActive) finish(onClosed, PairingClosedReason.Expired)
        }
        acceptJob = scope.launch(Dispatchers.IO) {
            while (isActive && !socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                launch(Dispatchers.IO) {
                    runCatching { client.use { handle(it, nowSeconds, onIncoming, onClosed) } }
                }
            }
        }
        return PairingSession(
            link = offer.link,
            qr = encodeQrMatrix(offer.link),
            host = lanIp,
            port = socket.localPort,
            expiresAtSeconds = offer.expiresAt,
        )
    }

    fun stop() {
        acceptJob?.cancel()
        acceptJob = null
        expiryJob?.cancel()
        expiryJob = null
        runCatching { serverSocket?.close() }
        serverSocket = null
        state = ""
    }

    private fun finish(onClosed: (PairingClosedReason) -> Unit, reason: PairingClosedReason) {
        stop()
        onClosed(reason)
    }

    private suspend fun handle(
        sock: Socket,
        nowSeconds: () -> Long,
        onIncoming: suspend (IncomingPairing) -> PairingDecision,
        onClosed: (PairingClosedReason) -> Unit,
    ) {
        sock.soTimeout = READ_TIMEOUT_MS
        val input = BufferedInputStream(sock.getInputStream())
        val out = sock.getOutputStream()
        val request = readRequest(input) ?: return respond(out, 400, "text/plain", "Bad request")

        if (!request.method.equals("POST", ignoreCase = true) || request.path != "/pair") {
            // A browser that scanned the QR code without the app gets a pointer to the app, never a form.
            return respond(out, 200, "text/html; charset=utf-8", INFO_PAGE)
        }
        val message = request.body ?: return respond(out, 413, "text/plain", "Too large")

        // One message at a time: the session state moves with every call.
        val outcome = lock.withLock {
            val result = pairing.open(state, message, nowSeconds())
            when (result) {
                is PairingOpenOutcome.Opened -> state = result.state
                is PairingOpenOutcome.Rejected -> state = result.state
            }
            result
        }
        when (outcome) {
            is PairingOpenOutcome.Rejected -> {
                // The reason is not given: it would tell an intruder what to adjust.
                respond(out, 400, "application/json", "{\"error\":\"refused\"}")
                if (outcome.closed) finish(onClosed, PairingClosedReason.Closed)
            }
            is PairingOpenOutcome.Opened -> {
                sock.soTimeout = 0 // the user takes the time they need (the session itself expires)
                val decision = runCatching { onIncoming(IncomingPairing(outcome.shareJson, outcome.from)) }
                    .getOrDefault(PairingDecision.Failed)
                val (result, count) = when (decision) {
                    is PairingDecision.Added -> "added" to decision.count
                    PairingDecision.Refused -> "refused" to 0
                    PairingDecision.Failed -> "error" to 0
                }
                val reply = pairing.sealReply(
                    outcome.replyKey, session, ByteArray(REPLY_ENTROPY).also(random::nextBytes), result, count,
                )
                respond(out, 200, "application/json", reply)
                finish(onClosed, PairingClosedReason.Done)
            }
        }
    }

    private data class Request(val method: String, val path: String, val body: String?)

    /** A small, strict HTTP/1.1 reader: bounded headers and body, no chunked bodies. */
    private fun readRequest(input: BufferedInputStream): Request? {
        fun readLine(): String? {
            val sb = StringBuilder()
            while (sb.length < MAX_LINE) {
                val b = input.read()
                if (b < 0) return null
                if (b == '\n'.code) return sb.toString().trimEnd('\r')
                sb.append(b.toChar())
            }
            return null
        }
        val first = readLine()?.split(' ') ?: return null
        if (first.size < 2) return null
        var contentLength = 0
        var headers = 0
        while (true) {
            val line = readLine() ?: return null
            if (line.isEmpty()) break
            if (++headers > MAX_HEADERS) return null
            if (line.startsWith("Content-Length:", ignoreCase = true)) {
                contentLength = line.substringAfter(':').trim().toIntOrNull() ?: return null
            }
        }
        if (contentLength !in 0..MAX_BODY) return Request(first[0], first[1].substringBefore('?'), null)
        val body = ByteArray(contentLength)
        var read = 0
        while (read < contentLength) {
            val n = input.read(body, read, contentLength - read)
            if (n <= 0) return null
            read += n
        }
        return Request(first[0], first[1].substringBefore('?'), String(body, Charsets.UTF_8))
    }

    private fun respond(out: OutputStream, status: Int, contentType: String, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val reason = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            413 -> "Payload Too Large"
            else -> "Error"
        }
        val head = "HTTP/1.1 $status $reason\r\nContent-Type: $contentType\r\nContent-Length: ${bytes.size}\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.UTF_8))
        out.write(bytes)
        out.flush()
    }

    private fun findLanIpv4Address(): String? = runCatching {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return@runCatching null
        data class Candidate(val host: String, val score: Int)
        val candidates = ArrayList<Candidate>()
        while (interfaces.hasMoreElements()) {
            val nif = interfaces.nextElement()
            if (!nif.isUp || nif.isLoopback || nif.isVirtual) continue
            val name = nif.name.orEmpty().lowercase()
            // Deprioritize cellular/VPN/tunnel interfaces so TV/device advertises its Wi-Fi / Ethernet LAN IP
            if (name.startsWith("tun") || name.startsWith("ppp") || name.startsWith("dummy")) continue
            val baseScore = when {
                name.startsWith("wlan") || name.startsWith("eth") || name.startsWith("en") -> 30
                name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("v4-") -> 1
                else -> 10
            }
            val addrs = nif.inetAddresses
            while (addrs.hasMoreElements()) {
                val addr = addrs.nextElement()
                if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                    val host = addr.hostAddress ?: continue
                    val score = baseScore + if (addr.isSiteLocalAddress) 20 else 0
                    candidates += Candidate(host, score)
                }
            }
        }
        candidates.maxByOrNull { it.score }?.host
    }.getOrNull()

    companion object {
        const val OFFER_ENTROPY = 40
        const val REPLY_ENTROPY = 12
        private const val READ_TIMEOUT_MS = 10_000
        private const val MAX_LINE = 8 * 1024
        private const val MAX_HEADERS = 40
        private const val MAX_BODY = 128 * 1024

        private const val INFO_PAGE = """
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Buntu TV</title>
<style>body{background:#0B0E14;color:#F5F7FA;font-family:system-ui,sans-serif;padding:24px;max-width:440px;margin:0 auto}h1{color:#FF9F0A;font-size:1.3rem}</style>
</head><body><h1>Ajouter vos comptes à la TV</h1>
<p>Ouvrez l'application <strong>Buntu</strong> sur ce téléphone et scannez de nouveau le QR code de la TV :
vos comptes lui sont envoyés chiffrés, sans qu'un mot de passe ne circule en clair.</p></body></html>
"""
    }
}
