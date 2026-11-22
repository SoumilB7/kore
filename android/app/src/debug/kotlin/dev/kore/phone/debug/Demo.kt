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
 * attn.state, and `tx-<chatId>.json` per chat); every command is answered ok, but a copy's
 * (`chat.copyVia`) as [Demo]'s scenario says.
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
 * snapshot); `no-windows` the Mac has none open; `no-devices` this phone knows none; `asleep` the
 * Mac says it's going to sleep; `cold` each dial takes 4 s (a tailnet starting cold); `usage-near` its logins past 80 % (amber), `usage-limit` at a
 * limit (red); `copy-slow` a copy takes 4 s, `copy-refused` the Mac refuses one, `copy-drop` the
 * link goes as one is asked (once) and the next asks how it ended, `copy-lost` the link goes and
 * Kore on the Mac doesn't know, `copy-away` the Mac answers no dial after the first, `no-copy` a
 * Mac from before copies; `cards` long permission and plan cards. Each device pushes its logins' usage (link 1.14) with resets from now.
 */
class Demo(private val context: Context, private val scenario: String = "") : StandIn {
    private val studio = Device(UUID.fromString("5D1A0000-2B3C-4D5E-8F60-718293A4B5C6"), "Studio", NodeKind.MAC, ByteArray(91) { 3 }, listOf("nodekey:studio"), "studio.tail.ts.net.")
    private val mac = Device(UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02"), "MacBook", NodeKind.MAC, ByteArray(91) { 1 }, listOf("nodekey:mac"), "macbook.tail.ts.net.")
    private val box = Device(UUID.fromString("0E4C2A91-5B7D-4F3E-9A61-2D8C7B5E1F04"), "mybox", NodeKind.BOX, ByteArray(91) { 2 }, listOf("nodekey:box"), "mybox.tail.ts.net.",
        via = setOf(UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02")))
    override val devices = when { scenario == "no-devices" -> emptyList(); scenario.startsWith("copy") -> listOf(mac, box, studio); else -> listOf(mac, box) }

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
        // `cold`: every dial takes as long as the phone's tailnet starting from cold.
        if (scenario == "cold") kotlinx.coroutines.delay(4_000)
        val dir = if (device.kind == NodeKind.MAC) "mac" else "box"
        if (scenario == "copy-away" && dir == "mac" && links.containsKey(dir)) throw java.io.IOException("away")
        DemoLink(device, dir).also { if (device !== studio) links[dir] = it }
    }

    /** Copies asked and dropped so far (`copy-drop`, `copy-lost`). */
    private val copied = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private fun asset(path: String): JsonObject? = runCatching {
        Json.parseToJsonElement(context.assets.open("demo/$path").bufferedReader().readText()).jsonObject
    }.getOrNull()

    /** One device's link: its welcome, snapshot and attention at once; a transcript when asked; every command ok. */
    inner class DemoLink(private val device: Device, private val dir: String) : LinkSession {
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
            else -> asset("$dir/snapshot.json")?.let { withUsage(it, dir) }?.let { if (scenario == "cards" && dir == "mac") withCards(it) else it }
        }

        init {
            // `asleep`: the Mac says it's going to sleep as soon as it's reached.
            if (scenario == "asleep" && dir == "mac") { end.complete("sleep"); channel.close() }
            if (scenario != "waiting") asset("$dir/welcome.json")?.let { w ->
                val named = if (device.id == studio.id) JsonObject(w + ("host" to buildJsonObject { put("name", "Studio"); put("koreVersion", "0.3.10") })) else w
                push(if (scenario == "no-copy") JsonObject(named + ("caps" to kotlinx.serialization.json.JsonArray((named["caps"] as kotlinx.serialization.json.JsonArray).filter { it != JsonPrimitive("copyVia") }))) else named)
            }
            snapshot?.let(::push)
            asset("$dir/attn.state.json")?.let(::push)
        }

        /**
         * As a running turn would (`STREAM`): a step, then an answer that streams in [pieces]
         * deltas, every [every] ms, a paragraph per ten, so the transcript grows past the screen.
         */
        fun stream(chat: String, pieces: Int = 60, every: Long = 150) = Thread {
            val turn = "turn-demo-${System.currentTimeMillis()}"
            fun delta(e: JsonObject) = push(buildJsonObject {
                put("t", "tx.delta"); put("chatId", chat)
                put("upserts", kotlinx.serialization.json.JsonArray(listOf(e)))
            })
            delta(buildJsonObject {
                put("id", "$turn-tool"); put("kind", "tool"); put("done", true); put("turn", turn)
                put("tool", buildJsonObject { put("name", "Read"); put("summary", "src/total.ts") })
            })
            val words = ("Rounding once on the total keeps every cent: the per-line rounding dropped a cent " +
                "whenever several lines rounded down together, which long carts do often.").split(' ')
            val paragraphs = ArrayList<String>()
            for (i in 0 until pieces) {
                if (i % 10 == 0) paragraphs += "${i / 10 + 1}."
                paragraphs[paragraphs.size - 1] = paragraphs.last() + " " + words[i % words.size]
                delta(buildJsonObject {
                    put("id", "$turn-answer"); put("kind", "answer"); put("done", i == pieces - 1); put("turn", turn)
                    put("text", paragraphs.joinToString("\n\n"))
                    put("doc", kotlinx.serialization.json.JsonArray(paragraphs.map { p ->
                        buildJsonObject {
                            put("k", "paragraph")
                            put("spans", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("text", p) })))
                        }
                    }))
                })
                Thread.sleep(every)
            }
        }.start()

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
                    // Every command the phone sends, for the emulator's checks (`logcat -s KoreDemo`).
                    android.util.Log.i("KoreDemo", "$dir ${cmd ?: "{}"}")
                    if ((cmd?.get("type") as? JsonPrimitive)?.content == "chat.copyVia") { copyVia(id, cmd); return true }
                    if ((cmd?.get("type") as? JsonPrimitive)?.content == "chat.send") queueIfWorking((cmd["chatId"] as? JsonPrimitive)?.content)
                    push((if (dir == "box") boxFolders(id, cmd) else null) ?: buildJsonObject { put("t", "result"); put("id", id); put("ok", true) })
                    cmd?.let(::closeIfAsked)
                }
                // An upload: taken, as the Mac's would be.
                "blob.put.end" -> (m["uploadId"] as? JsonPrimitive)?.content?.let { upload ->
                    push(buildJsonObject { put("t", "result"); put("id", "blob.put:$upload"); put("ok", true); put("blobId", "demo-$upload") })
                }
                // History: a few closed chats, filtered by the search, newest first (Today, This week, Earlier).
                "history.list" -> {
                    val q = (m["query"] as? JsonPrimitive)?.content.orEmpty().lowercase()
                    val now = System.currentTimeMillis()
                    val all = listOf(
                        Triple("Fix the login redirect", "claude", now - 2 * 3_600_000L),
                        Triple("Rate limit banner copy", "codex", now - 5 * 3_600_000L),
                        Triple("Box sync, first pass", "claude", now - 3 * 86_400_000L),
                        Triple("Tables on narrow phones", "claude", now - 4 * 86_400_000L),
                        Triple("0.2.9 release notes", "codex", now - 20 * 86_400_000L),
                    ).filter { q.isEmpty() || it.first.lowercase().contains(q) }
                    push(buildJsonObject {
                        put("t", "history.page"); put("id", id); put("windowId", (m["windowId"] as? JsonPrimitive)?.content ?: ""); put("more", false)
                        put("sessions", kotlinx.serialization.json.JsonArray(all.mapIndexed { i, (title, provider, at) ->
                            buildJsonObject { put("id", "s$i"); put("title", title); put("provider", provider); put("updatedAt", at); put("archived", false); put("open", false) }
                        }))
                    })
                }
                // A file's changes in a turn.
                "diff.get" -> push(buildJsonObject {
                    put("t", "diff.hunks"); put("id", id); put("path", (m["path"] as? JsonPrimitive)?.content ?: "src/total.ts"); put("more", false)
                    put("hunks", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject {
                        put("oldStart", 12); put("newStart", 12)
                        put("lines", kotlinx.serialization.json.JsonArray(listOf(
                            " export const total = (lines: Line[]) =>",
                            "-  lines.reduce((sum, l) => sum + round(l.price * l.qty), 0)",
                            "+  round(lines.reduce((sum, l) => sum + l.price * l.qty, 0))",
                            " ",
                            "+// Round once, on the total: per-line rounding lost a cent on long carts.",
                        ).map { JsonPrimitive(it) }))
                    })))
                })
                // A sent image (thumb or full alike): the demo's own picture, in one piece.
                "blob.get" -> push(buildJsonObject {
                    val bytes = context.assets.open("demo/pasted.png").use { it.readBytes() }
                    put("t", "blob.chunk"); put("id", id); put("mime", "image/png"); put("offset", 0); put("total", bytes.size)
                    put("data", java.util.Base64.getEncoder().encodeToString(bytes))
                })
                "logs.chunk" -> logsRead = (m["total"] as? JsonPrimitive)?.content?.toIntOrNull() ?: -1
            }
            return true
        }

        /** A copy's answer, by scenario: done (after 4 s: `copy-slow`), refused, or the link going first. */
        private fun copyVia(id: String, cmd: JsonObject) {
            fun result(code: String? = null, message: String? = null) = push(buildJsonObject {
                put("t", "result"); put("id", id); put("ok", code == null); code?.let { put("code", it) }; message?.let { put("message", it) }
            })
            val asked = cmd["copy"] as? JsonObject
            val first = copied.add((asked?.get("id") as? JsonPrimitive)?.content ?: "")
            when (scenario) {
                "copy-slow" -> Thread { Thread.sleep(4_000); result() }.start()
                "copy-refused" -> result("busy", "Can't reach mybox · nothing changed")
                "copy-drop", "copy-away" -> if (first) Thread { Thread.sleep(1_500); close("gone") }.start() else result()
                "copy-lost" -> if (first) Thread { Thread.sleep(1_500); close("gone") }.start()
                else result("gone.session", "Kore doesn't know if that was copied · look there before copying again")
                else -> result()
            }
        }

        /** A permission whose command runs past the card, and a plan long enough to be cut. */
        private fun withCards(snap: JsonObject): JsonObject {
            fun actions(vararg a: Triple<String, String, String>) = kotlinx.serialization.json.JsonArray(a.map { (id, label, style) ->
                buildJsonObject { put("id", id); put("label", label); put("style", style) } })
            fun card(id: String, kind: String, title: String, detail: String, body: String, acts: kotlinx.serialization.json.JsonArray) = kotlinx.serialization.json.JsonArray(listOf(buildJsonObject {
                put("id", id); put("kind", kind); put("title", title); put("detail", detail); put("body", body); put("digest", "ZGVtbw=="); put("actions", acts)
            }))
            val command = (1..40).joinToString(" && \\\n  ") { "npm test -- checkout/case-$it.spec.ts --runInBand" }
            val plan = "## Round once, on the total\n\n" + (1..18).joinToString("\n") { "$it. Step $it: change `src/total$it.ts` so the line's price is kept exact, then check the cart it belongs to." }
            val cards = mapOf(
                "6E1F0C2A-0000-4000-8000-000000000001" to card("toolu_long", "permission", "Bash", "Run a command", command, actions(Triple("allow", "Allow", "primary"), Triple("deny", "Deny", "destructive"))),
                "6E1F0C2A-0000-4000-8000-000000000004" to card("plan_01", "plan", "Ready to code?", "", plan, actions(Triple("approvePlan", "Approve", "primary"), Triple("keepPlanning", "Keep planning", "neutral"))),
            )
            val chats = (snap["chats"] as kotlinx.serialization.json.JsonArray).map { c ->
                val chat = c as JsonObject
                cards[(chat["id"] as? JsonPrimitive)?.content]?.let { JsonObject(chat + mapOf("cards" to it, "state" to JsonPrimitive("needsYou"))) } ?: chat
            }
            return JsonObject(snap + ("chats" to kotlinx.serialization.json.JsonArray(chats)))
        }

        /** The box's home as a phone browses it (`fs.list`, folders only), with what it serves and what's made here. */
        private val home = "/home/soumil"
        private val tree = mutableMapOf(
            home to mutableListOf("Code", "Documents", "notes", "Onfinance", "Platform", "Test1"),
            "$home/Code" to mutableListOf("kore", "kore-host", "scratch"),
            "$home/Documents" to mutableListOf("invoices"),
        )
        private val served = linkedMapOf("$home/Onfinance" to "w_onfinance", "$home/Test1" to "w_test1", "$home/Platform" to "w_platform")

        /** kore-host's answers to a phone's folder browser: `fs.list`, `fs.mkdir`, `folders.list`, `folder.add`; else null (a plain ok). */
        private fun boxFolders(id: String, cmd: JsonObject?): JsonObject? {
            fun str(k: String) = (cmd?.get(k) as? JsonPrimitive)?.content
            fun ok(body: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) = buildJsonObject { put("t", "result"); put("id", id); put("ok", true); body() }
            return when (str("type")) {
                "fs.list" -> {
                    val at = str("path") ?: home
                    ok {
                        put("path", at)
                        put("entries", kotlinx.serialization.json.JsonArray(tree[at].orEmpty().sortedWith(String.CASE_INSENSITIVE_ORDER).map { buildJsonObject { put("name", it); put("kind", "dir") } }))
                    }
                }
                "fs.mkdir" -> {
                    val at = str("path") ?: return null
                    val names = tree.getOrPut(at.substringBeforeLast('/')) { mutableListOf() }
                    val name = at.substringAfterLast('/')
                    if (name in names) buildJsonObject { put("t", "result"); put("id", id); put("ok", false); put("code", "invalid"); put("message", "$name is already there.") }
                    else { names += name; tree[at] = mutableListOf(); ok { put("path", at) } }
                }
                "folders.list" -> ok { put("folders", kotlinx.serialization.json.JsonArray(served.map { (p, w) -> buildJsonObject { put("path", p); put("windowId", w) } })) }
                "folder.add" -> {
                    val at = str("path") ?: return null
                    val wid = served.getOrPut(at) { "w_" + at.substringAfterLast('/').lowercase().filter { it.isLetterOrDigit() } }
                    windowFor(at, wid)
                    ok { put("windowId", wid) }
                }
                else -> null
            }
        }

        /** A served folder's window, as kore-host shows one: added to the windows, as a delta. */
        private fun windowFor(path: String, wid: String) {
            val snap = snapshot ?: return
            val windows = (snap["windows"] as? kotlinx.serialization.json.JsonArray)?.map { it as JsonObject } ?: return
            if (windows.any { (it["id"] as? JsonPrimitive)?.content == wid }) return
            val made = buildJsonObject {
                put("id", wid); put("name", path.substringAfterLast('/')); put("path", "~" + path.removePrefix(home))
                put("tabs", kotlinx.serialization.json.JsonArray(emptyList()))
            }
            val kept = windows + made
            val rev = ((snap["rev"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 1) + 1
            snapshot = JsonObject(snap + mapOf("rev" to JsonPrimitive(rev), "windows" to kotlinx.serialization.json.JsonArray(kept)))
            push(buildJsonObject { put("t", "delta"); put("rev", rev); put("windows", kotlinx.serialization.json.JsonArray(kept)) })
        }

        /** A window or a chat closed, as the Mac or kore-host would: gone from the windows, as a delta. */
        private fun closeIfAsked(cmd: JsonObject) {
            val type = (cmd["type"] as? JsonPrimitive)?.content
            if (type != "window.close" && type != "chat.close") return
            val snap = snapshot ?: return
            val windows = (snap["windows"] as? kotlinx.serialization.json.JsonArray)?.map { it as JsonObject } ?: return
            fun str(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.content
            val gone: List<String>
            val kept: List<JsonObject>
            if (type == "window.close") {
                val window = windows.firstOrNull { str(it, "id") == str(cmd, "windowId") } ?: return
                gone = (window["tabs"] as? kotlinx.serialization.json.JsonArray).orEmpty().mapNotNull { str(it as JsonObject, "chatId") }
                kept = windows - window
            } else {
                val chat = str(cmd, "chatId") ?: return
                gone = listOf(chat)
                kept = windows.map { w ->
                    val tabs = (w["tabs"] as? kotlinx.serialization.json.JsonArray).orEmpty().filter { str(it as JsonObject, "chatId") != chat }
                    JsonObject(w + ("tabs" to kotlinx.serialization.json.JsonArray(tabs)))
                }
            }
            val chats = (snap["chats"] as? kotlinx.serialization.json.JsonArray).orEmpty().filter { str(it as JsonObject, "id") !in gone }
            val rev = ((snap["rev"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 1) + 1
            snapshot = JsonObject(snap + mapOf("rev" to JsonPrimitive(rev), "windows" to kotlinx.serialization.json.JsonArray(kept), "chats" to kotlinx.serialization.json.JsonArray(chats)))
            push(buildJsonObject {
                put("t", "delta"); put("rev", rev); put("windows", kotlinx.serialization.json.JsonArray(kept))
                put("removed", kotlinx.serialization.json.JsonArray(gone.map(::JsonPrimitive)))
            })
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

        /**
         * The device's CLIs with their logins' usage (`clis[].usage`), as a Mac or kore-host pushes
         * them: the Mac's two Claude logins and Codex; the box's Claude accounts (its first chat on
         * "ajinkya", `controls.login`) and Codex. Normal, near a limit or at one, by [scenario].
         */
        private fun withUsage(snap: JsonObject, dir: String): JsonObject {
            val now = System.currentTimeMillis()
            val hour = 3_600_000L
            fun limits(five: Int, fiveIn: Long, week: Int, weekIn: Long) = kotlinx.serialization.json.JsonArray(listOf(
                buildJsonObject { put("kind", "5h"); put("used", five); put("resetsAt", (now + fiveIn) / 60_000 * 60_000) },
                buildJsonObject { put("kind", "7d"); put("used", week); put("resetsAt", (now + weekIn) / 60_000 * 60_000) },
            ))
            fun login(id: String, email: String?, active: Boolean, plan: String?, limits: kotlinx.serialization.json.JsonArray?) = buildJsonObject {
                put("login", id); email?.let { put("email", it) }; put("active", active); plan?.let { put("plan", it) }
                put("limits", limits ?: kotlinx.serialization.json.JsonArray(emptyList()))
            }
            fun cli(provider: String, vararg logins: JsonObject) = buildJsonObject {
                put("provider", provider); put("models", kotlinx.serialization.json.JsonArray(emptyList())); put("effortScale", kotlinx.serialization.json.JsonArray(emptyList()))
                put("usage", kotlinx.serialization.json.JsonArray(logins.toList()))
            }
            val (claude, codex) = when (scenario) {
                "usage-near" -> limits(86, 2 * hour + 20 * 60_000, 81, 3 * 24 * hour) to limits(64, 3 * hour, 92, 2 * 24 * hour)
                "usage-limit" -> limits(100, hour + 40 * 60_000, 93, 3 * 24 * hour) to limits(100, 2 * hour + 5 * 60_000, 100, 4 * 24 * hour + 2 * hour)
                else -> limits(42, 2 * hour + 10 * 60_000, 61, 3 * 24 * hour) to limits(18, 4 * hour, 44, 5 * 24 * hour)
            }
            val clis = if (dir == "mac") listOf(
                cli("claude", login("main", "ku••••@••il.com", true, "Max", claude), login("work", "so••••@••rp.com", false, "Team", limits(12, 3 * hour, 30, 6 * 24 * hour))),
                cli("codex", login("main", "ku••••@••il.com", true, "Pro", codex)),
            ) else listOf(
                cli("claude", login("main", "ku••••@••il.com", true, "Max", limits(8, 4 * hour, 22, 6 * 24 * hour)), login("ajinkya", "aj••••@••il.com", false, "Max", claude)),
                cli("codex", login("main", "ku••••@••il.com", true, "Pro", codex)),
            )
            val chats = (snap["chats"] as? kotlinx.serialization.json.JsonArray)?.mapIndexed { i, c ->
                val chat = c as JsonObject
                if (dir == "box" && i == 0) JsonObject(chat + ("controls" to JsonObject(((chat["controls"] as? JsonObject) ?: JsonObject(emptyMap())) + ("login" to JsonPrimitive("ajinkya"))))) else chat
            }
            return JsonObject(snap + ("clis" to kotlinx.serialization.json.JsonArray(clis)) + (chats?.let { mapOf("chats" to kotlinx.serialization.json.JsonArray(it)) } ?: emptyMap()))
        }

        override fun ping(): Deferred<Unit> = CompletableDeferred(Unit)
        override fun close(reason: String) {
            if (end.complete(reason)) channel.close()
        }
    }
}
