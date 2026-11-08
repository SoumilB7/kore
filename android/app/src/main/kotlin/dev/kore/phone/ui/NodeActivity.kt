package dev.kore.phone.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.State
import dev.kore.phone.kore
import dev.kore.phone.nodeId
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * A screen that shows one device (its intent's `node`): a one-word state pill in the top bar,
 * content below, redrawn whenever the node's state or snapshot changes. The last snapshot shows at
 * once; "Reconnecting" only after 1.5 s of trying. Screens it opens stay on its device.
 */
abstract class NodeActivity : Activity() {
    protected lateinit var root: LinearLayout
    protected lateinit var content: LinearLayout
    private lateinit var banner: TextView
    /** The top bar's title: the device's, the window's or the chat's name. */
    protected lateinit var barTitle: TextView
    /** A small state dot at the end of the top bar; screens that have a state show it. */
    protected lateinit var barDot: android.view.View
    protected open val showsBack = true
    private var watch: Job? = null
    /** The device this screen shows. */
    protected val host: String? get() = nodeId
    protected val link: NodeClient? get() = kore.mesh.node(host)
    /** The node's state as of the last [render]. */
    protected var linkState: State? = null
    /** The device's name, from its welcome or its record. */
    protected var macName: String = "your Mac"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        macName = link?.name ?: macName
        root = column()
        root.addView(topBar())
        content = column(16)
        root.addView(body(), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    private fun topBar(): android.view.View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = android.view.Gravity.CENTER_VERTICAL
        setPadding(dp(4), dp(4), if (showsGear) dp(4) else dp(16), dp(4))
        minimumHeight = dp(56)
        if (showsBack) addView(label("‹", 30f, K.text).apply {
            gravity = android.view.Gravity.CENTER
            contentDescription = "Back"
            isClickable = true
            setOnClickListener { finish() }
        }, LinearLayout.LayoutParams(dp(48), dp(48))) else addView(android.view.View(this@NodeActivity), LinearLayout.LayoutParams(dp(12), 1))
        barTitle = label("", 17f, bold = true).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
        addView(barTitle, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        barDot = android.view.View(this@NodeActivity).apply { visibility = android.view.View.GONE }
        addView(barDot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginStart = dp(10) })
        banner = label("", 12f, K.dim).apply {
            setPadding(dp(10), dp(4), dp(10), dp(4))
            background = rounded(K.surface, 12, K.line)
            maxLines = 1
            visibility = android.view.View.GONE
        }
        addView(banner, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(10) })
        if (showsGear) addView(label("⚙", 20f, K.dim).apply {
            gravity = android.view.Gravity.CENTER
            contentDescription = "Settings"
            isClickable = true
            setOnClickListener { startActivity(Intent(this@NodeActivity, SettingsActivity::class.java)) }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
    }

    protected open val showsGear = false

    /** What sits under the bar: a scrolling column by default. */
    protected open fun body(): android.view.View = ScrollView(this).apply { addView(content) }

    override fun onStart() {
        super.onStart()
        bind()
    }

    protected fun rebind() {
        watch?.cancel()
        linkState = null
        bind()
    }

    private fun bind() {
        val link = link ?: return backHome()
        watch = kore.scope.launch {
            var shown: State? = null
            link.state.combine(link.snapshot) { s, snap -> s to snap }.collect { (s, snap) ->
                // Trying again is said only once it takes a while.
                if (s == State.Connecting && shown != State.Connecting) delay(RECONNECTING_AFTER_MS)
                shown = s
                runOnUiThread {
                    showBanner(link, s)
                    linkState = s
                    render(snap)
                }
            }
        }
    }

    override fun onStop() {
        watch?.cancel()
        super.onStop()
    }

    private fun showBanner(link: NodeClient, s: State) {
        val name = link.name
        val (text, color) = stateWords(s)
        banner.text = text
        banner.setTextColor(color)
        banner.contentDescription = "$name: ${text.removePrefix("● ")}"
        banner.visibility = if (text.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE
        macName = name
    }

    private fun backHome() {
        startActivity(Intent(this, HomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }

    /** Screens opened from here stay on this screen's device. */
    override fun startActivity(intent: Intent, options: Bundle?) {
        if (intent.component?.packageName == packageName && !intent.hasExtra("node")) host?.let { intent.putExtra("node", it) }
        super.startActivity(intent, options)
    }

    /** Draws the screen from the latest snapshot (null until the first one). */
    abstract fun render(snapshot: JsonObject?)

    companion object {
        const val RECONNECTING_AFTER_MS = 1_500L
    }
}

/** A node's state as the bar's pill: empty while up. */
fun stateWords(s: State): Pair<String, Int> = when (s) {
    State.Up -> "" to K.ok
    State.Connecting -> "● Reconnecting" to K.warn
    State.AwaitingAllow -> "● Waiting for Allow" to K.dim
    is State.Away -> when (s.why) {
        NodeMachine.AwayWhy.ASLEEP -> "● Asleep" to K.dim
        NodeMachine.AwayWhy.OFF -> "● Offline" to K.dim
        NodeMachine.AwayWhy.UNREACHABLE -> "● Offline · retrying" to K.warn
    }
    is State.Denied -> "● Not allowed" to K.err
    State.Removed -> "● Removed" to K.err
    State.SignedOut -> "● Signed out" to K.warn
    State.Idle -> "● Off" to K.dim
}

/** A device's state as one glyph and colour: ● up, ◌ trying, ○ away. */
fun nodeLook(s: State): Pair<String, Int> = when (s) {
    State.Up -> "●" to K.ok
    State.Connecting, State.AwaitingAllow -> "◌" to K.warn
    is State.Denied, State.Removed -> "○" to K.err
    else -> "○" to K.faint
}

/** "last seen 2 h ago". */
fun lastSeenWords(at: Long?, now: Long = System.currentTimeMillis()): String? {
    at ?: return null
    val m = (now - at) / 60_000
    return "last seen " + when {
        m < 1 -> "just now"
        m < 60 -> "$m min ago"
        m < 48 * 60 -> "${m / 60} h ago"
        else -> "${m / 1440} days ago"
    }
}
