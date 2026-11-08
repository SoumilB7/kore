package dev.kore.link

import com.google.crypto.tink.subtle.Ed25519Sign
import dev.kore.link.update.KoreReleaseKey
import dev.kore.link.update.RangeFetcher
import dev.kore.link.update.RangedDownload
import dev.kore.link.update.ReleaseError
import dev.kore.link.update.ReleaseManifest
import dev.kore.link.update.UpdateCheck
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class UpdateTest {
    @get:Rule val tmp = TemporaryFolder()

    private val apk = ByteArray(5_000_000) { (it * 31 % 251).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(apk).joinToString("") { "%02x".format(it) }
    private val sums = "# kore 0.3.0 ${"a".repeat(40)}\n$sha  kore.apk\n${"b".repeat(64)}  kore-host-linux-x86_64.xz\n"
    private val pair = Ed25519Sign.KeyPair.newKeyPair()

    @Test fun releaseKeyIsTheMacsOwn() {
        val swift = File(System.getProperty("kore.releaseKey")).readText()
        val key = Regex("static let base64 = \"([^\"]+)\"").find(swift)!!.groupValues[1]
        assertEquals(key, KoreReleaseKey.BASE64)
    }

    @Test fun theSignedManifestVerifiesAndOffersTheNewerApk() {
        val sig = Ed25519Sign(pair.privateKey).sign(sums.toByteArray())
        val m = ReleaseManifest.verified(sums.toByteArray(), sig, pair.publicKey)
        assertEquals("0.3.0", m.version)
        val assets = UpdateCheck.assets("""{"tag_name":"v0.3.0","assets":[{"name":"kore.apk","browser_download_url":"https://github.com/x/kore.apk","size":5000000}]}""")
        assertEquals(dev.kore.link.update.UpdateOffer("0.3.0", "https://github.com/x/kore.apk", 5_000_000, sha), UpdateCheck.offer(assets, m, "0.2.3"))
        assertNull(UpdateCheck.offer(assets, m, "0.3.0"))
        assertNull(UpdateCheck.offer(assets, m, "0.10.0"))
    }

    @Test fun anythingNotSignedByTheKeyIsRefused() {
        val sig = Ed25519Sign(pair.privateKey).sign(sums.toByteArray())
        val other = Ed25519Sign.KeyPair.newKeyPair().publicKey
        for (bad in listOf<() -> Unit>(
            { ReleaseManifest.verified(sums.toByteArray(), sig, other) },
            { ReleaseManifest.verified((sums + "x").toByteArray(), sig, pair.publicKey) },
            { ReleaseManifest.verified(sums.toByteArray(), sig.copyOf(63), pair.publicKey) },
            // The placeholder key verifies nothing.
            { ReleaseManifest.verified(sums.toByteArray(), sig) },
        )) {
            assertTrue(runCatching(bad).exceptionOrNull() is ReleaseError)
        }
        assertNull(KoreReleaseKey.key())
    }

    @Test fun malformedManifestsAreRefused() {
        for (bad in listOf("", "# kore 0.3 abc\n", "# kore 0.3.0 ${"a".repeat(40)}\n$sha kore.apk\n", "# kore 0.3.0 ${"a".repeat(40)}\n$sha  ../kore.apk\n")) {
            assertTrue(bad, runCatching { ReleaseManifest.parse(bad) }.isFailure)
        }
    }

    /** Serves [apk] in ranges; [failAt] ranges (by start) fail once each, [dieAfter] pieces then everything fails. */
    private inner class Fetcher(val failAt: MutableSet<Long> = mutableSetOf(), var dieAfter: Int = Int.MAX_VALUE) : RangeFetcher {
        val asked = mutableListOf<Long>()
        override fun fetch(url: String, from: Long, to: Long, sink: (ByteArray, Int) -> Unit) {
            synchronized(this) {
                asked += from
                if (dieAfter-- <= 0) throw java.io.IOException("network gone")
                if (failAt.remove(from)) throw java.io.IOException("dropped")
            }
            val piece = apk.copyOfRange(from.toInt(), to.toInt() + 1)
            sink(piece, piece.size)
        }
    }

    @Test fun rangedPiecesResumeAfterADroppedRunAndVerify() = runTest {
        val dest = File(tmp.root, "kore.apk")
        val io = StandardTestDispatcher(testScheduler)
        val first = Fetcher(dieAfter = 2)
        val dl = { f: RangeFetcher -> RangedDownload("https://x/kore.apk", apk.size.toLong(), sha, dest, f, parallel = 2, chunk = 1L shl 20, tries = 2, io = io) }
        assertTrue(runCatching { dl(first).run() }.isFailure)
        val kept = dl(first).done()
        assertEquals(2, kept.size)
        val second = Fetcher(failAt = mutableSetOf(3L shl 20))
        val file = dl(second).run()
        assertArrayEquals(apk, file.readBytes())
        // Only the missing pieces, the dropped one twice.
        assertEquals((0 until 5).map { it.toLong() shl 20 }.filter { it.toInt() / (1 shl 20) !in kept } .size + 1, second.asked.size)
        assertTrue(!File(dest.path + ".parts").exists())
    }

    @Test fun aDownloadThatDoesntMatchItsHashIsThrownAway() = runTest {
        val dest = File(tmp.root, "kore.apk")
        val dl = RangedDownload("https://x/kore.apk", apk.size.toLong(), "0".repeat(64), dest, Fetcher(), io = StandardTestDispatcher(testScheduler))
        assertTrue(runCatching { dl.run() }.exceptionOrNull() is ReleaseError)
        assertTrue(!dest.exists() && !File(dest.path + ".part").exists())
    }
}
