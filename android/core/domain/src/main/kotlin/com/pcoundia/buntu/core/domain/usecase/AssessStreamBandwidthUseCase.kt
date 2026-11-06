package com.pcoundia.buntu.core.domain.usecase

import com.pcoundia.buntu.core.domain.model.BandwidthAssessment
import javax.inject.Inject

/**
 * Single responsibility (PRD-37 § 4.3):
 * Compare observed download speed (`measuredBitsPerSec`) against the media's required bitrate
 * (`fileSizeBytes * 8 / durationSeconds` with a 15 % safety margin) to warn the user before endless buffering.
 */
class AssessStreamBandwidthUseCase @Inject constructor() {
    operator fun invoke(
        measuredBitsPerSec: Long,
        fileSizeBytes: Long?,
        durationMs: Long?,
        hasLighterVersions: Boolean = false,
    ): BandwidthAssessment? {
        if (measuredBitsPerSec <= 0L) return null
        val size = fileSizeBytes?.takeIf { it > 0L } ?: return null
        val durationSecs = durationMs?.let { it / 1000L }?.takeIf { it >= 60L } ?: return null

        val nominalBitrate = (size * 8L) / durationSecs
        // Require 1.12x nominal bitrate to absorb VBR peaks without stalling.
        val requiredWithHeadroom = (nominalBitrate * 112L) / 100L
        val isInsufficient = measuredBitsPerSec < requiredWithHeadroom

        return BandwidthAssessment(
            isInsufficient = isInsufficient,
            measuredBitsPerSec = measuredBitsPerSec,
            requiredBitsPerSec = requiredWithHeadroom,
            hasLighterVersions = hasLighterVersions,
        )
    }
}

