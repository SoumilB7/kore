package dev.kore.link.trust

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.UUID

/**
 * Fields hashed together, each as a 4-byte big-endian length and its bytes, so no two field lists
 * give the same input (`Tests/Fixtures/link/v2/bind.json` shows the bytes).
 */
class Prefixed {
    private val out = ByteArrayOutputStream()

    fun add(field: ByteArray): Prefixed = apply {
        out.write(ByteBuffer.allocate(4).putInt(field.size).array())
        out.write(field)
    }

    fun add(text: String): Prefixed = add(text.toByteArray(Charsets.UTF_8))

    /** A device id as its 16 bytes in RFC 4122 order. */
    fun add(id: UUID): Prefixed = add(ByteBuffer.allocate(16).putLong(id.mostSignificantBits).putLong(id.leastSignificantBits).array())

    val bytes: ByteArray get() = out.toByteArray()
    val sha256: ByteArray get() = sha256(bytes)

    companion object {
        fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)
    }
}

/**
 * The session binding (phase 18 §1 "Handshake + identity"):
 * `B = SHA256("kore-bind/2" | route | nonceS | nonceC | deviceC | deviceS | nodeKeyC | nodeKeyS)`.
 * Both sides compute it from their own view (node keys from their own Status and the peer's WhoIs,
 * never from the peer's claims) and sign it.
 */
class Binding(
    val route: String,
    val nonceS: ByteArray,
    val nonceC: ByteArray,
    val deviceC: UUID,
    val deviceS: UUID,
    val nodeKeyC: String,
    val nodeKeyS: String,
) {
    init {
        require(route == TAILNET || route == SSH) { "binding: bad route" }
        require(nonceS.size == NONCE_SIZE) { "binding: bad nonceS" }
        require(nonceC.size == NONCE_SIZE) { "binding: bad nonceC" }
        require(deviceC != deviceS) { "binding: bad devices" }
        require(nodeKeyC.isNotEmpty() && nodeKeyS.isNotEmpty()) { "binding: bad nodeKey" }
    }

    val preimage: ByteArray
        get() = Prefixed().add(LABEL).add(route).add(nonceS).add(nonceC).add(deviceC).add(deviceS).add(nodeKeyC).add(nodeKeyS).bytes

    /** B. */
    val digest: ByteArray by lazy { Prefixed.sha256(preimage) }

    companion object {
        const val LABEL = "kore-bind/2"
        const val NONCE_SIZE = 32
        const val TAILNET = "tailnet"
        const val SSH = "ssh"
    }
}

/**
 * Raising a chat's mode from the phone (phase 18 §1 "Raises"): the Run node hands out a 32-byte
 * nonce (`raise.chal`, 60 s, single use); the phone signs this digest with its biometric
 * `kore_raise` key.
 */
object Raise {
    const val LABEL = "kore-raise/1"
    const val NONCE_SIZE = 32
    const val LIFETIME_MS = 60_000L

    fun digest(binding: ByteArray, nonce: ByteArray, chatId: String, modeId: String): ByteArray =
        Prefixed().add(LABEL).add(binding).add(nonce).add(chatId).add(modeId).sha256
}

/**
 * A device's P-256 key: signatures are ECDSA P-256 over SHA-256 of the message, DER encoded
 * (`SHA256withECDSA`); the public half is X.509 SubjectPublicKeyInfo DER.
 */
interface IdentitySigner {
    val publicKey: ByteArray
    fun sign(message: ByteArray): ByteArray
}

object IdentityProof {
    fun sign(binding: Binding, signer: IdentitySigner): ByteArray = signer.sign(binding.digest)

    /** Whether [signature] (DER) is [key]'s (SPKI DER) over [message]. */
    fun verify(signature: ByteArray, message: ByteArray, key: ByteArray): Boolean = runCatching {
        val pub = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(key))
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(pub)
            update(message)
            verify(signature)
        }
    }.getOrDefault(false)
}

/** An identity key held in memory: tests', and nothing else on the phone (its keys live in Keystore). */
class SoftwareIdentity(private val pair: java.security.KeyPair) : IdentitySigner {
    override val publicKey: ByteArray get() = pair.public.encoded

    override fun sign(message: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(pair.private)
        update(message)
        sign()
    }

    companion object {
        fun fresh(): SoftwareIdentity = SoftwareIdentity(
            java.security.KeyPairGenerator.getInstance("EC").apply { initialize(java.security.spec.ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        )

        /** From a 32-byte private scalar (the fixtures' keys). */
        fun fromScalar(scalar: ByteArray): SoftwareIdentity {
            val params = java.security.AlgorithmParameters.getInstance("EC").apply { init(java.security.spec.ECGenParameterSpec("secp256r1")) }
                .getParameterSpec(java.security.spec.ECParameterSpec::class.java)
            val kf = KeyFactory.getInstance("EC")
            val d = java.math.BigInteger(1, scalar)
            val priv = kf.generatePrivate(java.security.spec.ECPrivateKeySpec(d, params))
            val q = multiply(params, d)
            val pub = kf.generatePublic(java.security.spec.ECPublicKeySpec(q, params))
            return SoftwareIdentity(java.security.KeyPair(pub, priv))
        }

        // The public point d·G, for test keys only (double-and-add on the curve's affine form).
        private fun multiply(p: java.security.spec.ECParameterSpec, d: java.math.BigInteger): java.security.spec.ECPoint {
            val field = (p.curve.field as java.security.spec.ECFieldFp).p
            val a = p.curve.a
            fun add(x: java.security.spec.ECPoint, y: java.security.spec.ECPoint): java.security.spec.ECPoint {
                if (x == java.security.spec.ECPoint.POINT_INFINITY) return y
                if (y == java.security.spec.ECPoint.POINT_INFINITY) return x
                val lambda = if (x == y) {
                    if (x.affineY.signum() == 0) return java.security.spec.ECPoint.POINT_INFINITY
                    x.affineX.pow(2).multiply(java.math.BigInteger.valueOf(3)).add(a).multiply(x.affineY.shiftLeft(1).modInverse(field)).mod(field)
                } else {
                    if (x.affineX == y.affineX) return java.security.spec.ECPoint.POINT_INFINITY
                    y.affineY.subtract(x.affineY).multiply(y.affineX.subtract(x.affineX).modInverse(field)).mod(field)
                }
                val rx = lambda.pow(2).subtract(x.affineX).subtract(y.affineX).mod(field)
                val ry = lambda.multiply(x.affineX.subtract(rx)).subtract(x.affineY).mod(field)
                return java.security.spec.ECPoint(rx, ry)
            }
            var r = java.security.spec.ECPoint.POINT_INFINITY
            var addend = p.generator
            for (i in 0 until d.bitLength()) {
                if (d.testBit(i)) r = add(r, addend)
                addend = add(addend, addend)
            }
            return r
        }
    }
}

/** Fresh random bytes from the system's secure generator. */
fun secureRandom(n: Int): ByteArray = ByteArray(n).also { java.security.SecureRandom().nextBytes(it) }
