package dev.kore.link

import dev.kore.link.Fixtures.b64
import dev.kore.link.Fixtures.hex
import dev.kore.link.Fixtures.o
import dev.kore.link.Fixtures.s
import dev.kore.link.trust.Binding
import dev.kore.link.trust.IdentityProof
import dev.kore.link.trust.Raise
import dev.kore.link.trust.SoftwareIdentity
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** bind.json and raise.json: the preimages and digests byte for byte, the signatures verified. */
class TrustFixtureTest {
    private val bind = Fixtures.json("bind.json")
    private val raise = Fixtures.json("raise.json")
    private val client = bind.o("client")
    private val server = bind.o("server")

    private fun binding(route: String): Binding {
        val r = bind.o(route)
        return Binding(
            r.s("route"), hex(bind.s("nonceS")), hex(bind.s("nonceC")), UUID.fromString(client.s("device")), UUID.fromString(server.s("device")),
            r.s("nodeKeyC"), r.s("nodeKeyS"),
        )
    }

    @Test fun bindingPreimageAndDigestMatch() {
        for (route in listOf("tailnet", "ssh")) {
            val b = binding(route)
            assertEquals(route, bind.o(route).s("preimage"), b.preimage.toHex())
            assertEquals(route, bind.o(route).s("B"), b.digest.toHex())
        }
    }

    @Test fun bindingSignaturesVerify() {
        for (route in listOf("tailnet", "ssh")) {
            val b = binding(route)
            val r = bind.o(route)
            assertTrue(IdentityProof.verify(b64(r.s("sigC")), b.digest, b64(client.s("publicKey"))))
            assertTrue(IdentityProof.verify(b64(r.s("sigS")), b.digest, b64(server.s("publicKey"))))
            // Never by the other side's key, never over the other route's B.
            assertFalse(IdentityProof.verify(b64(r.s("sigC")), b.digest, b64(server.s("publicKey"))))
            assertFalse(IdentityProof.verify(b64(r.s("sigC")), binding(if (route == "ssh") "tailnet" else "ssh").digest, b64(client.s("publicKey"))))
        }
    }

    @Test fun fixtureKeysGiveTheirPublicKeysAndSignVerifiably() {
        val c = SoftwareIdentity.fromScalar(hex(client.s("privateKey")))
        assertArrayEquals(b64(client.s("publicKey")), c.publicKey)
        assertArrayEquals(b64(server.s("publicKey")), SoftwareIdentity.fromScalar(hex(server.s("privateKey"))).publicKey)
        val b = binding("tailnet")
        // ECDSA here is randomised: this side's signature differs from the fixture's, and verifies.
        assertTrue(IdentityProof.verify(IdentityProof.sign(b, c), b.digest, b64(client.s("publicKey"))))
    }

    @Test fun bindingRefusesBadFields() {
        val ok = binding("tailnet")
        for (bad in listOf<() -> Unit>(
            { Binding("wifi", ok.nonceS, ok.nonceC, ok.deviceC, ok.deviceS, "a", "b") },
            { Binding("tailnet", ByteArray(31), ok.nonceC, ok.deviceC, ok.deviceS, "a", "b") },
            { Binding("tailnet", ok.nonceS, ok.nonceC, ok.deviceC, ok.deviceC, "a", "b") },
            { Binding("tailnet", ok.nonceS, ok.nonceC, ok.deviceC, ok.deviceS, "", "b") },
        )) {
            assertTrue(runCatching(bad).isFailure)
        }
    }

    @Test fun raiseDigestMatchesAndItsSignatureVerifies() {
        assertEquals(bind.o("tailnet").s("B"), raise.s("B"))
        val pre = dev.kore.link.trust.Prefixed().add(Raise.LABEL).add(hex(raise.s("B"))).add(hex(raise.s("nonce"))).add(raise.s("chatId")).add(raise.s("modeId"))
        assertEquals(raise.s("preimage"), pre.bytes.toHex())
        val digest = Raise.digest(hex(raise.s("B")), hex(raise.s("nonce")), raise.s("chatId"), raise.s("modeId"))
        assertEquals(raise.s("digest"), digest.toHex())
        val key = b64(raise.o("raiseKey").s("publicKey"))
        assertTrue(IdentityProof.verify(b64(raise.s("sig")), digest, key))
        assertFalse(IdentityProof.verify(b64(raise.s("sig")), Raise.digest(hex(raise.s("B")), hex(raise.s("nonce")), raise.s("chatId"), "manual"), key))
        assertEquals(Raise.LIFETIME_MS / 1000, raise["ttlSeconds"].toString().toLong())
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
