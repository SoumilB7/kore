package dev.kore.link.update

import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Byte ranges of one URL (HTTP `Range`); a fake in tests. Blocking: called on [RangedDownload]'s dispatcher. */
interface RangeFetcher {
    /** Bytes [from]..[to] (inclusive) of [url], handed to [sink] as they arrive; throws when the range doesn't come whole. */
    fun fetch(url: String, from: Long, to: Long, sink: (ByteArray, Int) -> Unit)
}

/** HTTPS ranges with `HttpURLConnection`: redirects followed (GitHub's assets live on another host), https only. */
class HttpRangeFetcher(private val timeoutMs: Int = 30_000) : RangeFetcher {
    override fun fetch(url: String, from: Long, to: Long, sink: (ByteArray, Int) -> Unit) {
        var target = URL(url)
        repeat(5) {
            require(target.protocol == "https") { "not https" }
            val c = target.openConnection() as HttpURLConnection
            c.instanceFollowRedirects = false
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.setRequestProperty("Range", "bytes=$from-$to")
            try {
                when (c.responseCode) {
                    301, 302, 303, 307, 308 -> { target = URL(target, c.getHeaderField("Location")); return@repeat }
                    206 -> {
                        val want = to - from + 1
                        var got = 0L
                        c.inputStream.use { input ->
                            val buf = ByteArray(64 shl 10)
                            while (got < want) {
                                val n = input.read(buf, 0, minOf(buf.size.toLong(), want - got).toInt())
                                if (n < 0) break
                                sink(buf, n)
                                got += n
                            }
                        }
                        if (got != want) throw java.io.IOException("short range: $got of $want")
                        return
                    }
                    else -> throw java.io.IOException("HTTP ${c.responseCode} for a range")
                }
            } finally {
                c.disconnect()
            }
        }
        throw java.io.IOException("too many redirects")
    }
}

/**
 * An update download that survives slow and dropped links: the file is cut into [chunk]-byte
 * pieces fetched [parallel] at a time with HTTP ranges, each written in place; a piece that
 * finished is noted in `<dest>.parts`, so a new run (after the app was killed, or the network
 * dropped) fetches only what's missing. A piece that fails is tried again, up to [tries] times;
 * the whole file is kept only if its SHA-256 is the signed one.
 */
class RangedDownload(
    private val url: String,
    private val size: Long,
    private val sha256: String,
    private val dest: File,
    private val fetcher: RangeFetcher = HttpRangeFetcher(),
    private val parallel: Int = 4,
    private val chunk: Long = 1L shl 20,
    private val tries: Int = 4,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val part = File(dest.path + ".part")
    private val parts = File(dest.path + ".parts")
    val pieces: Int get() = ((size + chunk - 1) / chunk).toInt()

    /** The pieces already on disk from an earlier run (only if that run was for the same file). */
    fun done(): Set<Int> {
        if (!part.exists() || !parts.exists() || part.length() != size) return emptySet()
        val lines = parts.readLines()
        if (lines.firstOrNull() != "$sha256 $size $chunk") return emptySet()
        return lines.drop(1).mapNotNull { it.toIntOrNull() }.filter { it in 0 until pieces }.toSet()
    }

    /** Fetches what's missing and checks the whole; the verified file, or throws. [progress] gets bytes on disk. */
    suspend fun run(progress: (Long) -> Unit = {}): File = withContext(io) {
        require(size > 0) { "size unknown" }
        val have = done().toMutableSet()
        if (have.isEmpty()) {
            RandomAccessFile(part, "rw").use { it.setLength(size) }
            parts.writeText("$sha256 $size $chunk\n")
        }
        val lock = Mutex()
        var bytes = have.sumOf { span(it) }
        progress(bytes)
        val missing = (0 until pieces).filter { it !in have }.toMutableList()
        coroutineScope {
            (0 until minOf(parallel, missing.size)).map {
                async(io) {
                    while (true) {
                        val i = lock.withLock { missing.removeFirstOrNull() } ?: break
                        piece(i)
                        lock.withLock {
                            parts.appendText("$i\n")
                            bytes += span(i)
                            progress(bytes)
                        }
                    }
                }
            }.awaitAll()
        }
        val digest = MessageDigest.getInstance("SHA-256")
        part.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val hex = digest.digest().joinToString("") { "%02x".format(it) }
        if (!hex.equals(sha256, ignoreCase = true)) {
            part.delete()
            parts.delete()
            throw ReleaseError("the download doesn't match its SHA-256 in SHA256SUMS")
        }
        dest.delete()
        if (!part.renameTo(dest)) throw java.io.IOException("can't keep the download")
        parts.delete()
        dest
    }

    private fun span(i: Int): Long = minOf(chunk, size - i * chunk)

    private fun piece(i: Int) {
        val from = i * chunk
        val to = from + span(i) - 1
        var last: Exception? = null
        repeat(tries) {
            try {
                RandomAccessFile(part, "rw").use { f ->
                    f.seek(from)
                    var at = from
                    fetcher.fetch(url, from, to) { b, n ->
                        if (at + n > to + 1) throw java.io.IOException("range overflows")
                        f.write(b, 0, n)
                        at += n
                    }
                    if (at != to + 1) throw java.io.IOException("short piece")
                }
                return
            } catch (e: Exception) {
                last = e
            }
        }
        throw last ?: java.io.IOException("piece $i failed")
    }
}
