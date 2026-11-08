package dev.kore.phone.ui

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeMachine
import dev.kore.link.trust.NodeKind
import dev.kore.phone.R
import dev.kore.phone.kore
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * Home (korenet-first-connect.html E8): the devices this phone reaches as flat rows, and one
 * "N need you" cue while something waits, leading to the first. The directory came with the Mac's
 * welcome, so every box the Mac knows is already listed. A redraw happens only when what Home shows
 * changed (a chat's words elsewhere don't redraw it), and unchanged rows keep their views.
 */
class HomeActivity : Activity() {
    private lateinit var content: LinearLayout
    private var watch: Job? = null
    private val rows = RowCache()
    private var shown: Look? = null
    private var latest: List<Triple<NodeClient, NodeMachine.State, JsonObject?>> = emptyList()

    /** Everything Home draws; equal looks draw nothing. */
    private data class Look(val cue: Cue?, val devices: List<Device>, val update: Update?)
    private data class Cue(val count: Int, val title: String, val node: String, val nodeName: String, val chat: String?)
    private data class Device(val id: String, val name: String, val fact: String, val up: Boolean, val mac: Boolean, val dot: Int, val action: RowAction? = null)
    /** An update ready: from a Mac (one tap installs it) or from the release page (Settings). */
    private data class Update(val offer: Any, val mac: String?)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!kore.mesh.joined) return toJoin()
        val root = column()
        root.addView(LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPadding(dp(20), 0, dp(6), 0)
            addView(label("Kore", 17f, bold = true), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(label("⚙︎", 18f, K.dim).apply {
                gravity = Gravity.CENTER
                contentDescription = "Settings"
                setOnClickListener { startActivity(Intent(this@HomeActivity, SettingsActivity::class.java)) }
                pressable(24)
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
        })
        content = column().apply { setPadding(0, dp(4), 0, dp(16)) }
        root.addView(ScrollView(this).apply { addView(content) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onStart() {
        super.onStart()
        if (isFinishing) return
        if (!kore.mesh.joined) return toJoin()
        kore.scope.launch { Updates.check(this@HomeActivity, quiet = true) }
        watch = kore.scope.launch {
            kore.mesh.nodes.flatMapLatest { nodes ->
                if (nodes.isEmpty()) flowOf(emptyList()) else combine(nodes.map { n -> n.state.combine(n.snapshot) { s, snap -> Triple(n, s, snap) } }) { it.toList() }
            }.combine(Updates.status) { nodes, _ -> nodes }.collect { nodes -> runOnUiThread { latest = nodes; render() } }
        }
    }

    override fun onStop() {
        watch?.cancel()
        super.onStop()
    }

    private fun render() {
        // A Mac that's up may have a newer phone app (asked once per Mac per run, only while open).
        for ((n, s, _) in latest) if (s == NodeMachine.State.Up && n.device.value.kind == NodeKind.MAC) kore.scope.launch { Updates.checkMac(kore, n) }
        val look = look(latest)
        if (look == shown) return
        shown = look
        content.removeAllViews()
        look.cue?.let { cue -> content.addView(rows.row(cue) { needYou(cue) }) }
        look.devices.forEach { d -> content.addView(rows.row(d) { deviceRow(d) }) }
        if (look.devices.isEmpty()) content.addView(quietLine("No devices", "Settings ›") { startActivity(Intent(this, SettingsActivity::class.java)) })
        (Updates.status.value as? Updates.Status.Available)?.let { st ->
            // One line whichever source: from a Mac, one tap downloads, checks and installs it.
            val mac = look.update?.mac
            if (mac != null) content.addView(quietLine("Update ready", "from $mac") { kore.scope.launch { Updates.install(kore, st.offer) } })
            else content.addView(quietLine("An update is ready", "Settings ›") { startActivity(Intent(this, SettingsActivity::class.java)) })
        }
        rows.done()
    }

    private fun look(nodes: List<Triple<NodeClient, NodeMachine.State, JsonObject?>>): Look {
        // Only a device that's up (or just reconnecting) still has chats waiting; a removed or denied
        // Mac's last snapshot says nothing about now.
        val waiting = nodes.filter { (_, s, _) -> s == NodeMachine.State.Up || s == NodeMachine.State.Connecting }
            .flatMap { (n, _, snap) -> snap?.objs("chats").orEmpty().filter { it.str("state") == "needsYou" }.map { n to it } }
        val cue = waiting.firstOrNull()?.let { (n, chat) -> Cue(waiting.size, chat.str("title") ?: "a chat", n.id.toString(), n.name, chat.str("id")) }
        val devices = nodes.map { (n, state, snap) ->
            val s = shownState(state, kore.mesh.networkOn)
            val up = s == NodeMachine.State.Up
            val chats = snap?.objs("chats").orEmpty()
            val running = chats.count { it.str("state") == "working" }
            val mac = kore.mesh.macFor(n)
            val trouble = troubleWords(s, n.device.value.kind == NodeKind.MAC, n.name, mac)
            val fact = when {
                trouble != null -> trouble.fact
                up || (s == NodeMachine.State.Connecting && snap != null) -> (if (chats.size == 1) "1 chat" else "${chats.size} chats") + if (running > 0) " · $running running" else ""
                s is NodeMachine.State.Away -> awayFact(s.why, n.name, mac, n.lastSeen)
                else -> stateWords(s, mac).first.removePrefix("● ").lowercase()
            }
            Device(n.id.toString(), n.name, fact, up, n.device.value.kind == NodeKind.MAC, nodeLook(s).second, trouble?.action)
        }
        val update = (Updates.status.value as? Updates.Status.Available)?.let { Update(it.offer, Updates.fromMac(kore, it.offer)) }
        return Look(cue, devices, update)
    }

    /** One cue (mockup E8 .need), amber as chats that need you are everywhere: how many wait, the first one's title and device; a tap opens it. */
    private fun needYou(cue: Cue): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(14), 0, dp(14), 0)
        background = rounded(Tone.warnFill, 14, Tone.warnEdge)
        addView(label((if (cue.count == 1) "1 needs you" else "${cue.count} need you"), 14f, K.warn).apply { typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL) })
        addView(label("${cue.title} · ${cue.nodeName}", 12.5f, K.dim).apply {
            gravity = Gravity.END
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(dp(8), 0, 0, 0)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        tag = "need you"
        contentDescription = "${cue.count} need you: ${cue.title} on ${cue.nodeName}"
        setOnClickListener {
            startActivity(Intent(this@HomeActivity, ChatActivity::class.java).putExtra("node", cue.node).putExtra("chat", cue.chat))
        }
        pressable(12)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(20), dp(4), dp(20), dp(12)) }
    }

    /** A device (mockup E8 .pr): a flat row under a hairline, its glyph, name, one fact under it, and a status dot. */
    private fun deviceRow(d: Device): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(View(context).apply { setBackgroundColor(K.line) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1))
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(13), dp(20), dp(13))
            addView(ImageView(this@HomeActivity).apply {
                setImageResource(if (d.mac) R.drawable.ic_mac else R.drawable.ic_box)
                if (!d.up) setColorFilter(K.faint)
            }, LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginEnd = dp(12) })
            addView(column().apply {
                addView(label(d.name, 15f, if (d.up) K.text else K.faint).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
                addView(label(d.fact, 12f, if (d.action != null) K.accent else K.faint).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END })
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(View(this@HomeActivity).apply { background = rounded(d.dot, 4) }, LinearLayout.LayoutParams(dp(7), dp(7)).apply { marginStart = dp(12) })
        })
        contentDescription = "${d.name}: ${d.fact}"
        tag = "device ${d.name}"
        // A device that won't take this phone: the row does its one action.
        setOnClickListener {
            val node = latest.firstOrNull { it.first.id.toString() == d.id }?.first
            if (d.action != null && node != null) rowAction(node, d.action) else startActivity(Intent(this@HomeActivity, DeviceActivity::class.java).putExtra("node", d.id))
        }
        pressable(0)
    }

    /** One quiet line at the list's end: what it is, and the one thing to do. */
    private fun quietLine(text: String, action: String, go: () -> Unit): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(20), 0, dp(20), 0)
        addView(label(text, 13f, K.dim))
        addView(label("  ·  ", 13f, K.faint))
        addView(label(action, 13f, K.accent))
        contentDescription = "$text. $action"
        setOnClickListener { go() }
        pressable(0)
    }

    private fun toJoin() {
        startActivity(Intent(this, JoinActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}
