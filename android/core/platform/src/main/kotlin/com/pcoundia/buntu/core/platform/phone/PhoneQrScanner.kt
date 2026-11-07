package com.pcoundia.buntu.core.platform.phone

import android.content.Context
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.suspendCancellableCoroutine
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume

sealed interface PhoneQrScanResult {
    data class Scanned(val rawValue: String) : PhoneQrScanResult
    data object Cancelled : PhoneQrScanResult
    data class Unavailable(val message: String) : PhoneQrScanResult
}

/**
 * PRD-39 § 5.5: Google Play services code scanner (zero CAMERA permission required).
 * Falls back gracefully with [PhoneQrScanResult.Unavailable] on devices without Play services
 * so the UI can offer pasting/typing the `buntu://pair?...` link.
 */
@Singleton
class PhoneQrScanner @Inject constructor() {

    suspend fun scanQrCode(activityContext: Context): PhoneQrScanResult =
        suspendCancellableCoroutine { cont ->
            val options = GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build()
            val scanner = runCatching {
                GmsBarcodeScanning.getClient(activityContext, options)
            }.getOrElse { err ->
                if (cont.isActive) {
                    cont.resume(
                        PhoneQrScanResult.Unavailable(
                            err.localizedMessage ?: "Scanner Google Play Services indisponible sur cet appareil."
                        )
                    )
                }
                return@suspendCancellableCoroutine
            }

            scanner.startScan()
                .addOnSuccessListener { barcode ->
                    val raw = barcode.rawValue?.trim().orEmpty()
                    if (cont.isActive) {
                        if (raw.isNotEmpty()) {
                            cont.resume(PhoneQrScanResult.Scanned(raw))
                        } else {
                            cont.resume(PhoneQrScanResult.Cancelled)
                        }
                    }
                }
                .addOnCanceledListener {
                    if (cont.isActive) {
                        cont.resume(PhoneQrScanResult.Cancelled)
                    }
                }
                .addOnFailureListener { err ->
                    if (cont.isActive) {
                        cont.resume(
                            PhoneQrScanResult.Unavailable(
                                "Scanner indisponible (${err.localizedMessage ?: "Play Services"}). Vous pouvez coller le lien."
                            )
                        )
                    }
                }
        }
}

