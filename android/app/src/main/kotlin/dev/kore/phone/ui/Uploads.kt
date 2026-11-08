package dev.kore.phone.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import java.io.ByteArrayOutputStream

/** A picked file, ready to upload: photos re-encoded as JPEG (no EXIF, at most 2048 px), others as they are. */
object Uploads {
    const val MAX_BYTES = 12 * 1024 * 1024
    /** A message's attachments at most (the link's `maxBlobs`): the photo picker picks up to what's left. */
    const val MAX_FILES = 10
    /** What a phone may upload in an hour (Kore's policy table, `blob.put`): 256 MB. */
    const val BYTES_PER_HOUR = 256L * 1024 * 1024

    /** Why one file wasn't attached, in a few words. */
    fun tooMany() = "more than $MAX_FILES in a message"
    fun tooBig() = "over 12 MB"
    fun unread() = "couldn't be read"
    fun pastHour() = "past this hour's 256 MB"

    /** A device's refusal of an upload, in a few words: its code, else its own message. */
    fun refused(code: String?, message: String?): String = when {
        code == "tooLarge" -> tooBig()
        code == "rateLimited" || code == "rate.limited" -> pastHour()
        code != null && code.startsWith("busy") -> "busy there, try again"
        code == null && message == null -> "no answer"
        else -> message?.trimEnd('.')?.take(40) ?: "refused ($code)"
    }

    /**
     * The one line for what a pick left out: nothing when all came, else the name and why, a
     * second or more counted: "Not attached: a.jpg, over 12 MB" or "2 not attached: a.jpg, over
     * 12 MB; b.png, couldn't be read".
     */
    fun refusedLine(refused: List<Pair<String, String>>): String? = when (refused.size) {
        0 -> null
        1 -> "Not attached: ${refused[0].first}, ${refused[0].second}"
        else -> "${refused.size} not attached: " + refused.joinToString("; ") { "${it.first}, ${it.second}" }
    }

    /** What the picker may still pick: the room left in the message. */
    fun room(attached: Int): Int = maxOf(0, MAX_FILES - attached)

    /**
     * The phone's own count of the hour's upload bytes, so a file past the cap is refused here
     * with its reason rather than sent to be refused. Times are the caller's (ms).
     */
    class Budget(private val perHour: Long = BYTES_PER_HOUR) {
        private val sent = ArrayDeque<Pair<Long, Long>>()

        /** Whether [bytes] more fit in the hour before [now]. */
        fun fits(bytes: Long, now: Long): Boolean = used(now) + bytes <= perHour

        fun spend(bytes: Long, now: Long) { used(now); sent.addLast(now to bytes) }

        private fun used(now: Long): Long {
            while (sent.isNotEmpty() && sent.first().first <= now - 3_600_000L) sent.removeFirst()
            return sent.sumOf { it.second }
        }
    }

    /** This app's hour of uploads, across chats and devices. */
    val budget = Budget()
    private const val MAX_SIDE = 2048

    class Read(val name: String?, val mime: String, val bytes: ByteArray, val thumb: Bitmap?)

    fun read(resolver: ContentResolver, uri: Uri, mime: String): Read {
        if (mime.startsWith("image/")) {
            val image = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                val w = info.size.width
                val h = info.size.height
                val scale = minOf(1.0, MAX_SIDE.toDouble() / maxOf(w, h))
                decoder.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            val out = ByteArrayOutputStream()
            image.compress(Bitmap.CompressFormat.JPEG, 85, out)
            val thumb = Bitmap.createScaledBitmap(image, 96, maxOf(1, 96 * image.height / maxOf(1, image.width)), true)
            return Read("photo-${System.currentTimeMillis() % 100000}.jpg", "image/jpeg", out.toByteArray(), thumb)
        }
        val bytes = resolver.openInputStream(uri)?.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_BYTES) break
            }
            out.toByteArray()
        } ?: ByteArray(0)
        return Read(null, mime, bytes, null)
    }
}
