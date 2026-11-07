package com.pcoundia.buntu.core.domain.repository

/**
 * PRD-39: pairing a phone with a TV by QR code. The protocol (X25519 key agreement, HKDF, AES-GCM, one-use
 * sessions) is implemented ONCE, in Rust (`cnd-domain::pairing`), and shared with Swift and the Samsung TV's
 * WebAssembly. This is the Kotlin-facing contract; screens and the TV server never touch the bindings.
 *
 * `entropy` and `nowSeconds` come from the caller (SecureRandom and its clock): the protocol is pure.
 */
interface PairingRepository {
    /** TV side: a one-time offer (the link a QR code holds, and the private state the TV keeps). */
    fun createOffer(entropy: ByteArray, tvName: String, transport: String, host: String, port: Int, nowSeconds: Long): PairingOffer

    /** Phone side: validates a scanned link. Throws when it is malformed or expired. */
    fun parseLink(link: String, nowSeconds: Long): PairingLink

    /** Phone side: encrypts the sources document for the TV of that link. */
    fun seal(link: String, entropy: ByteArray, shareJson: String, phoneName: String, nowSeconds: Long): PairingSealed

    /** TV side: decrypts a message. Never throws: a bad message is an answer (`Rejected`). */
    fun open(state: String, message: String, nowSeconds: Long): PairingOpenOutcome

    /** TV side: tells the phone the outcome (`added`, `refused` or `error`). */
    fun sealReply(replyKey: String, session: String, entropy: ByteArray, result: String, count: Int): String

    /** Phone side: reads the TV's answer. */
    fun openReply(replyKey: String, session: String, reply: String): PairingReply
}

data class PairingOffer(val session: String, val link: String, val state: String, val expiresAt: Long)

data class PairingLink(
    val session: String,
    val tvName: String,
    /** `msf` (Samsung), `http` (Android TV) or `tls` (Apple TV). */
    val transport: String,
    val host: String,
    val port: Int,
    val expiresAt: Long,
)

data class PairingSealed(val message: String, val replyKey: String)

data class PairingReply(val result: String, val count: Int)

sealed interface PairingOpenOutcome {
    data class Opened(val shareJson: String, val from: String, val replyKey: String, val state: String) : PairingOpenOutcome

    /** `closed`: the session is over (expired, three errors, or already used): show a new QR code. */
    data class Rejected(val error: String, val state: String, val closed: Boolean) : PairingOpenOutcome
}
