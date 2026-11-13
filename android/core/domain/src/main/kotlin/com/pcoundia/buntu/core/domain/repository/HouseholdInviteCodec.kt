package com.pcoundia.buntu.core.domain.repository

/**
 * The QR code that adds a device to the household (PRD-41, PRD-44): `buntu://household?key=…`.
 * The format is decided in Rust (`cnd_domain::sync::invite`), shared with the other platforms.
 *
 * The link holds the household key: never log it, never store it.
 */
interface HouseholdInviteCodec {
    /** Text of the QR code for [keyHex], or `null` when it is not a valid household key. */
    suspend fun inviteLink(keyHex: String): String?

    /** Household key read from a scanned or pasted code (link or bare key), `null` for any other code. */
    suspend fun keyFromScanned(text: String): String?
}
