package dev.kore.phone.link

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import dev.kore.link.node.RaiseSigner
import dev.kore.link.trust.IdentitySigner
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

private fun ecKey(alias: String, biometric: Boolean): PrivateKey {
    val ks = keyStore()
    (ks.getKey(alias, null) as? PrivateKey)?.let { return it }
    val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
        .setDigests(KeyProperties.DIGEST_SHA256)
    // Never setUnlockedDeviceRequired: OnePlus refused it.
    if (biometric) {
        spec.setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
    }
    return KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec.build()) }.generateKeyPair().private
}

/**
 * The phone's identity key (phase 18 §1): P-256 in the Keystore, never exported, no fingerprint —
 * it signs every handshake's B, also while the phone is locked (background links).
 */
object IdentityKey : IdentitySigner {
    private const val ALIAS = "kore_identity"
    // Read from the Keystore each time: Leave KoreNet deletes it, the next join makes a new one.
    private val key: PrivateKey get() = ecKey(ALIAS, biometric = false)

    override val publicKey: ByteArray get() = key.let { keyStore().getCertificate(ALIAS).publicKey.encoded }

    override fun sign(message: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(key)
        update(message)
        sign()
    }

    fun forget() = runCatching { keyStore().deleteEntry(ALIAS) }
}

/**
 * `kore_raise`, the one biometric key: a strong fingerprint per signature (a CryptoObject), for
 * raising a chat's mode or Arsenal tier from the phone. A new fingerprint enrolled on the phone
 * invalidates it; it's made again and its public half goes to each Mac (`raise.key`), taken once
 * the owner Allows it there.
 */
class RaiseKey(private val front: () -> Activity?, private val renewed: (ByteArray) -> Unit = {}) : RaiseSigner {
    val publicKey: ByteArray get() = key().let { keyStore().getCertificate(ALIAS).publicKey.encoded }

    private fun key(): PrivateKey = ecKey(ALIAS, biometric = true)

    /** The signature, or null: no screen to ask on, cancelled, or the key was invalidated. */
    override suspend fun sign(digest: ByteArray): ByteArray? = withContext(Dispatchers.Main) {
        val activity = front() ?: return@withContext null
        val signature = Signature.getInstance("SHA256withECDSA")
        try {
            signature.initSign(key())
        } catch (e: KeyPermanentlyInvalidatedException) {
            // A fingerprint was enrolled: a new key, whose public half each Mac takes on its owner's Allow.
            runCatching { keyStore().deleteEntry(ALIAS) }
            runCatching { publicKey }.onSuccess(renewed)
            return@withContext null
        }
        suspendCancellableCoroutine { cont ->
            val cancel = CancellationSignal()
            cont.invokeOnCancellation { cancel.cancel() }
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("Raise with your fingerprint")
                .setSubtitle("Kore")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButton("Cancel", activity.mainExecutor) { _, _ -> if (cont.isActive) cont.resume(null) }
                .build()
            prompt.authenticate(BiometricPrompt.CryptoObject(signature), cancel, activity.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    val s = result.cryptoObject?.signature ?: signature
                    if (cont.isActive) cont.resume(runCatching { s.update(digest); s.sign() }.getOrNull())
                }
                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    if (cont.isActive) cont.resume(null)
                }
            })
        }
    }

    fun forget() = runCatching { keyStore().deleteEntry(ALIAS) }

    companion object {
        const val ALIAS = "kore_raise"
    }
}
