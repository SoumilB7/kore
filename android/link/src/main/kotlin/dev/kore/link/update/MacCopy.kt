package dev.kore.link.update

import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

/** One piece of a part the Mac has: where it starts, the part's whole size, its bytes. */
class AppPiece(val offset: Long, val total: Long, val data: ByteArray)

/**
 * Phone updates from a Mac over KoreNet (the "Mac copy", beside GitHub releases): the Mac serves
 * the release's three files (`app.get`, link 1.13) and this checks them exactly as a GitHub
 * release is checked: `SHA256SUMS` against `SHA256SUMS.sig` with Kore's release key, the APK
 * against its signed SHA-256, then (in the app) the signer. Only a debug build takes an unsigned
 * manifest (a dev build the Mac made), and Android's same-signer rule still holds for it.
 * Pure over [read], so the tests run it on a fake Mac. Works only while the app is open, as the
 * link does.
 */
object MacCopy {
    /** Reads one piece of `sums`, `sig` or `apk` from [offset]; null when the Mac has none or the link is down. */
    fun interface Reader {
        suspend fun read(part: String, offset: Long): AppPiece?
    }

    /** The largest manifest or signature taken from a Mac. */
    const val SMALL_MAX = 64 * 1024L

    /** What the Mac offers, checked, if it's newer than [installed]; null when it has none or nothing newer. */
    suspend fun offer(read: Reader, installed: String, debug: Boolean, key: ByteArray? = KoreReleaseKey.key()): UpdateOffer? {
        val sums = whole(read, "sums") ?: return null
        val sig = whole(read, "sig")
        val manifest = when {
            sig != null -> ReleaseManifest.verified(sums, sig, key)
            debug -> ReleaseManifest.parse(sums.decodeToString())
            else -> throw ReleaseError("the Mac's copy isn't signed by Kore's release key")
        }
        val sha = manifest.files[UpdateCheck.APK] ?: throw ReleaseError("SHA256SUMS doesn't list ${UpdateCheck.APK}")
        if (!ReleaseManifest.newer(manifest.version, installed)) return null
        val first = read.read("apk", 0) ?: throw ReleaseError("the Mac lists an update but has no ${UpdateCheck.APK}")
        return UpdateOffer(manifest.version, MAC, first.total, sha)
    }

    /**
     * The APK into [dest], going on from what's there (a download cut off resumes), checked
     * against [offer]'s SHA-256 at the end; a mismatch deletes it. [progress] gets the bytes so far.
     */
    suspend fun download(read: Reader, offer: UpdateOffer, dest: File, progress: (Long) -> Unit = {}): File {
        if (dest.length() > offer.size) dest.delete()
        RandomAccessFile(dest, "rw").use { out ->
            var at = out.length()
            out.seek(at)
            while (at < offer.size) {
                val piece = read.read("apk", at) ?: throw java.io.IOException("the Mac stopped answering")
                if (piece.total != offer.size || piece.offset != at || piece.data.isEmpty()) throw ReleaseError("the Mac's copy changed while downloading")
                out.write(piece.data)
                at += piece.data.size
                progress(at)
            }
        }
        val digest = MessageDigest.getInstance("SHA-256")
        dest.inputStream().use { input ->
            val buf = ByteArray(64 shl 10)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val got = digest.digest().joinToString("") { "%02x".format(it) }
        if (got != offer.sha256) {
            dest.delete()
            throw ReleaseError("the download didn't match the signed SHA-256")
        }
        return dest
    }

    /** An offer's address when it comes from a Mac (the device id follows). */
    const val MAC = "mac:"

    private suspend fun whole(read: Reader, part: String): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        while (true) {
            val piece = read.read(part, out.size().toLong()) ?: return if (out.size() == 0) null else throw java.io.IOException("cut off")
            if (piece.total > SMALL_MAX) throw ReleaseError("the Mac's $part is too large")
            out.write(piece.data)
            if (out.size() >= piece.total || piece.data.isEmpty()) return out.toByteArray()
        }
    }
}
