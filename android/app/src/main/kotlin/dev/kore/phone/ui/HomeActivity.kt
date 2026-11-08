package dev.kore.phone.ui

import android.app.Activity
import android.content.Intent
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
 * Home (korenet-first-connect.html E8): the devices this phone reaches, and one "N need you" cue
 * while something waits, leading to the first. The directory came with the Mac's welcome, so every
 * box the Mac knows is already listed.
 */
class HomeActivity : Activity() {
    private lateinit var content: LinearLayout
    private var watch: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!kore.mesh.joined) return toJoin()
        val root = column()
        root.addView(LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            setPadding(dp(20), dp(4), dp(4), dp(4))
            addView(label("Kore", 20f, bold = true), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(label("⚙", 20f, K.dim).apply {
                gravity = Gravity.CENTER
                contentDescription = "Settings"
                setOnClickListener { startActivity(Intent(this@HomeActivity, SettingsActivity::class.java)) }
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
        })
        content = column(16)
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
            }.collect { rows -> runOnUiThread { render(rows) } }
        }
    }

    override fun onStop() {
        watch?.cancel()
        super.onStop()
    }

    private fun render(rows: List<Triple<NodeClient, NodeMachine.State, JsonObject?>>) {
        content.removeAllViews()
        val waiting = rows.flatMap { (n, _, snap) -> snap?.objs("chats").orEmpty().filter { it.str("state") == "needsYou" }.map { n to it } }
        if (waiting.isNotEmpty()) content.addView(needYou(waiting))
        for ((n, s, snap) in rows) content.addView(deviceRow(n, s, snap))
        if (Updates.status.value is Updates.Status.Available) content.addView(label("An update is ready · Settings", 13f, K.accent).apply {
            setPadding(dp(4), dp(14), 0, 0)
            setOnClickListener { startActivity(Intent(this@HomeActivity, SettingsActivity::class.java)) }
        })
    }

    /** One cue: how many chats wait, the first one's title and device; a tap opens it. */
    private fun needYou(waiting: List<Pair<NodeClient, JsonObject>>): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(14), dp(10), dp(14), dp(10))
        background = rounded(android.graphics.Color.parseColor("#2A2618"), 12, android.graphics.Color.parseColor("#4A4128"))
        val (node, chat) = waiting.first()
        addView(label("${waiting.size} need you", 14f, K.warn, bold = true))
        addView(label("  ${chat.str("title") ?: "a chat"} · ${node.name}", 13f, K.dim).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        tag = "need you"
        setOnClickListener {
            startActivity(Intent(this@HomeActivity, ChatActivity::class.java).putExtra("node", node.id.toString()).putExtra("chat", chat.str("id")))
        }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) }
    }

    /** A device: its glyph, name, one fact under it, and a status dot. */
    private fun deviceRow(n: NodeClient, s: NodeMachine.State, snap: JsonObject?): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = rounded(K.surface)
        val up = s == NodeMachine.State.Up
        addView(ImageView(this@HomeActivity).apply {
            setImageResource(if (n.device.value.kind == NodeKind.MAC) R.drawable.ic_mac else R.drawable.ic_box)
            alpha = if (up) 1f else 0.6f
        }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(12) })
        val chats = snap?.objs("chats").orEmpty()
        val running = chats.count { it.str("state") == "working" }
        val fact = when {
            up || (s == NodeMachine.State.Connecting && snap != null) -> "${chats.size} chats" + if (running > 0) " · $running running" else ""
            s is NodeMachine.State.Away -> lastSeenWords(n.lastSeen) ?: stateWords(s).first.removePrefix("● ").lowercase()
            else -> stateWords(s).first.removePrefix("● ").lowercase()
        }
        addView(column().apply {
            addView(label(n.name, 15f, if (up) K.text else K.dim).apply { maxLines = 1 })
            addView(label(fact, 12f, K.faint).apply { maxLines = 1 })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val (_, color) = nodeLook(s)
        addView(View(this@HomeActivity).apply { background = rounded(color, 4) }, LinearLayout.LayoutParams(dp(8), dp(8)))
        contentDescription = "${n.name}: $fact"
        tag = "device ${n.name}"
        setOnClickListener { startActivity(Intent(this@HomeActivity, DeviceActivity::class.java).putExtra("node", n.id.toString())) }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) }
    }

    private fun toJoin() {
        startActivity(Intent(this, JoinActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}
