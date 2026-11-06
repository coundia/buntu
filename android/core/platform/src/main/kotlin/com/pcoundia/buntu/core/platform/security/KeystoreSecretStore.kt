package com.pcoundia.buntu.core.platform.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.pcoundia.buntu.core.domain.repository.SecretStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.inject.Inject
import javax.inject.Singleton

/**
 * PRD-37 § 7 & § 12:
 * Hardware-backed secret storage via `AndroidKeyStore` (`AES/GCM/NoPadding`, 256-bit key).
 * Ciphertext blobs are stored in `noBackupFilesDir` so credentials never leave the device
 * and never appear in plaintext preferences, SQLite, or logs.
 */
@Singleton
class KeystoreSecretStore @Inject constructor(
    @ApplicationContext private val context: Context,
) : SecretStore {

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val MASTER_KEY_ALIAS = "com.pcoundia.buntu.master_aes_gcm_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH_BYTES = 12
        private const val GCM_TAG_BITS = 128
    }

    private val mutex = Mutex()
    private val blobsDir: File by lazy {
        File(context.noBackupFilesDir, "keystore_secrets").apply { mkdirs() }
    }

    override suspend fun putSecret(alias: String, plaintext: String) {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
                val iv = cipher.iv
                val encrypted = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))

                val combined = ByteArray(1 + iv.size + encrypted.size)
                combined[0] = iv.size.toByte()
                System.arraycopy(iv, 0, combined, 1, iv.size)
                System.arraycopy(encrypted, 0, combined, 1 + iv.size, encrypted.size)

                blobFileFor(alias).writeBytes(combined)
            }
        }
    }

    override suspend fun getSecret(alias: String): String? =
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val file = blobFileFor(alias)
                if (!file.exists()) return@withLock null
                runCatching {
                    val raw = file.readBytes()
                    if (raw.size <= 1 + GCM_IV_LENGTH_BYTES) return@runCatching null
                    val ivLen = raw[0].toInt() and 0xFF
                    if (ivLen <= 0 || raw.size <= 1 + ivLen) return@runCatching null
                    val iv = raw.copyOfRange(1, 1 + ivLen)
                    val ciphertext = raw.copyOfRange(1 + ivLen, raw.size)

                    val cipher = Cipher.getInstance(TRANSFORMATION)
                    cipher.init(
                        Cipher.DECRYPT_MODE,
                        getOrCreateSecretKey(),
                        GCMParameterSpec(GCM_TAG_BITS, iv),
                    )
                    String(cipher.doFinal(ciphertext), Charsets.UTF_8)
                }.getOrNull()
            }
        }

    override suspend fun deleteSecret(alias: String) {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                blobFileFor(alias).delete()
            }
        }
    }

    private fun blobFileFor(alias: String): File {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(alias.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(blobsDir, "$digest.bin")
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(MASTER_KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        val spec = KeyGenParameterSpec.Builder(
            MASTER_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }
}

