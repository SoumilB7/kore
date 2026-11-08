package dev.kore.phone.ui

import android.content.Intent
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.kore.phone.kore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * One device (a Mac or a box): its windows as sections of their chats, a "Needs you" strip when a
 * chat waits on you, and ＋ for a new chat or a new window there (phase 18 §3: Kore's recent
 * folders on a Mac, folders already open on a box). Pulling down re-reads what it sent; the list
 * is live either way.
 */
class DeviceActivity : NodeActivity() {
    private var last: JsonObject? = null
    private var plus: android.widget.TextView? = null

    override fun body(): View {
        plus = barButton(barTitle, "＋", "New") { createSheet() }.apply { visibility = View.GONE }
        return PullScroll(this) { render(last); flash("Up to date") }.apply { addView(content) }
    }

    override fun render(snapshot: JsonObject?) {
        last = snapshot
        barTitle.text = macName
        content.removeAllViews()
        stateLine()?.let(content::addView)
        plus?.visibility = if (snapshot != null && linkState == dev.kore.link.node.NodeMachine.State.Up) View.VISIBLE else View.GONE
        if (snapshot == null) {
            if (linkState == dev.kore.link.node.NodeMachine.State.Up || linkState == dev.kore.link.node.NodeMachine.State.Connecting) {
                content.addView(empty("Waiting for $macName…", "It shows here as soon as Kore there answers."))
            }
            return
        }
        val chats = snapshot.chatsById()
        val windows = snapshot.objs("windows")
        val waiting = chats.values.filter { it.str("state") == "needsYou" }
        if (waiting.isNotEmpty()) content.addView(needsYou(waiting))
        if (windows.isEmpty()) {
            content.addView(empty("No windows open", "Open a folder in Kore there and it appears here."))
            return
        }
        val control = link.hasControl(snapshot)
        for (w in windows) {
            content.addView(section(w.str("name") ?: "Window", w.str("path")).apply {
                // Tap a window's header: its tabs, ＋ and History. Long-press: Close window.
                setOnClickListener { startActivity(Intent(this@DeviceActivity, WindowActivity::class.java).putExtra("window", w.str("id"))) }
                if (control) setOnLongClickListener { v -> windowMenu(v, w); true }
            })
            var any = false
            for (tab in w.objs("tabs")) {
                when (tab.str("kind")) {
                    "chat", "agent" -> chats[tab.str("chatId")]?.let { chatRow(it, tab.str("title")); any = true }
                    "board" -> {
                        val ids = tab.obj("board")?.objs("sections").orEmpty().flatMap { it.strs("chatIds") }
                        val states = ids.mapNotNull { chats[it]?.str("state") }
                        val (dot, word) = stateLook(states.firstOrNull { it == "needsYou" } ?: states.firstOrNull { it == "working" } ?: "idle")
                        content.addView(row("▦  ${tab.str("title") ?: "Board"}", "${ids.size} chats · $word", dot) {
                            startActivity(Intent(this, WindowActivity::class.java).putExtra("window", w.str("id")))
                        })
                        any = true
                    }
                    else -> Unit
                }
            }
            // A box's window lists its chats without tabs.
            if (!any) for (chat in chats.values.filter { it.str("windowId") == w.str("id") }) { chatRow(chat, null); any = true }
            if (!any) content.addView(label("No chats in this window", 13f, K.faint).apply { setPadding(dp(4), 0, 0, dp(8)) })
        }
        folderSheet?.takeIf { it.isShowing }?.refresh()
    }

