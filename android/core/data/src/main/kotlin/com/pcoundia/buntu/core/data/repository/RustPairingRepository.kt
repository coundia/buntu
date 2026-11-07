package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.domain.repository.PairingLink
import com.pcoundia.buntu.core.domain.repository.PairingOffer
import com.pcoundia.buntu.core.domain.repository.PairingOpenOutcome
import com.pcoundia.buntu.core.domain.repository.PairingRepository
import com.pcoundia.buntu.core.domain.repository.PairingReply
import com.pcoundia.buntu.core.domain.repository.PairingSealed
import com.pcoundia.buntu.core.engine.ffi.pairingCreateOffer
import com.pcoundia.buntu.core.engine.ffi.pairingOpen
import com.pcoundia.buntu.core.engine.ffi.pairingOpenReply
import com.pcoundia.buntu.core.engine.ffi.pairingParseLink
import com.pcoundia.buntu.core.engine.ffi.pairingSeal
import com.pcoundia.buntu.core.engine.ffi.pairingSealReply
import javax.inject.Inject
import javax.inject.Singleton

/** The Rust pairing protocol (`cnd-domain::pairing`) behind the domain contract. Pure functions: no engine needed. */
@Singleton
class RustPairingRepository @Inject constructor() : PairingRepository {

    override fun createOffer(entropy: ByteArray, tvName: String, transport: String, host: String, port: Int, nowSeconds: Long): PairingOffer {
        val o = pairingCreateOffer(entropy, tvName, transport, host, port.toUShort(), nowSeconds)
        return PairingOffer(o.session, o.link, o.state, o.expiresAt)
    }

    override fun parseLink(link: String, nowSeconds: Long): PairingLink {
        val l = pairingParseLink(link, nowSeconds)
        return PairingLink(l.session, l.tvName, l.transport, l.host, l.port.toInt(), l.expiresAt)
    }

    override fun seal(link: String, entropy: ByteArray, shareJson: String, phoneName: String, nowSeconds: Long): PairingSealed {
        val s = pairingSeal(link, entropy, shareJson, phoneName, nowSeconds)
        return PairingSealed(s.message, s.replyKey)
    }

    override fun open(state: String, message: String, nowSeconds: Long): PairingOpenOutcome {
        val r = pairingOpen(state, message, nowSeconds)
        r.opened?.let { return PairingOpenOutcome.Opened(it.shareJson, it.from, it.replyKey, it.state) }
        val rej = r.rejected
        return if (rej != null) {
            PairingOpenOutcome.Rejected(rej.error, rej.state, rej.closed)
        } else {
            PairingOpenOutcome.Rejected("message invalide", state, closed = true)
        }
    }

    override fun sealReply(replyKey: String, session: String, entropy: ByteArray, result: String, count: Int): String =
        pairingSealReply(replyKey, session, entropy, result, count.coerceAtLeast(0).toUInt())

    override fun openReply(replyKey: String, session: String, reply: String): PairingReply {
        val r = pairingOpenReply(replyKey, session, reply)
        return PairingReply(r.result, r.count.toInt())
    }
}
