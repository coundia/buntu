package com.pcoundia.buntu.core.platform.tv

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.URLDecoder
import javax.inject.Inject
import javax.inject.Singleton

data class QrMatrix(
    val size: Int,
    val pixels: BooleanArray,
)

sealed interface PairedSourcePayload {
    data class M3u(val name: String, val url: String) : PairedSourcePayload
    data class Xtream(
        val name: String,
        val server: String,
        val username: String,
        val password: String,
    ) : PairedSourcePayload
    data class ShareJson(val json: String) : PairedSourcePayload
}

/**
 * PRD-37 § 5.3 & PRD-26:
 * Serves a tiny local web page on the Android TV's LAN IP and generates a QR code matrix
 * so the user scans the TV screen with their phone and submits Xtream / M3U / Share JSON
 * without typing URLs or passwords on a D-Pad remote!
 */
@Singleton
class QrPairingServer @Inject constructor() {

    private var serverSocket: ServerSocket? = null
    private var acceptJob: Job? = null

    fun encodeQrMatrix(content: String, sizePx: Int = 256): QrMatrix {
        val bitMatrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx)
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

    fun startPairingEndpoint(
        scope: CoroutineScope,
        onReceived: suspend (PairedSourcePayload) -> Unit,
    ): String? {
        stop()
        val lanIp = findLanIpv4Address() ?: return null
        val socket = runCatching { ServerSocket(0) }.getOrNull() ?: return null
        serverSocket = socket
        val url = "http://$lanIp:${socket.localPort}/pair"

        acceptJob = scope.launch(Dispatchers.IO) {
            while (isActive && !socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                launch(Dispatchers.IO) {
                    client.use { sock ->
                        val reader = BufferedReader(InputStreamReader(sock.getInputStream(), Charsets.UTF_8))
                        val requestLine = reader.readLine() ?: return@use
                        var contentLength = 0
                        while (true) {
                            val header = reader.readLine() ?: break
                            if (header.isEmpty()) break
                            if (header.startsWith("Content-Length:", ignoreCase = true)) {
                                contentLength = header.substringAfter(':').trim().toIntOrNull() ?: 0
                            }
                        }

                        if (requestLine.startsWith("POST", ignoreCase = true) && contentLength in 1..256_000) {
                            val buf = CharArray(contentLength)
                            var readTotal = 0
                            while (readTotal < contentLength) {
                                val r = reader.read(buf, readTotal, contentLength - readTotal)
                                if (r <= 0) break
                                readTotal += r
                            }
                            val body = String(buf, 0, readTotal)
                            parseFormOrJson(body)?.let { payload ->
                                onReceived(payload)
                            }
                            val okHtml = "<html><body style='background:#0B0E14;color:#F5F7FA;font-family:sans-serif;padding:24px'><h2>Source envoyee a votre TV Buntu !</h2><p>Vous pouvez refermer cette page.</p></body></html>"
                            writeHttpResponse(sock.getOutputStream(), 200, "text/html; charset=utf-8", okHtml)
                        } else {
                            writeHttpResponse(sock.getOutputStream(), 200, "text/html; charset=utf-8", PAIRING_FORM_HTML)
                        }
                    }
                }
            }
        }
        return url
    }

    fun stop() {
        acceptJob?.cancel()
        acceptJob = null
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    private fun parseFormOrJson(body: String): PairedSourcePayload? {
        val trimmed = body.trim()
        if (trimmed.startsWith("{")) {
            return PairedSourcePayload.ShareJson(trimmed)
        }
        val params = trimmed.split('&').mapNotNull { pair ->
            val idx = pair.indexOf('=')
            if (idx <= 0) null
            else URLDecoder.decode(pair.substring(0, idx), "UTF-8") to
                URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
        }.toMap()

        val mode = params["type"] ?: "xtream"
        val name = params["name"]?.trim().takeUnless { it.isNullOrEmpty() } ?: "Ma TV"
        return if (mode == "m3u") {
            val m3uUrl = params["url"]?.trim()?.takeIf(String::isNotEmpty) ?: return null
            PairedSourcePayload.M3u(name = name, url = m3uUrl)
        } else {
            val server = params["server"]?.trim()?.takeIf(String::isNotEmpty) ?: return null
            val username = params["username"]?.trim()?.takeIf(String::isNotEmpty) ?: return null
            val password = params["password"]?.takeIf(String::isNotEmpty) ?: return null
            PairedSourcePayload.Xtream(
                name = name,
                server = server,
                username = username,
                password = password,
            )
        }
    }

    private fun writeHttpResponse(
        out: java.io.OutputStream,
        status: Int,
        contentType: String,
        body: String,
    ) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val headers = "HTTP/1.1 $status OK\r\n" +
            "Content-Type: $contentType\r\n" +
            "Content-Length: ${bytes.size}\r\n" +
            "Connection: close\r\n\r\n"
        out.write(headers.toByteArray(Charsets.UTF_8))
        out.write(bytes)
        out.flush()
    }

    private fun findLanIpv4Address(): String? = runCatching {
        val interfaces = NetworkInterface.getNetworkInterfaces() ?: return@runCatching null
        while (interfaces.hasMoreElements()) {
            val nif = interfaces.nextElement()
            if (!nif.isUp || nif.isLoopback) continue
            val addrs = nif.inetAddresses
            while (addrs.hasMoreElements()) {
                val addr = addrs.nextElement()
                if (addr is Inet4Address && !addr.isLoopbackAddress) {
                    return@runCatching addr.hostAddress
                }
            }
        }
        null
    }.getOrNull()

    companion object {
        private const val PAIRING_FORM_HTML = """
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Buntu TV — Ajouter une source</title>
<style>
  body { background:#0B0E14; color:#F5F7FA; font-family:system-ui,sans-serif; padding:20px; max-width:440px; margin:0 auto; }
  h1 { color:#FF9F0A; font-size:1.3rem; }
  label { display:block; margin-top:12px; color:#8E95A5; font-size:0.9rem; }
  input, select { width:100%; box-sizing:border-box; padding:12px; margin-top:4px; border-radius:8px; border:1px solid #202737; background:#161B26; color:#F5F7FA; }
  button { width:100%; margin-top:20px; padding:14px; border:0; border-radius:10px; background:#FF9F0A; color:#0B0E14; font-weight:700; font-size:1rem; }
</style>
</head>
<body>
  <h1>Buntu TV · Ajouter une source</h1>
  <form method="POST" action="/pair">
    <label>Type de source</label>
    <select name="type">
      <option value="xtream">Xtream Codes</option>
      <option value="m3u">Lien M3U</option>
    </select>
    <label>Nom</label>
    <input name="name" placeholder="Salon TV" required/>
    <label>Serveur Xtream (ex: http://monfournisseur.xyz:8080)</label>
    <input name="server" placeholder="http://..."/>
    <label>Identifiant Xtream</label>
    <input name="username" autocomplete="off"/>
    <label>Mot de passe Xtream</label>
    <input name="password" type="password" autocomplete="off"/>
    <label>Ou URL de playlist M3U</label>
    <input name="url" placeholder="http://.../playlist.m3u"/>
    <button type="submit">Envoyer à la TV</button>
  </form>
</body>
</html>
"""
    }
}

