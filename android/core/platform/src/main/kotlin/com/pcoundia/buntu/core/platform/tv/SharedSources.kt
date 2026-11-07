package com.pcoundia.buntu.core.platform.tv

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI

/** One account a phone sent (`cnd-source-share` document, PRD-26). */
data class SharedSource(
    val name: String,
    val isXtream: Boolean,
    val server: String?,
    val username: String?,
    val password: String?,
    val url: String?,
) {
    /** `host:port` of the server: what the confirmation shows, never a password or a full address. */
    val host: String
        get() = runCatching { URI(if (isXtream) server!! else url!!).authority }.getOrNull().orEmpty()
    val hasPassword: Boolean get() = isXtream && !password.isNullOrEmpty()
}

object SharedSources {
    const val MAX_SOURCES = 20

    /** Reads the document; throws [IllegalArgumentException] with a short message when it is not usable. */
    fun parse(json: String, nowSeconds: Long = System.currentTimeMillis() / 1000): List<SharedSource> {
        val doc = runCatching { Json.parseToJsonElement(json).jsonObject }.getOrNull()
            ?: throw IllegalArgumentException("Document de partage illisible")
        if (doc.str("format") != "cnd-source-share" || doc["version"]?.jsonPrimitive?.contentOrNull != "1") {
            throw IllegalArgumentException("Ce n'est pas un partage de sources Buntu")
        }
        doc["expires_at"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()?.let {
            if (it < nowSeconds) throw IllegalArgumentException("Ce partage a expiré")
        }
        val out = ArrayList<SharedSource>()
        for (element in doc["sources"]?.jsonArray.orEmpty().take(MAX_SOURCES)) {
            val o = element as? JsonObject ?: continue
            val xtream = when (o.str("type")) {
                "xtream" -> true
                "m3u" -> false
                else -> continue
            }
            val name = clean(o.str("name"), 80).ifEmpty { "Ma source" }
            if (xtream) {
                val server = clean(o.str("server"), 300)
                val user = clean(o.str("username"), 300)
                if (!isHttp(server) || user.isEmpty()) continue
                out += SharedSource(name, true, server, user, o.str("password")?.take(200)?.ifEmpty { null }, null)
            } else {
                val url = clean(o.str("url"), 2000)
                if (!isHttp(url)) continue
                out += SharedSource(name, false, null, null, null, url)
            }
        }
        if (out.isEmpty()) throw IllegalArgumentException("Aucun compte utilisable dans ce partage")
        return out
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun clean(v: String?, max: Int) = (v ?: "").filter { it.code >= 0x20 && it.code != 0x7f }.trim().take(max)
    private fun isHttp(v: String) = v.startsWith("http://", true) || v.startsWith("https://", true)
}
