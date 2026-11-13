package com.pcoundia.buntu.core.platform.tv

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/** Encodes a QR code at its natural size: one cell per module, plus a quiet zone of [margin] modules. */
object QrCodeEncoder {
    fun encode(content: String, margin: Int = 2): QrMatrix {
        val hints = mapOf(
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.MARGIN to margin,
        )
        // Width and height 0: zxing returns one pixel per module, the smallest matrix to draw.
        val bits = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, hints)
        val size = bits.width
        val pixels = BooleanArray(size * size) { i -> bits.get(i % size, i / size) }
        return QrMatrix(size = size, pixels = pixels)
    }
}
