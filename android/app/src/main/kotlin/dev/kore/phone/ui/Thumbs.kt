package dev.kore.phone.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import dev.kore.link.node.NodeClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Attachment thumbnails from a device (`blob.get`), fetched once each when first shown, kept in memory only. */
object Thumbs {
    private val cache = LruCache<String, Bitmap>(48)
    private val asked = HashSet<String>()

    fun get(ref: String): Bitmap? = cache.get(ref)

    /** Fetches [ref] unless it was asked for already; [ready] runs on the caller's thread hop when it lands. */
    fun fetch(scope: CoroutineScope, link: NodeClient, chatId: String, ref: String, ready: () -> Unit) {
        synchronized(asked) { if (!asked.add(ref)) return }
        scope.launch {
            val bytes = link.blobGet(chatId, ref, "thumb") ?: return@launch
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@launch
            cache.put(ref, bitmap)
            ready()
        }
    }
}
