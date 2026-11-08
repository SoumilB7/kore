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
    private var last: JsonObject? = null
    private var plus: TextView? = null
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
        chips = LinearLayout(this@DeviceActivity).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(16), dp(2), dp(16), dp(8)) }
        chipsRow = HorizontalScrollView(this@DeviceActivity).apply { isHorizontalScrollBarEnabled = false; addView(chips); visibility = View.GONE }
        windowLine = label("", 12f, K.faint).apply {
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
        if (snapshot == null) {
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            if (linkState == dev.kore.link.node.NodeMachine.State.Up || linkState == dev.kore.link.node.NodeMachine.State.Connecting) {
                notes.addView(empty("Waiting for $macName…", "It shows here as soon as Kore there answers."))
            }
            return
        }
        val windows = DeviceList.chips(snapshot)
        if (windows.isEmpty()) {
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            notes.addView(empty("No windows open", "Open a folder in Kore there and it appears here."))
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
        if (made.isEmpty() && w != null) {
            notes.addView(label("No chats in ${w.str("name") ?: "this window"} yet. ＋ starts one.", 13f, K.faint).apply {
                setPadding(dp(4), dp(8), dp(4), dp(8))
            })
        }
    }

    /** All, then each window by name: a tap filters; an empty window is outlined and opens. */
    private fun drawChips(windows: List<DeviceList.Chip>) {
        chips.removeAllViews()
        chipsRow.visibility = if (windows.size > 1) View.VISIBLE else View.GONE
        if (windows.size <= 1) return
        fun chip(text: String, on: Boolean, empty: Boolean, go: () -> Unit) = chips.addView(label(text, 13f, if (on) K.text else K.dim).apply {
            background = rounded(if (on) KS.chipOn else if (empty) android.graphics.Color.TRANSPARENT else K.surface, 14, if (on) K.accent else K.line)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            alpha = if (empty) 0.7f else 1f
            isSelected = on
            contentDescription = if (empty) "$text, no chats" else text
            setOnClickListener { go() }
            pressable(14)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(6) })
        chip("All ${windows.sumOf { it.chats }}", filter == null, false) { filter = null; draw() }
        for (w in windows.sortedByDescending { it.chats > 0 }) {
            chip(w.name, filter == w.windowId, w.chats == 0) {
                if (w.chats == 0) startActivity(Intent(this, WindowActivity::class.java).putExtra("window", w.windowId))
                else { filter = if (filter == w.windowId) null else w.windowId; draw() }
            }
        }
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
            setPadding(dp(4), 0, dp(4), dp(10))
            addView(label(text, 13f, K.dim), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            if (action != null) addView(label(action.first, 13f, K.accent).apply {
                setPadding(dp(8), dp(6), 0, dp(6))
                setOnClickListener { action.second() }
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
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = object : RecyclerView.ViewHolder(rowView()) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = bind(holder.itemView as LinearLayout, getItem(position))
    }

    /** Two lines: the CLI's mark, the title (bold while unread) and the age; then the cue or the last word. */
    private fun rowView(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(11), dp(14), dp(11))
        background = rounded(K.surface)
        pressable()
        layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) }
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(label("", 15f).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(View(context).apply { background = rounded(K.accent, 4) }, LinearLayout.LayoutParams(dp(7), dp(7)).apply { marginStart = dp(8) })
            addView(label("", 12f, K.faint).apply { setPadding(dp(8), 0, 0, 0) })
        })
        addView(label("", 13f, K.dim).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(dp(22), dp(3), 0, 0) })
    }

    private fun bind(v: LinearLayout, row: DeviceList.Row) {
        val top = v.getChildAt(0) as LinearLayout
        val title = top.getChildAt(0) as TextView
        val dot = top.getChildAt(1)
        val age = top.getChildAt(2) as TextView
        val line = v.getChildAt(1) as TextView
        val mark = if (row.chatId != null) providerMark(row.provider) else ""
        title.text = android.text.SpannableStringBuilder(mark).append(if (mark.isNotEmpty()) "  " else "").append(row.title)
        title.typeface = if (row.unread) android.graphics.Typeface.DEFAULT_BOLD else android.graphics.Typeface.DEFAULT
        dot.visibility = if (row.unread) View.VISIBLE else View.GONE
        age.text = row.age
        line.text = row.line
        line.visibility = if (row.line.isEmpty()) View.GONE else View.VISIBLE
        line.setTextColor(when (row.cue) {
            DeviceList.Cue.NEEDS -> K.warn
            DeviceList.Cue.WORKING -> K.accent
            DeviceList.Cue.FAILED -> K.err
            DeviceList.Cue.NONE -> K.dim
        })
        v.contentDescription = listOf(row.title, row.age, if (row.unread) "unread" else "", row.line).filter { it.isNotEmpty() }.joinToString(", ")
        v.setOnClickListener {
            if (row.chatId != null) startActivity(Intent(this, ChatActivity::class.java).putExtra("chat", row.chatId))
            else startActivity(Intent(this, WindowActivity::class.java).putExtra("window", row.windowId))
        }
    }

    private fun empty(title: String, line: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(24), dp(80), dp(24), dp(24))
        addView(android.widget.ImageView(this@DeviceActivity).apply { setImageResource(dev.kore.phone.R.drawable.kore_mark); alpha = 0.5f },
            LinearLayout.LayoutParams(dp(48), dp(48)).apply { bottomMargin = dp(16) })
        addView(label(title, 16f, K.text, bold = true).apply { gravity = Gravity.CENTER })
        addView(label(line, 14f, K.dim).apply { gravity = Gravity.CENTER; setPadding(0, dp(6), 0, 0) })
    }

}
