package dev.kore.phone.debug

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import dev.kore.link.net.ByteConn
import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetClientSession
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.node.NodeDialer
import dev.kore.link.trust.Device
import dev.kore.link.trust.NodeKind
import dev.kore.phone.StandIn
import dev.kore.phone.StandIns
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * Debug builds only: a demo of KoreNet with no Mac, box or Tailscale, for an emulator's
 * screenshots of every screen. On when the app's files hold `demo`:
 *
 *   adb shell run-as dev.kore.android touch files/demo     (off: rm files/demo; restart the app)
 *
 * A Mac ("MacBook") and a box ("mybox") answer from `assets/demo/<mac|box>/` (welcome, snapshot,
 * attn.state, and `tx-<chatId>.json` per chat); every command is answered ok.
 */
class DemoStart : ContentProvider() {
    override fun onCreate(): Boolean {
        val context = context ?: return true
        val flag = File(context.filesDir, "demo")
        if (flag.exists()) StandIns.current = Demo(context, flag.readText().trim())
        return true
    }
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}

/**
 * [scenario] (the text in files/demo): "" the normal demo; `waiting` the Mac never answers (no
 * snapshot); `no-windows` the Mac has none open; `no-devices` this phone knows none.
 */
class Demo(private val context: Context, private val scenario: String = "") : StandIn {
    private val mac = Device(UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02"), "MacBook", NodeKind.MAC, ByteArray(91) { 1 }, listOf("nodekey:mac"), "macbook.tail.ts.net.")
    private val box = Device(UUID.fromString("0E4C2A91-5B7D-4F3E-9A61-2D8C7B5E1F04"), "mybox", NodeKind.BOX, ByteArray(91) { 2 }, listOf("nodekey:box"), "mybox.tail.ts.net.",
        via = setOf(UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02")))
    override val devices = if (scenario == "no-devices") emptyList() else listOf(mac, box)

    override val tailnet: Tailnet = object : Tailnet {
        private fun node(name: String, os: String, key: String, ip: String) =
            TailnetNode("$name.tail.ts.net.", name, os, true, 7, "me@example.com", key, listOf(ip))
        override fun state() = Tailnet.RUNNING
        override fun authUrl(): String? = null
        override fun self() = node("kore-pixel-6-7f3a", "android", "nodekey:phone", "100.64.0.9")
        override fun peers() = listOf(node("macbook", "macOS", "nodekey:mac", "100.64.0.2"), node("mybox", "linux", "nodekey:box", "100.64.0.3"))
        override fun whois(ip: String) = peers().firstOrNull { ip in it.ips }
        override fun dial(address: String, port: Int, timeoutMs: Long): ByteConn = throw java.io.IOException("demo")
        override fun start() = Unit
        override fun stop() = Unit
        override fun logout() = Unit
    }

    /** The live links by kind ("mac", "box"): the debug hooks reach them (`Hooks`). */
    val links = java.util.concurrent.ConcurrentHashMap<String, DemoLink>()
    /** The Mac's answer to the last log ask: its length in characters, or -1 before one. */
    @Volatile var logsRead = -1

    override val dialer = NodeDialer { device, _, _ ->
        val dir = if (device.kind == NodeKind.MAC) "mac" else "box"
        DemoLink(device, dir).also { links[dir] = it }
    }

    private fun asset(path: String): JsonObject? = runCatching {
        Json.parseToJsonElement(context.assets.open("demo/$path").bufferedReader().readText()).jsonObject
    }.getOrNull()

    /** One device's link: its welcome, snapshot and attention at once; a transcript when asked; every command ok. */
    inner class DemoLink(device: Device, private val dir: String) : LinkSession {
        private val channel = Channel<ByteArray>(Channel.UNLIMITED)
        private val end = CompletableDeferred<String>()
        override val incoming get() = channel
        override val ended: Deferred<String> get() = end
        override val binding = ByteArray(32) { 7 }
        override val peer = NetClientSession.State.Established.Peer(device, listOf("read", "ask", "run"), false, byteArrayOf(4, 2), null, null)
        override var lastInbound = System.currentTimeMillis()

        /** The snapshot as it stands: a send to a working chat queues behind its turn (`queued`). */
        private var snapshot: JsonObject? = when (scenario) {
            "waiting" -> null
            "no-windows" -> buildJsonObject { put("t", "snapshot"); put("rev", 1); put("windows", kotlinx.serialization.json.JsonArray(emptyList())); put("chats", kotlinx.serialization.json.JsonArray(emptyList())) }
            else -> asset("$dir/snapshot.json")
        }

        init {
            if (scenario != "waiting") asset("$dir/welcome.json")?.let(::push)
            snapshot?.let(::push)
            asset("$dir/attn.state.json")?.let(::push)
        }

        /** As a Mac would: ask for the phone's log (`logs.get`), from the start. */
        fun askLogs() = push(buildJsonObject { put("t", "logs.get"); put("id", "demo-logs"); put("offset", 0) })

        fun push(m: JsonObject) {
            lastInbound = System.currentTimeMillis()
            channel.trySend(m.toString().toByteArray())
        }

        override fun send(payload: ByteArray): Boolean {
            val m = runCatching { Json.parseToJsonElement(payload.decodeToString()).jsonObject }.getOrNull() ?: return true
            val t = (m["t"] as? JsonPrimitive)?.content
            val id = (m["id"] as? JsonPrimitive)?.content
            when (t) {
                "tx.open" -> {
                    val chat = (m["chatId"] as? JsonPrimitive)?.content ?: return true
                    push(asset("$dir/tx-$chat.json") ?: buildJsonObject {
                        put("t", "tx.page"); put("chatId", chat); put("txRev", 1); put("hasEarlier", false)
                        put("entries", kotlinx.serialization.json.JsonArray(emptyList())); put("turns", kotlinx.serialization.json.JsonArray(emptyList()))
                    })
                }
                "cmd" -> if (id != null) {
                    val cmd = m["cmd"] as? JsonObject
                    if ((cmd?.get("type") as? JsonPrimitive)?.content == "chat.send") queueIfWorking((cmd["chatId"] as? JsonPrimitive)?.content)
                    push(buildJsonObject { put("t", "result"); put("id", id); put("ok", true) })
                }
                // An upload: taken, as the Mac's would be.
                "blob.put.end" -> (m["uploadId"] as? JsonPrimitive)?.content?.let { upload ->
                    push(buildJsonObject { put("t", "result"); put("id", "blob.put:$upload"); put("ok", true); put("blobId", "demo-$upload") })
                }
                "logs.chunk" -> logsRead = (m["total"] as? JsonPrimitive)?.content?.toIntOrNull() ?: -1
            }
            return true
        }

        /** A message to a chat whose turn runs waits behind it: its `queued` goes up by one, as a delta. */
        private fun queueIfWorking(chatId: String?) {
            val snap = snapshot ?: return
            val chats = (snap["chats"] as? kotlinx.serialization.json.JsonArray)?.map { it as JsonObject } ?: return
            val chat = chats.firstOrNull { (it["id"] as? JsonPrimitive)?.content == chatId } ?: return
            if ((chat["running"] as? JsonPrimitive)?.content != "true") return
            val queued = ((chat["queued"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0) + 1
            val updated = JsonObject(chat + ("queued" to JsonPrimitive(queued)))
            val rev = ((snap["rev"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 1) + 1
            snapshot = JsonObject(snap + mapOf("rev" to JsonPrimitive(rev), "chats" to kotlinx.serialization.json.JsonArray(chats.map { if (it === chat) updated else it })))
            push(buildJsonObject { put("t", "delta"); put("rev", rev); put("chats", kotlinx.serialization.json.JsonArray(listOf(updated))) })
        }

        override fun ping(): Deferred<Unit> = CompletableDeferred(Unit)
        override fun close(reason: String) {
            if (end.complete(reason)) channel.close()
        }
    }
}
