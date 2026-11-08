package dev.kore.phone.ui

import android.content.Intent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import dev.kore.phone.kore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * One device (a Mac or a box) as one list, newest first, across its windows (option B of
 * phone-device-screen.html): two lines a row, needs-you and working first, idle saying nothing.
 * More than one window: chips on top filter it (an empty window is an outlined chip). ＋ makes a
 * chat or a window there, and says what a tap makes and where. The list is diffed: a change
 * rebinds only its rows; ages move once a minute.
 */
class DeviceActivity : NodeActivity() {
    private companion object { const val LOADING_MS = 10_000L }
    private var last: JsonObject? = null
    private var plus: android.view.View? = null
    /** The window the list is filtered to (null: all). */
    private var filter: String? = null
    private val rows = Rows()
    private lateinit var chipsRow: HorizontalScrollView
    private lateinit var chips: LinearLayout
    private lateinit var windowLine: TextView
    private lateinit var list: RecyclerView
    /** What the list says when it has nothing (waiting, no windows, no chats yet): redrawn with it. */
    private lateinit var notes: LinearLayout
    private val minute = Runnable { draw(); scheduleMinute() }

    override fun body(): View = column().apply {
        plus = barButton(barTitle, "＋", "New") { createSheet() }.apply { visibility = View.GONE }
        chips = LinearLayout(this@DeviceActivity).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(16), dp(2), dp(16), dp(10)) }
        // The chips scroll, fading over the row's last stretch (spec §5).
        chipsRow = HorizontalScrollView(this@DeviceActivity).apply {
            isHorizontalScrollBarEnabled = false
            isHorizontalFadingEdgeEnabled = true
            setFadingEdgeLength(dp(44))
            addView(chips)
            visibility = View.GONE
        }
        windowLine = label("").apply {
            type(Type.Caption)
            setTextColor(Tone.faint)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(dp(20), dp(2), dp(20), dp(8))
            visibility = View.GONE
        }
        list = RecyclerView(this@DeviceActivity).apply {
            layoutManager = LinearLayoutManager(this@DeviceActivity)
            adapter = rows
            itemAnimator = null
            setPadding(dp(16), 0, dp(16), dp(16))
            clipToPadding = false
        }
        notes = column()
        content.addView(notes)
        addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(chipsRow)
        addView(windowLine, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    }

    override fun onStart() {
        super.onStart()
        scheduleMinute()
        // Opening a device's screen tries it now: an away one dials at once, a quiet link gets a probe.
        link?.reconnectNow()
    }

    override fun onStop() {
        list.removeCallbacks(minute)
        super.onStop()
    }

    /** Ages read "now", "4 m": once a minute the rows are made again; only those whose age moved rebind. */
    private fun scheduleMinute() {
        list.removeCallbacks(minute)
        list.postDelayed(minute, 60_000)
    }

    override fun render(snapshot: JsonObject?) {
        last = snapshot
        barTitle.text = macName
        content.removeAllViews()
        stateLine()?.let(content::addView)
        content.addView(notes)
        plus?.visibility = if (snapshot != null && linkState == dev.kore.link.node.NodeMachine.State.Up) View.VISIBLE else View.GONE
        draw()
        folderSheet?.takeIf { it.isShowing }?.refresh()
    }

    /** The chips, the window's line and the rows, from the last snapshot. */
    private fun draw() {
        val snapshot = last
        notes.removeAllViews()
        content.visibility = View.VISIBLE
        // Away: the device's own state in place of its list (spec §6: asleep, offline, not answering).
        (linkState as? dev.kore.link.node.NodeMachine.State.Away)?.let { away -> awayState(away)?.let { v ->
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            notes.addView(v)
            content.visibility = View.VISIBLE
            quietBanner()
            return
        } }
        if (snapshot == null) {
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            val s = linkState
            if (s == dev.kore.link.node.NodeMachine.State.Up || s == dev.kore.link.node.NodeMachine.State.Connecting) {
                // Up, its first state not here yet: skeleton rows for 10 s, then the waiting state.
                val since = loadingSince ?: System.currentTimeMillis().also { loadingSince = it; list.postDelayed({ draw() }, LOADING_MS + 50) }
                if (s == dev.kore.link.node.NodeMachine.State.Up && System.currentTimeMillis() - since < LOADING_MS) notes.addView(skeleton())
                else notes.addView(emptyState(dev.kore.phone.R.drawable.i_laptop, "Waiting for $macName", "It shows here as soon as Kore there answers.", waiting = true))
            }
            return
        }
        loadingSince = null
        val windows = DeviceList.chips(snapshot)
        if (windows.isEmpty()) {
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            notes.addView(emptyState(dev.kore.phone.R.drawable.i_folder, "No windows open", "Open a folder in Kore on the Mac, or start one from here.", "New window" to { createSheet() }))
            return
        }
        if (filter != null && windows.none { it.windowId == filter }) filter = null
        drawChips(windows)
        // One window, or one picked: its folder as a faint line; a tap opens its tabs and history.
        val shown = if (windows.size == 1) windows[0].windowId else filter
        val w = shown?.let { id -> snapshot.objs("windows").firstOrNull { it.str("id") == id } }
        windowLine.visibility = if (w != null) View.VISIBLE else View.GONE
        if (w != null) {
            windowLine.text = listOfNotNull(w.str("name"), w.str("path")).joinToString("  ·  ") + "  ›"
            windowLine.setOnClickListener { startActivity(Intent(this, WindowActivity::class.java).putExtra("window", w.str("id"))) }
            if (link.hasControl(snapshot)) windowLine.setOnLongClickListener { v -> windowMenu(v, w); true }
        }
        val made = DeviceList.rows(snapshot, filter, System.currentTimeMillis(), kore.seen)
        rows.submitList(made)
        // Nothing above the chips (no state line, no empty state): no gap either.
        content.visibility = if (made.isEmpty() || content.childCount > 1) View.VISIBLE else View.GONE
        if (made.isEmpty() && w != null) {
            notes.addView(emptyState(dev.kore.phone.R.drawable.i_chat, "No chats here yet", "A new chat opens as a tab in ${w.str("name") ?: "this window"} on $macName.",
                if (link.hasControl(snapshot)) "New chat" to { createSheet() } else null))
        }
    }

    /** When the device's first state started loading (the skeleton's 10 s). */
    private var loadingSince: Long? = null

    /** An away device's state (spec §6): asleep (moon), offline or not answering (wifi off), waiting; else null (a line says it). */
    private fun awayState(away: dev.kore.link.node.NodeMachine.State.Away): View? {
        val node = link ?: return null
        val seen = lastSeenWords(node.lastSeen)?.replaceFirstChar { it.uppercase() }
        val retry = "Try again" to { node.reconnectNow(); Unit }
        return when (away.why) {
            dev.kore.link.node.NodeMachine.AwayWhy.ASLEEP -> emptyState(dev.kore.phone.R.drawable.i_moon, "$macName is asleep",
                listOfNotNull(seen?.let { "$it." }, "Wake it and Kore picks up here.").joinToString(" "), retry)
            dev.kore.link.node.NodeMachine.AwayWhy.OFFLINE -> emptyState(dev.kore.phone.R.drawable.i_wifi_off, "$macName is offline",
                listOfNotNull(seen?.let { "$it." }, "Kore picks up here once it's back.").joinToString(" "), retry)
            dev.kore.link.node.NodeMachine.AwayWhy.UNREACHABLE -> emptyState(dev.kore.phone.R.drawable.i_wifi_off, "$macName isn't answering",
                "Kore there may be closed. It shows here as soon as it answers.", retry)
            dev.kore.link.node.NodeMachine.AwayWhy.WAITING -> emptyState(dev.kore.phone.R.drawable.i_laptop, "Waiting for $macName",
                "It shows here as soon as Kore there answers.", waiting = true)
            else -> null
        }
    }

    /**
     * All, then each window by name (spec §5): 32 high, Label; at rest `l1` with a hair edge, the
     * picked one accentFill and b200. A window with a chat that needs you has a warn point after
     * its name; names that match add their folder, faint. A tap filters (an empty window opens);
     * a long-press holds Show on the Mac and Close window.
     */
    private fun drawChips(windows: List<DeviceList.Chip>) {
        chips.removeAllViews()
        chipsRow.visibility = if (windows.size > 1) View.VISIBLE else View.GONE
        if (windows.size <= 1) return
        val control = link.hasControl(last)
        fun chip(text: String, suffix: String?, needs: Boolean, on: Boolean, empty: Boolean, w: DeviceList.Chip?, go: () -> Unit) = chips.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), 0, dp(14), 0)
            addView(label(text).apply { type(Type.Label); setTextColor(if (on) Tone.b200 else Tone.dim) })
            if (suffix != null) addView(label(" · $suffix").apply { type(Type.Label); setTextColor(Tone.faint); typeface = android.graphics.Typeface.DEFAULT })
            if (needs) addView(point(Tone.warn, 6), LinearLayout.LayoutParams(dp(6), dp(6)).apply { marginStart = dp(6) })
            alpha = if (empty) 0.7f else 1f
            isSelected = on
            contentDescription = listOfNotNull(text, suffix, if (needs) "needs you" else null, if (empty) "no chats" else null).joinToString(", ")
            setOnClickListener { go() }
            if (w != null && control) setOnLongClickListener { v -> chipMenu(v, w); true }
            pressFill(if (on) Tone.accentFill else Tone.l1, if (on) Tone.accentFill else Tone.l2, 16, if (on) null else Tone.hair)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(32)).apply { marginEnd = dp(8) })
        chip("All ${windows.sumOf { it.chats }}", null, false, filter == null, false, null) { filter = null; draw() }
        val ordered = windows.sortedByDescending { it.chats > 0 }
        val suffixes = DeviceList.chipSuffixes(ordered)
        ordered.forEachIndexed { i, w ->
            chip(w.name, suffixes[i], w.needs, filter == w.windowId, w.chats == 0, w) {
                if (w.chats == 0) startActivity(Intent(this, WindowActivity::class.java).putExtra("window", w.windowId))
                else { filter = if (filter == w.windowId) null else w.windowId; draw() }
            }
        }
    }

    /** A chip held (spec §6): Show on the Mac (its active chat comes forward), a rule, Close window. */
    private fun chipMenu(anchor: View, chip: DeviceList.Chip) {
        val w = last?.objs("windows")?.firstOrNull { it.str("id") == chip.windowId } ?: return
        val C = dev.kore.link.node.Control
        val shown = w.objs("tabs").firstOrNull { it.str("id") == w.str("activeTabId") }?.str("chatId")
            ?: w.objs("tabs").firstOrNull { it.str("chatId") != null }?.str("chatId")
        PopMenu(this).show(anchor, listOf(
            PopMenu.Item("Show on the Mac", enabled = shown != null) { shown?.let { id -> act(C.select(id)) { Quiet.say(this, "Shown on $macName") } } },
            PopMenu.Item("Close window", danger = true, rule = true) {
                act(C.windowClose(chip.windowId), forced = C.windowClose(chip.windowId, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
            },
        ))
    }

    /** Why the device isn't up, in one line, and the one thing to do about it. */
    private fun stateLine(): View? {
        val s = linkState ?: return null
        val node = link ?: return null
        // Removed, or not allowed: one line and its one action, as Home's row says it.
        troubleWords(s, node.device.value.kind == dev.kore.link.trust.NodeKind.MAC, macName, kore.mesh.macFor(node))?.let { t ->
            val said = t.fact.substringBeforeLast(" · ")
            val act = t.action?.let { a -> t.fact.substringAfterLast(" · ") to { rowAction(node, a) } }
            return stateRow(if (t.action == null) t.fact else said, act)
        }
        // An away device that shows its own state (asleep, offline…) needs no line too.
        if (s is dev.kore.link.node.NodeMachine.State.Away && awayState(s) != null) return null
        val (text, action) = when (s) {
            is dev.kore.link.node.NodeMachine.State.Away -> awayLine(s.why, macName, kore.mesh.macFor(node), node.lastSeen).let { (line, retry) ->
                line to (if (retry) "Retry" to { node.reconnectNow() } else null)
            }
            dev.kore.link.node.NodeMachine.State.SignedOut -> "Signed out of Tailscale" to ("Sign in" to { startActivity(Intent(this, JoinActivity::class.java).putExtra("signIn", true)) })
            dev.kore.link.node.NodeMachine.State.Idle -> if (!kore.mesh.networkOn) "KoreNet is off on this phone" to ("Turn on" to { kore.mesh.networkOn = true }) else return null
            else -> return null
        }
        return stateRow(text, action)
    }

    private fun stateRow(text: String, action: Pair<String, () -> Unit>?): View {
        return LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), 0, dp(16), dp(10))
            addView(label(text).apply { type(Type.Callout); setTextColor(Tone.dim) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            if (action != null) addView(label(action.first).apply {
                type(Type.Label)
                setTextColor(Tone.accent)
                setPadding(dp(12), dp(8), dp(12), dp(8))
                setOnClickListener { action.second() }
                pressFill(null, Tone.l2, 15)
            })
        }
    }

    /** What ＋ makes: a chat or a window. */
    private var making = "chat"
    private val prefs by lazy { getSharedPreferences("kore", MODE_PRIVATE) }
    /** A box's folders, read when the Window half opens. */
    private var boxFolders: List<JsonObject>? = null

    /**
     * ＋ (option B): Chat or Window, then where. Chat: the CLI (it remembers the last), then the
     * window it goes in. Window: Kore's recent folders not open now and Reopen on a Mac; the
     * folders a box serves on a box. The one line at the foot says what a tap makes and where.
     */
    private fun createSheet() {
        if (last == null) return
        val box = link?.device?.value?.kind == dev.kore.link.trust.NodeKind.BOX
        // The builder runs inside show(), before show() returns: the sheet is its receiver, never a
        // variable assigned from show() (reading that one there throws, the ＋ crash of 0.3.0).
        val s = Sheet(this).show {
            val snap = last ?: return@show dismiss()
            title("New on $macName")
            val sheet = this
            segmented(listOf("chat" to "Chat", "window" to "Window"), making) { making = it; if (it == "window" && box) readBoxFolders(sheet); refresh() }
            if (making == "chat") chatHalf(snap, box) else windowHalf(snap, box)
        }
        folderSheet = s
        s.onDismiss { folderSheet = null }
    }

    private fun Sheet.chatHalf(snap: JsonObject, box: Boolean) {
        val s = this
        val providers = link?.welcome?.value?.objs("providers").orEmpty()
        val chosen = prefs.getString("newProvider", null)?.takeIf { p -> providers.any { it.str("id") == p } } ?: providers.firstOrNull()?.str("id")
        if (providers.size > 1) segmented(providers.map { (it.str("id") ?: "") to (it.str("name") ?: it.str("id") ?: "") }, chosen) {
            prefs.edit().putString("newProvider", it).apply()
            refresh()
        }
        val cli = providers.firstOrNull { it.str("id") == chosen }
        val cliName = cli?.str("name") ?: "new"
        val windows = snap.objs("windows")
        for (w in windows) {
            val wid = w.str("id") ?: continue
            item(w.str("name") ?: "Window", glyph = "□", detail = ControlModel.parentOf(w.str("path")), tag = "New $cliName chat in ${w.str("name")}") {
                val pid = chosen ?: return@item
                s.dismiss()
                val cmd = if (box && w.str("path") != null) dev.kore.link.node.Control.newChatInFolder(w.str("path")!!, pid) else dev.kore.link.node.Control.newChat(wid, pid)
                act(cmd) { r ->
                    r.str("chatId")?.let { startActivity(Intent(this@DeviceActivity, ChatActivity::class.java).putExtra("chat", it)) }
                        ?: Quiet.say(this@DeviceActivity, "Started on $macName")
                }
            }
        }
        val where = if (windows.size == 1) windows[0].str("name") ?: "the window" else "the folder you pick"
        say(if (box) "A $cliName chat in $where on $macName." else "A $cliName chat in $where, as a new tab there.")
    }

    private fun Sheet.windowHalf(snap: JsonObject, box: Boolean) {
        val s = this
        if (box) {
            val folders = boxFolders
            if (folders == null) { say("Reading the folders on $macName…"); return }
            for (f in folders) {
                val wid = f.str("windowId") ?: continue
                item((f.str("path") ?: "Folder").trimEnd('/').substringAfterLast('/'), glyph = "□", detail = ControlModel.parentOf(f.str("path")), enabled = !f.bool("missing")) {
                    s.dismiss()
                    startActivity(Intent(this@DeviceActivity, WindowActivity::class.java).putExtra("window", wid))
                }
            }
            say("Folders open on $macName. A new folder is added from the Mac.")
            return
        }
        // A Mac that doesn't send its recents (before this phone's ask view): say so, not an empty sheet.
        val mac = snap.obj("mac") ?: return say("Update Kore on $macName to open its folders from here.")
        val open = snap.objs("windows").mapNotNull { it.str("path") }.toSet()
        for (r in mac.objs("recents").filter { it.str("path") !in open }) {
            val id = r.str("id") ?: continue
            item(r.str("name") ?: "Folder", glyph = "□", detail = ControlModel.parentOf(r.str("path")), tag = "Open ${r.str("name")}") {
                s.dismiss()
                act(dev.kore.link.node.Control.windowOpen(id)) { res ->
                    res.str("windowId")?.let { startActivity(Intent(this@DeviceActivity, WindowActivity::class.java).putExtra("window", it)) }
                }
            }
        }
        if (mac.bool("canReopenWindow")) item("Reopen closed window", glyph = "↺") {
            s.dismiss()
            act(dev.kore.link.node.Control.windowReopen()) { res ->
                res.str("windowId")?.let { startActivity(Intent(this@DeviceActivity, WindowActivity::class.java).putExtra("window", it)) }
            }
        }
        item("Another folder", glyph = " ", detail = "on $macName", enabled = false)
        say("A window on $macName, from a folder Kore opened before.")
    }

    /** A box: the folders it already serves (a new folder is the Mac's to add). */
    private fun readBoxFolders(s: Sheet) {
        val node = link ?: return
        kore.scope.launch {
            val r = node.call(dev.kore.link.node.Control.foldersList())
            runOnUiThread {
                if (!r.bool("ok")) return@runOnUiThread s.say(refusalWords(r.str("code")))
                boxFolders = r.objs("folders")
                if (s.isShowing) s.refresh()
            }
        }
    }

    private var folderSheet: Sheet? = null

    private fun windowMenu(anchor: View, w: JsonObject) {
        val id = w.str("id") ?: return
        val C = dev.kore.link.node.Control
        PopMenu(this).show(anchor, listOf(PopMenu.Item("Close window", danger = true) {
            act(C.windowClose(id), forced = C.windowClose(id, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
        }))
    }

    /** The rows, diffed: a snapshot rebinds only the rows that changed. */
    private inner class Rows : ListAdapter<DeviceList.Row, RecyclerView.ViewHolder>(object : DiffUtil.ItemCallback<DeviceList.Row>() {
        override fun areItemsTheSame(a: DeviceList.Row, b: DeviceList.Row) = a.key == b.key
        override fun areContentsTheSame(a: DeviceList.Row, b: DeviceList.Row) = a == b
    }) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = object : RecyclerView.ViewHolder(chatCard()) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = bindChatCard(holder.itemView as LinearLayout, getItem(position))
    }
}
