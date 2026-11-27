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
 * rebinds only its rows; ages move once a minute. At its foot, the device's Accounts: each CLI
 * login's usage as the device pushes it (link 1.14), asked for once as the screen opens.
 */
class DeviceActivity : NodeActivity() {
    private companion object { const val LOADING_MS = 10_000L }
    private var last: JsonObject? = null
    private var plus: android.view.View? = null
    /** The window the list is filtered to (null: all). */
    private var filter: String? = null
    private val rows = Rows()
    private val accounts = Accounts()
    /** This opening asked the device for its logins' usage (once; the device answers in `clis`). */
    private var askedUsage = false
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
            adapter = androidx.recyclerview.widget.ConcatAdapter(rows, accounts)
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
        askedUsage = false
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
        askUsage()
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
            accounts.submitList(emptyList())
            notes.addView(v)
            content.visibility = View.VISIBLE
            quietBanner()
            return
        } }
        if (snapshot == null) {
            chipsRow.visibility = View.GONE
            windowLine.visibility = View.GONE
            rows.submitList(emptyList())
            accounts.submitList(emptyList())
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
            accounts.submitList(emptyList())
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
        val made = DeviceList.rows(snapshot, filter, System.currentTimeMillis(), kore.seen, kore.pins.of(host))
        rows.submitList(made)
        val usage = UsageMeters.rows(snapshot, System.currentTimeMillis())
        accounts.submitList(if (usage.isEmpty()) emptyList() else listOf(usage))
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

    /**
     * A chip held (spec §6): Show on the Mac (its active chat comes forward; a box has no screen),
     * History (its past chats, to open here), a rule, Close window. A box's window with no chats closes too (kore-host keeps the folder).
     */
    private fun chipMenu(anchor: View, chip: DeviceList.Chip) {
        val w = last?.objs("windows")?.firstOrNull { it.str("id") == chip.windowId } ?: return
        val C = dev.kore.link.node.Control
        val shown = w.objs("tabs").firstOrNull { it.str("id") == w.str("activeTabId") }?.str("chatId")
            ?: w.objs("tabs").firstOrNull { it.str("chatId") != null }?.str("chatId")
        val items = ArrayList<PopMenu.Item>()
        if (!isBox) items += PopMenu.Item("Show on the Mac", enabled = shown != null) { shown?.let { id -> act(C.select(id)) { Quiet.say(this, "Shown on $macName") } } }
        items += PopMenu.Item("History") { history(chip.windowId) }
        pasteItem(chip.windowId, chip.name)?.let { items += it }
        items += PopMenu.Item("Close window", danger = true, rule = true) {
            act(C.windowClose(chip.windowId), forced = C.windowClose(chip.windowId, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
        }
        PopMenu(this).show(anchor, items)
    }

    private val isBox get() = link?.device?.value?.kind == dev.kore.link.trust.NodeKind.BOX

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
    /** A box's folder browser: made when the Window half first opens on a box, gone with the sheet. */
    private var browser: FolderBrowser? = null
    /** The new folder's name while it's typed (kept across the sheet's redraws). */
    private var naming: android.widget.EditText? = null
    /** The Chat half's From History with several windows: the window its past chats come from is picked first. */
    private var pickingHistory = false

    /**
     * ＋ (option B): Chat or Window, then where. Chat: the CLI (it remembers the last), then the
     * window it goes in, or a past chat From History. Window: Kore's recent folders not open now
     * and Reopen on a Mac; on a box, its folders from the home down, a new one, and Open here.
     * The one line at the foot says what a tap makes and where.
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
            segmented(listOf("chat" to "Chat", "window" to "Window"), making) { making = it; pickingHistory = false; refresh() }
            if (making == "window" && box) startBrowse(sheet)
            if (making == "chat") chatHalf(snap, box) else windowHalf(snap, box)
        }
        folderSheet = s
        s.onDismiss { folderSheet = null; browser = null; naming = null; pickingHistory = false }
    }

    private fun Sheet.chatHalf(snap: JsonObject, box: Boolean) {
        val s = this
        val windows = snap.objs("windows")
        if (pickingHistory) return historyPick(windows)
        val providers = link?.welcome?.value?.objs("providers").orEmpty()
        val chosen = prefs.getString("newProvider", null)?.takeIf { p -> providers.any { it.str("id") == p } } ?: providers.firstOrNull()?.str("id")
        if (providers.size > 1) segmented(providers.map { (it.str("id") ?: "") to (it.str("name") ?: it.str("id") ?: "") }, chosen) {
            prefs.edit().putString("newProvider", it).apply()
            refresh()
        }
        val cli = providers.firstOrNull { it.str("id") == chosen }
        val cliName = cli?.str("name") ?: "new"
        for (w in windows) {
            val wid = w.str("id") ?: continue
            item(w.str("name") ?: "Window", glyph = "□", detail = ControlModel.parentOf(w.str("path")), tag = "New $cliName chat in ${w.str("name")}") {
                val pid = chosen ?: return@item
                s.dismiss()
                // By the window's id, on a box too: its windows say their folder as `~/…`.
                act(dev.kore.link.node.Control.newChat(wid, pid)) { r ->
                    r.str("chatId")?.let { startActivity(Intent(this@DeviceActivity, ChatActivity::class.java).putExtra("chat", it)) }
                        ?: Quiet.say(this@DeviceActivity, "Started on $macName")
                }
            }
        }
        // A past chat back, in the picked window (one window, or the chip picked: straight to its
        // History; several: the window first).
        val picked = (if (windows.size == 1) windows[0] else windows.firstOrNull { it.str("id") == filter })
        if (windows.isNotEmpty()) item("From History", glyph = "From History", detail = picked?.str("name"), chevron = true) {
            val wid = picked?.str("id")
            if (wid != null) { s.dismiss(); history(wid) } else { pickingHistory = true; refresh() }
        }
        val where = if (windows.size == 1) windows[0].str("name") ?: "the window" else "the folder you pick"
        say(if (box) "A $cliName chat in $where on $macName." else "A $cliName chat in $where, as a new tab there.")
    }

    /** From History, several windows: which one's past chats (a tap there opens one in it). */
    private fun Sheet.historyPick(windows: List<JsonObject>) {
        val s = this
        custom(navRow("From History", dev.kore.phone.R.drawable.i_back, "Back to new chat") { pickingHistory = false; s.refresh() })
        for (w in windows) {
            val wid = w.str("id") ?: continue
            item(w.str("name") ?: "Window", glyph = "□", detail = ControlModel.parentOf(w.str("path")), chevron = true, tag = "History of ${w.str("name")}") {
                s.dismiss()
                history(wid)
            }
        }
        say("A past chat on $macName, opened again in the folder you pick.")
    }

    private fun Sheet.windowHalf(snap: JsonObject, box: Boolean) {
        val s = this
        if (box) {
            val b = browser
            if (b != null && !b.unsupported) return browserHalf(b)
            val folders = boxFolders
            if (folders == null) { say("Reading the folders on $macName…"); return }
            for (f in folders) {
                val wid = f.str("windowId") ?: continue
                item((f.str("path") ?: "Folder").trimEnd('/').substringAfterLast('/'), glyph = "□", detail = ControlModel.parentOf(f.str("path")), enabled = !f.bool("missing")) {
                    s.dismiss()
                    openBoxWindow(wid)
                }
            }
            say("Folders open on $macName. Update kore-host there to open any folder from here.")
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
        // A Mac's new folder stays the Mac's: a phone never browses the Mac's disk.
        item("Another folder", glyph = " ", detail = "on the Mac itself", enabled = false)
        say("A window on $macName, from a folder Kore opened before.")
    }

    /**
     * A box's folders from its user's home (FolderBrowser): where it stands (a tap goes up), its
     * subfolders (a tap goes in; one open on the box says so), New folder named in place, and Open
     * here. Read one level at a time; the foot line says what Open here makes.
     */
    private fun Sheet.browserHalf(b: FolderBrowser) {
        val s = this
        val at = b.path
        val up = b.up()
        custom(navRow(at?.let { FolderBrowser.shown(it, b.home) } ?: "~", if (up != null) dev.kore.phone.R.drawable.i_up else dev.kore.phone.R.drawable.i_folder,
            if (up != null) "Up to ${FolderBrowser.shown(up, b.home)}" else null) { if (up != null) browse(s, up) })
        if (at == null) {
            // The home's read failed: Retry makes the browser again and asks once more.
            if (b.failedFirst) custom(button("Retry", Btn.Secondary) { browser = null; startBrowse(s); s.refresh() }.apply {
                contentDescription = "Retry"
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), dp(14), dp(4), 0) }
            })
            return say(b.problem ?: if (b.failedFirst) "Couldn't read the folders on $macName." else "Reading the folders on $macName…")
        }
        val served = boxFolders.orEmpty().mapNotNull { it.str("path")?.trimEnd('/') }.toSet()
        for (name in b.folders) {
            val p = b.into(name) ?: continue
            item(name, glyph = "□", detail = if (p in served) "open" else null, chevron = true, tag = "Folder $name") { browse(s, p) }
        }
        if (b.folders.isEmpty() && b.reading == null) custom(label("No folders in here.").apply {
            type(Type.Callout); setTextColor(Tone.faint); setPadding(dp(4), dp(10), dp(4), dp(10))
        })
        val field = naming
        if (field == null) item("New folder", glyph = "New folder", tag = "New folder") {
            naming = nameField()
            s.refresh()
            naming?.let { f -> f.requestFocus(); f.post { (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).showSoftInput(f, 0) } }
        } else {
            custom(field)
            custom(LinearLayout(this@DeviceActivity).apply {
                addView(button("Cancel", Btn.Secondary) { naming = null; hideKeys(field); s.refresh() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(8) })
                addView(button("Make", Btn.Primary) { makeFolder(s) }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), dp(4), dp(4), dp(4)) }
            })
        }
        if (field == null) custom(button("Open here", Btn.Primary) { openHere(s) }.apply {
            contentDescription = "Open here"
            // Another folder is being read: what's shown isn't where Open here would land yet.
            isEnabled = b.canOpen
            alpha = if (b.canOpen) 1f else 0.45f
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), dp(14), dp(4), 0) }
        })
        val here = FolderBrowser.shown(at, b.home)
        say(b.problem ?: if (b.reading != null) "Reading…" else if (field != null) "A new folder in $here on $macName." else "A window on $here on $macName.")
    }

    /** A sheet's place row: an icon (a tap goes back or up when [go] is said), then where, dim. */
    private fun navRow(text: String, icon: Int, tapSays: String?, go: () -> Unit): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(44)
        setPadding(dp(4), dp(6), dp(4), dp(6))
        addView(android.widget.ImageView(this@DeviceActivity).apply {
            setImageResource(icon)
            imageTintList = android.content.res.ColorStateList.valueOf(if (tapSays != null) Tone.accent else Tone.dim)
        }, LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginEnd = dp(14) })
        addView(label(text).apply {
            type(Type.Label); setTextColor(Tone.dim); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.START
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        contentDescription = tapSays ?: text
        if (tapSays != null) { pressable(); setOnClickListener { go() } }
    }

    /** The new folder's name: one line, never a secret (suggestions stay on), Done makes it. */
    private fun nameField(): android.widget.EditText = android.widget.EditText(this).apply {
        hint = "Folder name"
        setHintTextColor(K.faint)
        setTextColor(K.text)
        textSize = 15f
        background = rounded(KS.field, 10, K.line)
        setPadding(dp(12), dp(10), dp(12), dp(10))
        inputType = android.text.InputType.TYPE_CLASS_TEXT
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        maxLines = 1
        isSingleLine = true
        contentDescription = "Folder name"
        setOnEditorActionListener { _, _, _ -> folderSheet?.let(::makeFolder); true }
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { setMargins(dp(4), dp(8), dp(4), dp(4)) }
    }

    private fun hideKeys(v: View) =
        (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).hideSoftInputFromWindow(v.windowToken, 0)

    /** The Window half opened on a box: its served folders (marks, the fallback) and its home, read once a sheet. */
    private fun startBrowse(s: Sheet) {
        if (browser != null) return
        browser = FolderBrowser()
        readBoxFolders(s)
        browse(s, null, redraw = false)
    }

    /** Goes to [to] (null: the home): at once when it was read, else read now and drawn when it answers. */
    private fun browse(s: Sheet, to: String?, redraw: Boolean = true) {
        val b = browser ?: return
        naming = null
        val needs = b.go(to)
        if (redraw) s.refresh()
        if (!needs) return
        val asked = b.reading?.takeIf { it.isNotEmpty() }
        ask(dev.kore.link.node.Control.fsList(asked)) { r ->
            if (browser !== b) return@ask
            b.listed(asked, r)
            if (s.isShowing) s.refresh()
        }
    }

    /** New folder's Make: the name checked here first, made on the box, then the browser stands in it. */
    private fun makeFolder(s: Sheet) {
        val b = browser ?: return
        val at = b.path ?: return
        val name = naming?.text?.toString()?.trim().orEmpty()
        FolderBrowser.nameProblem(name, b.folders)?.let { b.refused(it); return s.refresh() }
        val path = if (at == "/") "/$name" else "$at/$name"
        ask(dev.kore.link.node.Control.fsMkdir(path)) { r ->
            if (browser !== b) return@ask
            if (r.bool("ok")) {
                naming?.let(::hideKeys)
                naming = null
                b.made(name, at)
            } else b.refused(boxWords(r))
            if (s.isShowing) s.refresh()
        }
    }

    /** Open here: the box serves the folder (a phone's add is audited there), then its window opens. */
    private fun openHere(s: Sheet) {
        val b = browser ?: return
        if (!b.canOpen) return
        val at = b.path ?: return
        ask(dev.kore.link.node.Control.folderAdd(at)) { r ->
            if (!r.bool("ok")) { b.refused(boxWords(r)); return@ask s.refresh() }
            val wid = r.str("windowId") ?: r.objs("folders").firstOrNull { it.str("path")?.trimEnd('/') == at }?.str("windowId")
            s.dismiss()
            if (wid != null) openBoxWindow(wid) else Quiet.say(this, "Opened on $macName")
        }
    }

    /** A box window by id: a closed one comes back first (`window.open`); an open one just opens. */
    private fun openBoxWindow(wid: String) {
        val window = Intent(this, WindowActivity::class.java).putExtra("window", wid)
        if (last?.objs("windows")?.any { it.str("id") == wid } == true) startActivity(window)
        else act(dev.kore.link.node.Control.windowShow(wid)) { startActivity(window) }
    }

    /** A box's refusal in its own words where they say what to change (a path, a name). */
    private fun boxWords(r: JsonObject): String {
        val code = r.str("code")
        val own = code == "denied.path" || code == "invalid" || code?.startsWith("gone") == true
        return r.str("message")?.takeIf { own && it.isNotBlank() } ?: refusalWords(code)
    }

    /** One command to this device, answered on the UI thread (a refusal comes back as the result). */
    private fun ask(cmd: JsonObject, done: (JsonObject) -> Unit) {
        val node = link ?: return Quiet.say(this, "Not connected")
        kore.scope.launch {
            val r = node.call(cmd, 20_000)
            runOnUiThread { done(r) }
        }
    }

    /** A box: the folders it already serves (marked in the browser; listed when it can't browse). */
    private fun readBoxFolders(s: Sheet) {
        val node = link ?: return
        kore.scope.launch {
            val r = node.call(dev.kore.link.node.Control.foldersList())
            runOnUiThread {
                if (!r.bool("ok")) return@runOnUiThread s.say(refusalWords(r.str("code"), r.str("message")))
                boxFolders = r.objs("folders")
                if (s.isShowing) s.refresh()
            }
        }
    }

    private var folderSheet: Sheet? = null

    private fun windowMenu(anchor: View, w: JsonObject) {
        val id = w.str("id") ?: return
        val C = dev.kore.link.node.Control
        PopMenu(this).show(anchor, listOfNotNull(
            PopMenu.Item("History") { history(id) },
            pasteItem(id, w.str("name") ?: "this window"),
            PopMenu.Item("Close window", danger = true, rule = true) {
                act(C.windowClose(id), forced = C.windowClose(id, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
            },
        ))
    }

    /** Paste chat on a window while a chat is held and this device's Mac copies from here. */
    private fun pasteItem(windowId: String, name: String): PopMenu.Item? {
        val l = link ?: return null
        if (kore.chatClip == null || !copyOffered(l)) return null
        return PopMenu.Item("Paste chat") { pasteChat(l, windowId, name) }
    }

    /** A window's past chats; a tap there opens one here, in that window. */
    private fun history(windowId: String) = startActivity(Intent(this, HistoryActivity::class.java).putExtra("window", windowId))

    /**
     * A chat's row held: Pin or Unpin (this phone's own, any grant), then with control Show on the
     * Mac (a Mac's) and Close tab, refused while it would lose work.
     */
    private fun rowMenu(anchor: View, row: DeviceList.Row) {
        val chatId = row.chatId ?: return
        val chat = last?.chatsById()?.get(chatId) ?: return
        val items = ArrayList<PopMenu.Item>()
        val device = host
        if (device != null && row.pinKeys.isNotEmpty()) items += PopMenu.Item(kore.pins.word(device, row.pinKeys)) {
            kore.pins.set(device, row.pinKeys, !row.pinned)
            draw()
        }
        val wid = row.windowId
        if (device != null && wid != null && copyOffered(link)) items += PopMenu.Item("Copy") {
            copyChat(ChatCopy.Clip(device, macName, wid, chatId, null, chat.str("provider") ?: "claude", chat.str("title") ?: row.title))
        }
        if (link.hasControl(last)) {
            if (!isBox) items += PopMenu.Item("Show on the Mac") { act(dev.kore.link.node.Control.select(chatId)) { Quiet.say(this, "Shown on $macName") } }
            if (CloseHold.offered(chat, isBox)) items += PopMenu.Item("Close tab", danger = true, rule = items.isNotEmpty()) { closeChat(chat) }
        }
        if (items.isNotEmpty()) PopMenu(this).show(anchor, items)
    }

    /** Once per opening, while the device is up: its CLIs' logins read again where due (at most once a minute each). */
    private fun askUsage() {
        val node = link ?: return
        if (askedUsage || linkState != dev.kore.link.node.NodeMachine.State.Up) return
        askedUsage = true
        node.askUsage(node.welcome.value?.objs("providers").orEmpty().mapNotNull { it.str("id") })
    }

    /** The Accounts block at the list's foot: one item, made again only when a login's usage changed. */
    private inner class Accounts : ListAdapter<List<UsageMeters.Row>, RecyclerView.ViewHolder>(object : DiffUtil.ItemCallback<List<UsageMeters.Row>>() {
        override fun areItemsTheSame(a: List<UsageMeters.Row>, b: List<UsageMeters.Row>) = true
        override fun areContentsTheSame(a: List<UsageMeters.Row>, b: List<UsageMeters.Row>) = a == b
    }) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder =
            object : RecyclerView.ViewHolder(android.widget.FrameLayout(this@DeviceActivity).apply {
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            }) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val frame = holder.itemView as android.widget.FrameLayout
            frame.removeAllViews()
            frame.addView(usageBlock(getItem(position)), android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    /** The rows, diffed: a snapshot rebinds only the rows that changed. */
    private inner class Rows : ListAdapter<DeviceList.Row, RecyclerView.ViewHolder>(object : DiffUtil.ItemCallback<DeviceList.Row>() {
        override fun areItemsTheSame(a: DeviceList.Row, b: DeviceList.Row) = a.key == b.key
        override fun areContentsTheSame(a: DeviceList.Row, b: DeviceList.Row) = a == b
    }) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder = object : RecyclerView.ViewHolder(chatCard()) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val row = getItem(position)
            bindChatCard(holder.itemView as LinearLayout, row)
            holder.itemView.setOnLongClickListener(row.chatId?.let { View.OnLongClickListener { v -> rowMenu(v, row); true } })
        }
    }
}
