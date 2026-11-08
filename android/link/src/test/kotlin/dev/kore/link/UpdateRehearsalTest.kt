package dev.kore.link

import dev.kore.link.update.RangeFetcher
import dev.kore.link.update.RangedDownload
import dev.kore.link.update.ReleaseError
import dev.kore.link.update.ReleaseManifest
import dev.kore.link.update.ReleaseSigner
import dev.kore.link.update.UpdateCheck
import java.io.File
import java.net.URL
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The phone's update path against a real release (scripts/tests/release-rehearsal.sh): a dry-run
 * release served on localhost (KORE_REHEARSAL), signed with a throwaway key (KORE_REHEARSAL_KEY),
 * its kore.apk's signing certificate beside it (KORE_REHEARSAL_CERT). Skipped without them.
 */
class UpdateRehearsalTest {
    @get:Rule val tmp = TemporaryFolder()

    private val base: String? = System.getenv("KORE_REHEARSAL")
    private fun get(name: String) = URL("$base/$name").readBytes()
    private val github = "https://github.com/SoumilB7/kore/releases/download/v0/kore.apk"

    /** The served file, whole, then cut into the ranges asked for. */
    private inner class Served(name: String) : RangeFetcher {
        val bytes = get(name)
        override fun fetch(url: String, from: Long, to: Long, sink: (ByteArray, Int) -> Unit) {
            val piece = bytes.copyOfRange(from.toInt(), to.toInt() + 1)
            sink(piece, piece.size)
        }
    }

    @Test fun theServedReleaseUpdatesThePhone() {
        assumeTrue(base != null)
        val key = Base64.getDecoder().decode(System.getenv("KORE_REHEARSAL_KEY"))
        val manifest = ReleaseManifest.verified(get("SHA256SUMS"), get("SHA256SUMS.sig"), key)
        val apk = Served("kore.apk")
        val assets = mapOf("kore.apk" to (github to apk.bytes.size.toLong()))

        // Offered to an older app only: same version and a downgrade are not.
        val offer = UpdateCheck.offer(assets, manifest, "0.0.1")!!
        assertNull(UpdateCheck.offer(assets, manifest, manifest.version))
        assertNull(UpdateCheck.offer(assets, manifest, "99.0.0"))

        // Downloaded in ranges and kept only when it's the signed hash.
        val file = runBlocking { RangedDownload(offer.url, offer.size, offer.sha256, File(tmp.root, "ok.apk"), apk, chunk = 1L shl 20).run() }
        assertTrue(file.readBytes().contentEquals(apk.bytes))
        val tampered = object : RangeFetcher {
            override fun fetch(url: String, from: Long, to: Long, sink: (ByteArray, Int) -> Unit) =
                apk.fetch(url, from, to) { b, n -> if (from == 0L) b[100] = (b[100] + 1).toByte(); sink(b, n) }
        }
        val refused = runCatching { runBlocking { RangedDownload(offer.url, offer.size, offer.sha256, File(tmp.root, "bad.apk"), tampered).run() } }
        assertTrue(refused.exceptionOrNull() is ReleaseError)

        // A SHA256SUMS edited after signing, or signed by another key, is refused.
        val sums = get("SHA256SUMS")
        assertTrue(runCatching { ReleaseManifest.verified(sums + "x".toByteArray(), get("SHA256SUMS.sig"), key) }.exceptionOrNull() is ReleaseError)
        assertTrue(runCatching { ReleaseManifest.verified(sums, get("SHA256SUMS.sig")) }.exceptionOrNull() is ReleaseError)

        // Its signer is the pinned release certificate; a phone on that certificate takes it, a debug one doesn't.
        val cert = File(System.getenv("KORE_REHEARSAL_CERT")).readBytes()
        assertEquals(ReleaseSigner.RELEASE_SIGNER, ReleaseSigner.sha256(cert))
        assertTrue(ReleaseSigner.accepts(listOf(cert), listOf(cert)))
        assertTrue(!ReleaseSigner.accepts(listOf("debug".toByteArray()), listOf(cert)))
    }
}
