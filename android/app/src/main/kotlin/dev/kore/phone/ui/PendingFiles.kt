package dev.kore.phone.ui

import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * A chat's attachments not yet sent, kept in the app's cache (a folder per chat): each file's bytes
 * as read (a photo already re-encoded) and an index, and the camera's target while it's out. So
 * leaving for the camera or a picker loses nothing, even when Android ends the screen or the whole
 * process meanwhile. One holder per chat in a process ([of]): a screen made again finds its chips,
 * and one upload loop runs per chat. Each file is uploaded once the link is up; a link that drops
 * mid-upload means it waits again, never that it's dropped. Only a refusal from the device (or the
 * owner's ×) removes one.
 */
class PendingFiles(private val dir: File, private val scope: CoroutineScope) {
    data class Item(val id: String, val name: String, val mime: String, val blobId: String? = null)

    /** One upload's end, as [drain]'s uploader saw it. */
    sealed interface Outcome {
        data class Uploaded(val blobId: String) : Outcome
        /** The device said no: the file goes, with [why]. */
        data class Refused(val why: String) : Outcome
        /** Nothing answered (the link went, or the device was silent): it's tried again. */
        data object NoAnswer : Outcome
    }

    private val index = File(dir, INDEX)
    private val shotFile = File(dir, SHOT)
    private val itemsFlow = MutableStateFlow(load())
    /** In the composer, in order: uploaded ones carry their blob id. */
    val items: StateFlow<List<Item>> = itemsFlow.asStateFlow()
    private val refusedFlow = MutableSharedFlow<Pair<String, String>>(extraBufferCapacity = 16)
    /** A file the device refused, or that couldn't be read again: its name and why. */
    val refused: SharedFlow<Pair<String, String>> = refusedFlow.asSharedFlow()

    fun file(id: String): File = File(dir, id)

    /** Keeps [bytes] as a new attachment at the end. */
    @Synchronized fun add(name: String, mime: String, bytes: ByteArray): Item {
        dir.mkdirs()
        val item = Item(UUID.randomUUID().toString(), name, mime)
        file(item.id).writeBytes(bytes)
        set(itemsFlow.value + item)
        return item
    }

    /** Back in the composer at the front (a message that didn't go): those whose bytes are still here. */
    @Synchronized fun restore(back: List<Item>) {
        val have = itemsFlow.value.map { it.id }.toSet()
        set(back.filter { it.id !in have && file(it.id).exists() } + itemsFlow.value)
    }

    @Synchronized fun uploaded(id: String, blobId: String?) {
        if (itemsFlow.value.none { it.id == id }) return
        set(itemsFlow.value.map { if (it.id == id) it.copy(blobId = blobId) else it })
    }

    /** Out of the composer and gone (the owner's ×, a refusal). */
    @Synchronized fun remove(id: String) {
        set(itemsFlow.value.filterNot { it.id == id })
        file(id).delete()
    }

    /**
     * Sending: [ids] leave the composer; their bytes stay until [forget], so a message that didn't
     * go comes back ([restore]) or uploads again.
     */
    @Synchronized fun take(ids: Collection<String>): List<Item> {
        val (out, keep) = itemsFlow.value.partition { it.id in ids }
        set(keep)
        return out
    }

    /** A message went: its files' bytes are no longer needed. */
    @Synchronized fun forget(ids: Collection<String>) {
        val shown = itemsFlow.value.map { it.id }.toSet()
        ids.filter { it !in shown }.forEach { file(it).delete() }
    }

    /** Where the camera writes its photo, kept from before it opens until it returns. */
    var shot: File?
        @Synchronized get() = runCatching { shotFile.readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() }?.let(::File)
        @Synchronized set(value) {
            if (value == null) shotFile.delete() else { dir.mkdirs(); write(shotFile, value.path) }
        }

    private var draining: Job? = null

    /**
     * Uploads every file without a blob id, one at a time and in order, each once [up] says the
     * link is up. Nothing back: tried again after [RETRY_MS] (doubling to [RETRY_CAP_MS]), once
     * the link is up. One loop at a time; it ends when nothing waits.
     */
    @Synchronized fun drain(up: Flow<Boolean>, upload: suspend (Item, ByteArray) -> Outcome) {
        if (draining?.isActive == true) return
        draining = scope.launch {
            var wait = RETRY_MS
            while (true) {
                val next = synchronized(this@PendingFiles) { itemsFlow.value.firstOrNull { it.blobId == null } } ?: break
                up.first { it }
                // The owner may have removed it while the link came.
                if (itemsFlow.value.none { it.id == next.id }) continue
                val bytes = runCatching { file(next.id).readBytes() }.getOrNull()
                if (bytes == null) {
                    remove(next.id)
                    refusedFlow.tryEmit(next.name to UNREAD)
                    continue
                }
                when (val o = upload(next, bytes)) {
                    is Outcome.Uploaded -> { wait = RETRY_MS; uploaded(next.id, o.blobId) }
                    is Outcome.Refused -> { remove(next.id); refusedFlow.tryEmit(next.name to o.why) }
                    Outcome.NoAnswer -> { delay(wait); wait = minOf(wait * 2, RETRY_CAP_MS) }
                }
            }
        }
    }

    private fun set(list: List<Item>) {
        itemsFlow.value = list
        dir.mkdirs()
        write(index, JsonArray(list.map { i ->
            JsonObject(mapOf("id" to JsonPrimitive(i.id), "name" to JsonPrimitive(i.name), "mime" to JsonPrimitive(i.mime),
                "blobId" to (i.blobId?.let(::JsonPrimitive) ?: JsonNull)))
        }).toString())
    }

    /** What the folder holds: its index's files that are still there; anything else in it is a leftover and goes. */
    private fun load(): List<Item> {
        val list = runCatching {
            Json.parseToJsonElement(index.readText()) as JsonArray
        }.getOrNull()?.mapNotNull { e ->
            runCatching {
                val o = e.jsonObject
                Item(o["id"]!!.jsonPrimitive.content, o["name"]!!.jsonPrimitive.content, o["mime"]!!.jsonPrimitive.content,
                    o["blobId"]?.jsonPrimitive?.contentOrNull)
            }.getOrNull()
        }?.filter { file(it.id).exists() } ?: emptyList()
        val keep = list.map { it.id }.toSet() + INDEX + SHOT
        dir.listFiles()?.forEach { if (it.name !in keep) it.delete() }
        return list
    }

    private fun write(f: File, text: String) {
        val tmp = File(f.path + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(f)) { f.writeText(text); tmp.delete() }
    }

    companion object {
        const val RETRY_MS = 2_000L
        const val RETRY_CAP_MS = 30_000L
        const val UNREAD = "couldn't be read"
        private const val INDEX = "index.json"
        private const val SHOT = "shot"
        private val all = HashMap<String, PendingFiles>()

        /** The chat's holder in this process: made (and read from disk) once. */
        @Synchronized fun of(cacheDir: File, chatId: String, scope: CoroutineScope): PendingFiles =
            all.getOrPut(chatId) { PendingFiles(File(File(cacheDir, "attach"), folder(chatId)), scope) }

        /** A chat id as a folder name. */
        fun folder(chatId: String): String = chatId.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "_" }

        /** For tests: a process starting again. */
        @Synchronized internal fun forgetAll() = all.clear()
    }
}
