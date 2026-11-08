package dev.kore.link

import com.google.crypto.tink.subtle.Ed25519Sign
import dev.kore.link.update.AppPiece
import dev.kore.link.update.MacCopy
import dev.kore.link.update.ReleaseError
import java.security.MessageDigest
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Phone updates from a Mac over KoreNet: checked as a GitHub release is, resumable, nothing unsigned on a release build. */
class MacCopyTest {
    @get:Rule val tmp = TemporaryFolder()

    private val apk = ByteArray(1_300_000) { (it * 7 % 253).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(apk).joinToString("") { "%02x".format(it) }
    private val sums = "# kore 0.4.0 ${"c".repeat(40)}\n$sha  kore.apk\n".toByteArray()
    private val pair = Ed25519Sign.KeyPair.newKeyPair()
    private val sig = Ed25519Sign(pair.privateKey).sign(sums)

    /** A Mac serving its files in 512 KiB pieces, as PhoneApp does; [cutAfter] pieces of the APK, then silence. */
    private class Mac(val files: Map<String, ByteArray>, var cutAfter: Int = Int.MAX_VALUE) : MacCopy.Reader {
        val asked = mutableListOf<Pair<String, Long>>()
        override suspend fun read(part: String, offset: Long): AppPiece? {
            asked += part to offset
            val f = files[part] ?: return null
            if (part == "apk" && asked.count { it.first == "apk" } > cutAfter) return null
            val start = offset.coerceIn(0, f.size.toLong()).toInt()
            return AppPiece(start.toLong(), f.size.toLong(), f.copyOfRange(start, minOf(f.size, start + 512 * 1024)))
        }
    }

    @Test fun aSignedNewerCopyIsOfferedAndDownloadsInPieces() = runTest {
        val mac = Mac(mapOf("sums" to sums, "sig" to sig, "apk" to apk))
        val offer = MacCopy.offer(mac, installed = "0.3.9", debug = false, key = pair.publicKey)!!
        assertEquals("0.4.0", offer.version)
        assertEquals(apk.size.toLong(), offer.size)
        assertTrue(offer.url.startsWith(MacCopy.MAC))
        val file = MacCopy.download(mac, offer, tmp.root.resolve("kore.apk"))
        assertArrayEquals(apk, file.readBytes())
        assertEquals(listOf(0L, 524_288L, 1_048_576L), mac.asked.filter { it.first == "apk" }.drop(1).map { it.second })
    }

    @Test fun nothingNewerIsNoOffer() = runTest {
        assertNull(MacCopy.offer(Mac(mapOf("sums" to sums, "sig" to sig, "apk" to apk)), installed = "0.4.0", debug = false, key = pair.publicKey))
        assertNull(MacCopy.offer(Mac(emptyMap()), installed = "0.1.0", debug = false, key = pair.publicKey))
    }

    @Test fun aReleaseBuildRefusesAnUnsignedOrForeignCopy() = runTest {
        try {
            MacCopy.offer(Mac(mapOf("sums" to sums, "apk" to apk)), installed = "0.1.0", debug = false, key = pair.publicKey)
            fail("unsigned taken")
        } catch (_: ReleaseError) {}
        val other = Ed25519Sign(Ed25519Sign.KeyPair.newKeyPair().privateKey).sign(sums)
        try {
            MacCopy.offer(Mac(mapOf("sums" to sums, "sig" to other, "apk" to apk)), installed = "0.1.0", debug = false, key = pair.publicKey)
            fail("foreign signature taken")
        } catch (_: ReleaseError) {}
    }

    @Test fun aDebugBuildTakesTheMacsUnsignedDevBuild() = runTest {
        val offer = MacCopy.offer(Mac(mapOf("sums" to sums, "apk" to apk)), installed = "0.1.0", debug = true, key = pair.publicKey)
        assertEquals("0.4.0", offer?.version)
    }

    @Test fun aCutDownloadResumesWhereItStopped() = runTest {
        val mac = Mac(mapOf("sums" to sums, "sig" to sig, "apk" to apk), cutAfter = 2)
        val offer = MacCopy.offer(mac, installed = "0.1.0", debug = false, key = pair.publicKey)!!
        val dest = tmp.root.resolve("kore.apk")
        try { MacCopy.download(mac, offer, dest); fail("not cut") } catch (_: java.io.IOException) {}
        assertEquals(524_288L, dest.length())
        mac.cutAfter = Int.MAX_VALUE
        mac.asked.clear()
        assertArrayEquals(apk, MacCopy.download(mac, offer, dest).readBytes())
        assertEquals(524_288L, mac.asked.first().second)
    }

    @Test fun aCopyThatDoesntMatchTheSignedHashIsDeleted() = runTest {
        val bad = apk.copyOf().also { it[10] = (it[10] + 1).toByte() }
        val mac = Mac(mapOf("sums" to sums, "sig" to sig, "apk" to bad))
        val offer = MacCopy.offer(mac, installed = "0.1.0", debug = false, key = pair.publicKey)!!
        val dest = tmp.root.resolve("kore.apk")
        try { MacCopy.download(mac, offer, dest); fail("bad hash taken") } catch (_: ReleaseError) {}
        assertTrue(!dest.exists())
    }
}