    /** Why the device isn't up, in one line, and the one thing to do about it. */
    private fun stateLine(): View? {
        val s = linkState ?: return null
        val node = link ?: return null
        val (text, action) = when (s) {
            is dev.kore.link.node.NodeMachine.State.Away -> when (s.why) {
                dev.kore.link.node.NodeMachine.AwayWhy.ASLEEP -> listOfNotNull("$macName is asleep", lastSeenWords(node.lastSeen)).joinToString(" · ") to null
                dev.kore.link.node.NodeMachine.AwayWhy.OFF -> "$macName took this phone offline" to null
                dev.kore.link.node.NodeMachine.AwayWhy.UNREACHABLE -> "$macName is offline · retrying" to ("Retry" to { node.reconnectNow() })
            }
            is dev.kore.link.node.NodeMachine.State.Denied -> "$macName hasn't allowed this phone" to ("Try again" to { node.reconnectNow() })
            dev.kore.link.node.NodeMachine.State.Removed -> "$macName removed this phone" to ("Forget" to { kore.mesh.forget(node.id); finish() })
            dev.kore.link.node.NodeMachine.State.SignedOut -> "Signed out of Tailscale" to ("Sign in" to { startActivity(Intent(this, JoinActivity::class.java).putExtra("signIn", true)) })
            dev.kore.link.node.NodeMachine.State.Idle -> if (!kore.mesh.networkOn) "KoreNet is off on this phone" to ("Turn on" to { kore.mesh.networkOn = true }) else return null
            else -> return null
        }
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

    /** ＋: a new chat in one of the device's windows, or a new window (phase 18 §3's limits). */
    private fun createSheet() {
        val snap = last ?: return
        val providers = link?.welcome?.value?.objs("providers").orEmpty()
        val box = link?.device?.value?.kind == dev.kore.link.trust.NodeKind.BOX
        lateinit var s: Sheet
        s = Sheet(this).show {
            title("New on $macName")
            for (w in snap.objs("windows")) {
                val wid = w.str("id") ?: continue
                for (p in providers) {
                    val pid = p.str("id") ?: continue
                    item("${p.str("name") ?: pid} chat", glyph = providerMark(pid), detail = w.str("name"), tag = "New ${p.str("name")} chat in ${w.str("name")}") {
                        s.dismiss()
                        val cmd = if (box && w.str("path") != null) dev.kore.link.node.Control.newChatInFolder(w.str("path")!!, pid) else dev.kore.link.node.Control.newChat(wid, pid)
                        act(cmd) { r ->
                            r.str("chatId")?.let { startActivity(Intent(this@DeviceActivity, ChatActivity::class.java).putExtra("chat", it)) }
                                ?: Quiet.say(this@DeviceActivity, "Started on $macName")
                        }
                    }
                }
            }
            item("New window", glyph = "□") { s.dismiss(); if (box) boxFolders() else openFolder() }
        }
    }

    /** A box: the folders it already serves (a new folder is the Mac's to add). */
    private fun boxFolders() {
        val node = link ?: return
        kore.scope.launch {
            val r = node.call(dev.kore.link.node.Control.foldersList())
            runOnUiThread {
                if (!r.bool("ok")) return@runOnUiThread Quiet.say(this@DeviceActivity, refusalWords(r.str("code")))
                lateinit var s: Sheet
                s = Sheet(this@DeviceActivity).show {
                    title("Folders on $macName", "Folders already open there. Adding one is done on the Mac.")
                    for (f in r.objs("folders")) {
                        val wid = f.str("windowId") ?: continue
                        item((f.str("path") ?: "Folder").trimEnd('/').substringAfterLast('/'), glyph = "□", detail = ControlModel.parentOf(f.str("path")), enabled = !f.bool("missing")) {
                            s.dismiss()
                            startActivity(Intent(this@DeviceActivity, WindowActivity::class.java).putExtra("window", wid))
                        }
                    }
                }
            }
        }
    }

    private var folderSheet: Sheet? = null

    /** A Mac: Kore's recent folders, Reopen closed window, and any other folder (that one needs the Mac). */
    private fun openFolder() {
        lateinit var s: Sheet
        s = Sheet(this).show {
            val mac = last?.obj("mac") ?: return@show dismiss()
            title("Open a folder", "Folders Kore opened before.")
            for (r in mac.objs("recents")) {
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
            val other = item("Another folder", glyph = " ") { say("Pick any other folder on the Mac: it needs the Mac's file picker.") } as LinearLayout
            (other.getChildAt(1) as android.widget.TextView).setTextColor(K.dim)
            other.addView(label("on the Mac", 11f, K.faint).apply {
                background = rounded(android.graphics.Color.TRANSPARENT, 6, android.graphics.Color.parseColor("#2F3337"))
                setPadding(dp(6), dp(1), dp(6), dp(2))
            })
        }
        folderSheet = s
        s.onDismiss { folderSheet = null }
    }

    private fun windowMenu(anchor: View, w: JsonObject) {
        val id = w.str("id") ?: return
        val C = dev.kore.link.node.Control
        PopMenu(this).show(anchor, listOf(PopMenu.Item("Close window", danger = true) {
            act(C.windowClose(id), forced = C.windowClose(id, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
        }))
    }

    private fun chatRow(chat: JsonObject, fallback: String?) {
        val (dot, word) = stateLook(chat.str("state"))
        content.addView(row(chat.str("title") ?: fallback ?: "Chat", word, dot, providerMark(chat.str("provider"))) {
            startActivity(Intent(this, ChatActivity::class.java).putExtra("chat", chat.str("id")))
        })
    }

    /** One amber strip: how many chats wait on you; a tap opens the first. */
    private fun needsYou(waiting: List<JsonObject>): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(14), dp(10), dp(14), dp(10))
        background = rounded(android.graphics.Color.parseColor("#2A2316"), 12, android.graphics.Color.parseColor("#4A3A1C"))
        val first = waiting.first()
        val words = if (waiting.size == 1) "Needs you" else "${waiting.size} chats need you"
        addView(label("$words · ${first.str("title") ?: "a chat"}", 14f, K.warn).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(label("›", 18f, K.warn))
        setOnClickListener { startActivity(Intent(this@DeviceActivity, ChatActivity::class.java).putExtra("chat", first.str("id"))) }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(14) }
    }

    /** A window as a section: its folder name, and the path faint beside it. */
    private fun section(name: String, path: String?): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.BOTTOM
        setPadding(dp(4), dp(12), dp(4), dp(8))
        addView(label(name, 13f, K.dim, bold = true))
        if (!path.isNullOrBlank()) addView(label("  $path", 12f, K.faint).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.START },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
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

    private fun flash(text: String) = android.widget.Toast.makeText(this, text, android.widget.Toast.LENGTH_SHORT).show()
}

/** A scroll view that calls [onPull] when dragged down past its top. */
class PullScroll(context: android.content.Context, private val onPull: () -> Unit) : ScrollView(context) {
    private var startY = -1f
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> startY = if (scrollY == 0) e.y else -1f
            MotionEvent.ACTION_UP -> {
                if (startY >= 0 && e.y - startY > resources.displayMetrics.density * 96) onPull()
                startY = -1f
            }
        }
        return super.onTouchEvent(e)
    }
}
