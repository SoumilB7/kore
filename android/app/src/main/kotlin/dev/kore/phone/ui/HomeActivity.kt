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
    private data class Look(val cue: Cue?, val devices: List<Device>, val update: Update?, val offline: Boolean = false)
    private data class Cue(val count: Int, val title: String, val node: String, val nodeName: String, val chat: String?)
    private data class Device(
        val id: String, val name: String, val fact: String, val up: Boolean, val mac: Boolean, val dot: Int, val action: RowAction? = null,
        /** A login on it is also on another device (a Mac's snapshot says so): an amber point by its name. */
        val alsoOn: Boolean = false,
    )
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
            addView(label("Kore").apply { type(Type.Title) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(barIcon(dev.kore.phone.R.drawable.i_gear, "Settings").apply {
                setOnClickListener { startActivity(Intent(this@HomeActivity, SettingsActivity::class.java)) }
                pressFill(null, Tone.l2, 24)
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

    /** Whether this phone has a network at all (none: Home says the phone is offline). */
    private fun phoneOnline(): Boolean {
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /** Home draws again when the phone's network comes or goes. */
    private val netWatch = object : android.net.ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: android.net.Network) = runOnUiThread { render() }
        override fun onLost(network: android.net.Network) = runOnUiThread { render() }
    }

    override fun onResume() {
        super.onResume()
        runCatching { getSystemService(android.net.ConnectivityManager::class.java)?.registerDefaultNetworkCallback(netWatch) }
    }

    override fun onPause() {
        runCatching { getSystemService(android.net.ConnectivityManager::class.java)?.unregisterNetworkCallback(netWatch) }
        super.onPause()
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
        look.cue?.let { cue -> content.addView(rows.row(cue) { needYou(cue) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(16), dp(4), dp(16), 0) }) }
        if (look.devices.isNotEmpty()) {
            content.addView(sectionLabel("Devices", first = look.cue == null), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(16), 0, dp(16), 0) })
            content.addView(grouped(look.devices.map { d -> rows.row(d) { deviceRow(d) } }), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(16), 0, dp(16), 0) })
        }
        if (look.devices.isEmpty()) content.addView(emptyState(R.drawable.i_laptop, "No devices yet", "On your Mac, open Kore's Devices and press +. This phone shows up there."))
        // The phone itself offline (spec §6): its own state above the devices it can't reach.
        if (look.offline && look.devices.isNotEmpty()) content.addView(emptyState(R.drawable.i_wifi_off, "This phone is offline", "Your chats are where you left them. Kore goes on once you're back."), 0)
        (Updates.status.value as? Updates.Status.Available)?.let { st ->
            // "Update" (spec §6): one grouped row; from a Mac, Install downloads, checks and installs it.
            val mac = look.update?.mac
            val install = label(if (mac != null) "Install" else "Open").apply {
                type(Type.Label); setTextColor(Tone.accent); setPadding(dp(12), dp(8), dp(12), dp(8))
            }
            val go: () -> Unit = if (mac != null) ({ kore.scope.launch { Updates.install(kore, st.offer) }; Unit }) else ({ startActivity(Intent(this, SettingsActivity::class.java)) })
            content.addView(sectionLabel("Update"), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(16), 0, dp(16), 0) })
            content.addView(grouped(listOf(groupRow(R.drawable.i_download, "Kore ${st.offer.version}", if (mac != null) "From $mac" else "In Settings", iconTint = Tone.accent, end = install, go = go))),
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(16), 0, dp(16), 0) })
        }
        rows.done()
    }

    private fun look(nodes: List<Triple<NodeClient, NodeMachine.State, JsonObject?>>): Look {
        // Only a device that's up (or just reconnecting) still has chats waiting; a removed or denied
        // Mac's last snapshot says nothing about now.
        val waiting = nodes.filter { (_, s, _) -> s == NodeMachine.State.Up || s == NodeMachine.State.Connecting }
            .flatMap { (n, _, snap) -> snap?.objs("chats").orEmpty().filter { it.str("state") == "needsYou" }.map { n to it } }
        val cue = waiting.firstOrNull()?.let { (n, chat) -> Cue(waiting.size, chat.str("title") ?: "a chat", n.id.toString(), n.name, chat.str("id")) }
        // Devices holding a login also held on another device, as each Mac says (link 1.14).
        val doubled = nodes.flatMap { (_, _, snap) -> snap?.obj("mac")?.strs("alsoOn").orEmpty() }.map { it.lowercase() }.toSet()
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
            Device(n.id.toString(), n.name, fact, up, n.device.value.kind == NodeKind.MAC, nodeLook(s).second, trouble?.action, n.id.toString().lowercase() in doubled)
        }
        val update = (Updates.status.value as? Updates.Status.Available)?.let { Update(it.offer, Updates.fromMac(kore, it.offer)) }
        return Look(cue, devices, update, offline = !phoneOnline())
    }

    /** One cue (mockup E8 .need), amber as chats that need you are everywhere: how many wait, the first one's title and device; a tap opens it. */
    private fun needYou(cue: Cue): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), dp(12), dp(16), dp(12))
        addView(point(Tone.warn), LinearLayout.LayoutParams(dp(7), dp(7)).apply { marginEnd = dp(12) })
        addView(column().apply {
            addView(label(if (cue.count == 1) "1 needs you" else "${cue.count} need you").apply { type(Type.BodyMedium); setTextColor(Tone.warn) })
            addView(label("${cue.title} · ${cue.nodeName}").apply {
                type(Type.Callout); setTextColor(Tone.dim)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(ImageView(this@HomeActivity).apply {
            setImageResource(R.drawable.i_chevron)
            imageTintList = android.content.res.ColorStateList.valueOf(Tone.warn)
        }, LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginStart = dp(8) })
        tag = "need you"
        contentDescription = "${cue.count} need you: ${cue.title} on ${cue.nodeName}"
        setOnClickListener {
            startActivity(Intent(this@HomeActivity, ChatActivity::class.java).putExtra("node", cue.node).putExtra("chat", cue.chat))
        }
        pressFill(Tone.warnFill, Tone.warnPressed, Radius.row, Tone.warnEdge)
    }

    /** A device in the grouped list: its icon, name, fact, a point in its state's colour, a chevron. */
    private fun deviceRow(d: Device): View = groupRow(
        icon = if (d.mac) R.drawable.i_laptop else R.drawable.i_server,
        title = d.name, second = d.fact,
        titleColor = if (d.up) Tone.text else Tone.faint,
        secondColor = if (d.action != null) Tone.accent else Tone.dim,
        iconTint = if (d.up) Tone.dim else Tone.faint,
        end = point(d.dot), chevron = d.action == null, titleMark = if (d.alsoOn) Tone.warn else null,
    ) {
        val node = latest.firstOrNull { it.first.id.toString() == d.id }?.first
        if (d.action != null && node != null) rowAction(node, d.action) else startActivity(Intent(this@HomeActivity, DeviceActivity::class.java).putExtra("node", d.id))
    }.apply {
        contentDescription = "${d.name}: ${d.fact}" + if (d.alsoOn) ". A login on it is also on another device" else ""
        tag = "device ${d.name}"
    }

    private fun toJoin() {
        startActivity(Intent(this, JoinActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}
