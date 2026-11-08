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
    private lateinit var titleColumn: LinearLayout
    /** The top bar's title: the device's, the window's or the chat's name. */
    protected lateinit var barTitle: TextView
    protected lateinit var barLead: android.widget.FrameLayout
    /** A chat's waiting symbols, after the title (link 1.13). */
    protected lateinit var barAfter: LinearLayout
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
        tag = BAR_ROW
        orientation = LinearLayout.HORIZONTAL
        gravity = android.view.Gravity.CENTER_VERTICAL
        setPadding(dp(4), dp(4), if (showsGear) dp(4) else dp(16), dp(4))
        minimumHeight = dp(56)
        if (showsBack) addView(barIcon(dev.kore.phone.R.drawable.i_back, "Back").apply {
            imageTintList = android.content.res.ColorStateList.valueOf(Tone.text)
            setOnClickListener { finish() }
            pressFill(null, Tone.l2, 24)
        }, LinearLayout.LayoutParams(dp(48), dp(48))) else addView(android.view.View(this@NodeActivity), LinearLayout.LayoutParams(dp(12), 1))
        // The lead (spec §5): a chat's logo, or the spinner while it works; 17, 8 before the title. Hidden elsewhere.
        barLead = android.widget.FrameLayout(this@NodeActivity).apply { visibility = android.view.View.GONE }
        addView(barLead, LinearLayout.LayoutParams(dp(17), dp(17)).apply { marginStart = dp(2); marginEnd = dp(8) })
        barTitle = label("").apply { type(Type.Title); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
        // The link's state is one quiet line under the title (spec §5: Caption, warn), so the name keeps its width.
        banner = label("").apply {
            type(Type.Caption)
            setTextColor(Tone.warn)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            visibility = android.view.View.GONE
        }
        // The title, then (a chat's) waiting symbols 8 after it; the title gives way when space is short.
        barAfter = waitingSymbols().apply { visibility = android.view.View.GONE }
        titleColumn = LinearLayout(this@NodeActivity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            minimumHeight = dp(48)
            addView(LinearLayout(this@NodeActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                addView(barTitle, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(barAfter, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8) })
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(banner)
        }
        addView(titleColumn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        barDot = android.view.View(this@NodeActivity).apply { visibility = android.view.View.GONE }
        addView(barDot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginStart = dp(10) })
        if (showsGear) addView(barIcon(dev.kore.phone.R.drawable.i_gear, "Settings").apply {
            setOnClickListener { startActivity(Intent(this@NodeActivity, SettingsActivity::class.java)) }
            pressFill(null, Tone.l2, 24)
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
            link.state.combine(link.snapshot) { s, snap -> shownState(s, kore.mesh.networkOn) to snap }.collectLatest { (s, snap) ->
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
        val mac = kore.mesh.macFor(link)
        val trouble = troubleWords(s, link.device.value.kind == dev.kore.link.trust.NodeKind.MAC, name, mac)
        val (text, color) = trouble?.let { it.pill to stateWords(s, mac).second } ?: stateWords(s, mac)
        banner.text = text
        banner.setTextColor(color)
        val action = trouble?.action
        titleColumn.setOnClickListener(action?.let { a -> android.view.View.OnClickListener { rowAction(link, a) } })
        titleColumn.isClickable = action != null
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

/**
 * The state a screen shows: [State.Idle] with KoreNet on is the seconds the tailnet takes to start
 * on opening, so it reads as connecting, never "off" (that's only KoreNet off on this phone).
 */
fun shownState(s: State, networkOn: Boolean): State = if (s == State.Idle && networkOn) State.Connecting else s

/** A node's state as the bar's pill: empty while up. [mac]: the Mac a box waits for or was paused by. */
fun stateWords(s: State, mac: String = "your Mac"): Pair<String, Int> = when (s) {
    State.Up -> "" to K.ok
    State.Connecting -> "● Reconnecting" to K.warn
    State.AwaitingAllow -> "● Waiting for Allow" to K.dim
    is State.Away -> when (s.why) {
        NodeMachine.AwayWhy.ASLEEP -> "● Asleep" to K.dim
        NodeMachine.AwayWhy.OFFLINE -> "● Offline" to K.dim
        NodeMachine.AwayWhy.OFF -> "● Taken offline" to K.dim
        NodeMachine.AwayWhy.UNREACHABLE -> "● Not answering" to K.warn
        NodeMachine.AwayWhy.WAITING -> "● Waiting for $mac" to K.dim
        NodeMachine.AwayWhy.NET_OFF -> "● KoreNet is off" to K.dim
    }
    is State.Denied -> "● Not allowed" to K.err
    State.Removed -> "● Removed" to K.err
    State.SignedOut -> "● Signed out" to K.warn
    State.Idle -> "● Off" to K.dim
}

/**
 * Home's fact for a device that is away, the same story as the pill and the Device line:
 * "asleep · last seen 14:02", "offline · last seen 2 h ago", "not answering", "taken offline on MacBook".
 */
fun awayFact(why: NodeMachine.AwayWhy, name: String, mac: String, lastSeen: Long?, now: Long = System.currentTimeMillis()): String {
    val seen = lastSeenWords(lastSeen, now)
    return when (why) {
        NodeMachine.AwayWhy.ASLEEP -> listOfNotNull("asleep", seen).joinToString(" · ")
        NodeMachine.AwayWhy.OFFLINE -> listOfNotNull("offline", seen).joinToString(" · ")
        NodeMachine.AwayWhy.UNREACHABLE -> "not answering"
        NodeMachine.AwayWhy.OFF -> "taken offline on $mac"
        NodeMachine.AwayWhy.WAITING -> "waiting for $mac"
        NodeMachine.AwayWhy.NET_OFF -> "KoreNet is off on $name"
    }
}

/** The Device screen's line for a device that is away, and whether it offers Retry. */
fun awayLine(why: NodeMachine.AwayWhy, name: String, mac: String, lastSeen: Long?, now: Long = System.currentTimeMillis()): Pair<String, Boolean> {
    val seen = lastSeenWords(lastSeen, now)
    return when (why) {
        NodeMachine.AwayWhy.ASLEEP -> listOfNotNull("$name is asleep", seen).joinToString(" · ") to true
        NodeMachine.AwayWhy.OFFLINE -> listOfNotNull("$name is offline", seen).joinToString(" · ") to true
        NodeMachine.AwayWhy.UNREACHABLE -> "$name isn't answering" to true
        NodeMachine.AwayWhy.OFF -> "$mac took this phone offline · Bring it online in Devices there" to false
        NodeMachine.AwayWhy.WAITING -> "Waiting for $mac" to true
        NodeMachine.AwayWhy.NET_OFF -> "KoreNet is off on $name" to true
    }
}

/** What a device row offers when the device won't take this phone: tapping the row does it. */
enum class RowAction {
    /** Join again through the Add device window (removed there). */
    JOIN_AGAIN,
    /** Ask the Mac again through the Add device window (it doesn't hold this phone). */
    ASK_AGAIN,
    /** Dial again now (the Mac's KoreNet was off). */
    TRY_AGAIN,
}

/** A row's fact for a device that won't take this phone, with its one action. */
data class Trouble(val fact: String, val pill: String, val action: RowAction?)

/**
 * Removed, not allowed, or a Mac whose KoreNet went off: one line and at most one action (G18).
 * [name] is the device's, [mac] the Mac that allowed this phone (a box waits for it).
 */
fun troubleWords(s: State, isMac: Boolean, name: String, mac: String): Trouble? = when {
    s == State.Removed -> Trouble("Removed on ${if (isMac) name else mac} · Join again", "● Removed · Join again", RowAction.JOIN_AGAIN)
    s !is State.Denied -> null
    !isMac -> Trouble("waiting for $mac", "● Waiting for $mac", null)
    else -> Trouble("Not allowed · Ask again", "● Not allowed · Ask again", RowAction.ASK_AGAIN)
}

/** Does a row's action: the Join screen for another Allow, or a dial now. */
fun Activity.rowAction(node: NodeClient, action: RowAction) {
    when (action) {
        RowAction.JOIN_AGAIN, RowAction.ASK_AGAIN -> startActivity(Intent(this, JoinActivity::class.java).putExtra(JoinActivity.AGAIN, true))
        RowAction.TRY_AGAIN -> node.post(NodeMachine.Event.Trigger)
    }
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
