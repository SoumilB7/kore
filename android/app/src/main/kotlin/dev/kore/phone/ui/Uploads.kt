package dev.kore.phone.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import java.io.ByteArrayOutputStream

/** A picked file, ready to upload: photos re-encoded as JPEG (no EXIF, at most 2048 px), others as they are. */
object Uploads {
    const val MAX_BYTES = 12 * 1024 * 1024
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
