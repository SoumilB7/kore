package dev.kore.phone.ui

import android.content.Intent
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import dev.kore.link.node.Control
import dev.kore.phone.kore
import kotlinx.serialization.json.JsonObject

/**
 * One window: its tabs in order, runs of a tab group under the group's coloured header. Chats
 * open; boards list their sections' chats; files show but don't open. ＋ starts a chat or a
 * board; a long-press on a tab, a group header or a section header holds its menu; one History
 * row closes the list.
 */
class WindowActivity : NodeActivity() {
    private val windowId by lazy { intent.getStringExtra("window") ?: "" }
    private var plus: android.view.View? = null
    private var snapshot: JsonObject? = null
    /** Groups opened or folded on the phone only; the Mac's fold is where each starts. */
    private val unfolded = HashMap<String, Boolean>()
    private var newSheet: Sheet? = null

    private var more: android.view.View? = null
    private val isBox get() = link?.device?.value?.kind == dev.kore.link.trust.NodeKind.BOX
    /** What the device says it does (groups and boards are a Mac's). */
    private fun caps(): Set<String> = kore.mesh.caps(link)

    override fun body(): View {
        more = barButton(barTitle, "⋮", "More") { windowSheet() }.apply { visibility = View.GONE }
        plus = barButton(barTitle, "＋", "New") { openNew() }.apply { visibility = View.GONE }
        return super.body()
    }

    /** ⋮ (spec §6): Show on the Mac (its active chat comes forward) and Close window. */
    private fun windowSheet() {
        val w = snapshot?.objs("windows")?.firstOrNull { it.str("id") == windowId } ?: return
        val shown = w.objs("tabs").firstOrNull { it.str("id") == w.str("activeTabId") }?.str("chatId")
            ?: w.objs("tabs").firstOrNull { it.str("chatId") != null }?.str("chatId")
        lateinit var s: Sheet
        s = Sheet(this).show {
            title(w.str("name") ?: "Window", w.str("path"))
            if (link?.device?.value?.kind != dev.kore.link.trust.NodeKind.BOX) item("Show on the Mac", glyph = "Show on the Mac", enabled = shown != null) { s.dismiss(); shown?.let { id -> act(Control.select(id)) { Quiet.say(this@WindowActivity, "Shown on $macName") } } }
            item("Close window", glyph = "Close window", danger = true) {
                s.dismiss()
                act(Control.windowClose(windowId), forced = Control.windowClose(windowId, force = true), ask = "A chat in ${w.str("name") ?: "this window"} is working. Closing stops it.")
            }
        }
    }

    /** What was last drawn: a change elsewhere on the device draws nothing here. */
    private var shown: Any? = null

    override fun render(snapshot: JsonObject?) {
        this.snapshot = snapshot
        val w = snapshot?.objs("windows")?.firstOrNull { it.str("id") == windowId }
        val control = link.hasControl(snapshot)
        val chats = snapshot?.chatsById().orEmpty()
        val look = listOf(snapshot == null, w, w?.let { usedChats(it).map { id -> chats[id] } }, control, unfolded.toMap(), macName)
        if (look == shown) {
            newSheet?.takeIf { it.isShowing }?.refresh()
            return
        }
        shown = look
        content.removeAllViews()
        if (w == null) {
            more?.visibility = View.GONE
            plus?.visibility = View.GONE
            content.addView(if (snapshot == null) emptyState(dev.kore.phone.R.drawable.i_laptop, "Waiting for $macName", "It shows here as soon as Kore there answers.", waiting = true)
                else emptyState(dev.kore.phone.R.drawable.i_folder, "This window was closed", "It's no longer open in Kore on $macName."))
            return
        }
        plus?.visibility = if (control) View.VISIBLE else View.GONE
        more?.visibility = if (control) View.VISIBLE else View.GONE
        barTitle.text = w.str("name") ?: ""
        // Its folder (spec §6): Mono 12, faint.
        content.addView(label(w.str("path") ?: "").apply {
            type(Type.Mono); textSize = 12f; setTextColor(Tone.faint)
            maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            setPadding(dp(4), dp(2), dp(4), dp(10))
        })
        if (w.objs("tabs").none { it.str("kind") == "chat" || it.str("kind") == "agent" || it.str("kind") == "board" }) {
            content.addView(emptyState(dev.kore.phone.R.drawable.i_chat, "No chats here yet", "A new chat opens as a tab in ${w.str("name") ?: "this window"} on $macName.",
                if (control) "New chat" to { openNew() } else null))
            // Its past chats stay a tap away with no tab open (one opens here).
            if (control) historyRow(w)
            return
        }
        val segments = ControlModel.segments(w)
        val grouped = segments.any { it is ControlModel.Segment.Group }
        var labelled = false
        for (seg in segments) when (seg) {
            is ControlModel.Segment.Group -> {
                val g = seg.group
                val gid = g.str("id") ?: continue
                val open = unfolded[gid] ?: !g.bool("folded")
                content.addView(groupHeader(g, seg.tabs.size, open))
                if (open) seg.tabs.forEach { tab(w, it, chats, control) }
                labelled = false
            }
            is ControlModel.Segment.Tab -> {
                // After a group, the loose tabs get their own small label, as on the Mac's strip.
                if (grouped && !labelled) {
                    content.addView(sectionLabel("Tabs"))
                    labelled = true
                }
                tab(w, seg.tab, chats, control)
            }
        }
        // One grouped History row closes the list (spec §6).
        if (control) historyRow(w)
        newSheet?.takeIf { it.isShowing }?.refresh()
    }

    /** The window's History: its closed chats, a tap opening one here. */
    private fun historyRow(w: JsonObject) {
        content.addView(grouped(listOf(groupRow(dev.kore.phone.R.drawable.i_archive, "History", "Closed chats in ${w.str("name") ?: "this window"}", chevron = true) {
            startActivity(Intent(this, HistoryActivity::class.java).putExtra("window", windowId))
        })), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })
    }

    /** The chats this window's tabs and boards show, in order. */
    private fun usedChats(w: JsonObject): List<String?> = w.objs("tabs").flatMap { tab ->
        if (tab.str("kind") == "board") tab.obj("board")?.objs("sections").orEmpty().flatMap { it.strs("chatIds") } else listOf(tab.str("chatId"))
    }

    private fun tab(w: JsonObject, tab: JsonObject, chats: Map<String, JsonObject>, control: Boolean) {
        when (tab.str("kind")) {
            "chat", "agent" -> chatRow(chats[tab.str("chatId")], tab.str("title"), control = control)?.let { row ->
                if (control) row.setOnLongClickListener { tabMenu(it, w, tab, chats[tab.str("chatId")]); true }
            }
            "board" -> {
                content.addView(sectionLabel(tab.str("title") ?: "Board"))
                // Every chat on the board, in order: a chat opened from here swipes to its neighbours.
                val sections = tab.obj("board")?.objs("sections").orEmpty()
                val order = sections.flatMap { it.strs("chatIds") }.toTypedArray()
                for (section in sections) {
                    val name = section.str("name")
                    if (!name.isNullOrBlank() || (control && sections.size > 1)) {
                        val head = sectionHeader(name?.takeIf { it.isNotBlank() } ?: "Section", section.str("swatch"))
                        if (control) head.setOnLongClickListener { sectionMenu(it, tab, section); true }
                        content.addView(head)
                    }
                    section.strs("chatIds").forEach { id ->
                        chatRow(chats[id], null, order, control)?.let { row ->
                            if (control) row.setOnLongClickListener { boardChatMenu(it, tab, chats[id]); true }
                        }
                    }
                }
            }
            "file" -> content.addView(grouped(listOf(groupRow(dev.kore.phone.R.drawable.i_file_doc, tab.str("title") ?: "File", "Open on $macName"))),
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
            else -> Unit
        }
    }

    /** A chat's row card (spec §5), the Device screen's own: lead, title and age, symbols and its state or last word. */
    private fun chatRow(chat: JsonObject?, fallback: String?, board: Array<String>? = null, control: Boolean = false): View? {
        if (chat == null) return null
        val row = DeviceList.chatRow(chat, windowId, "", false, System.currentTimeMillis(), kore.seen)?.let { if (fallback != null && chat.str("title") == null) it.copy(title = fallback) else it } ?: return null
        val v = chatCard()
        bindChatCard(v, row) {
            startActivity(Intent(this, ChatActivity::class.java).putExtra("chat", chat.str("id")).apply { if (board != null) putExtra("board", board) })
        }
        content.addView(v)
        return v
    }

    /** A tab group (spec §6): an 8 square in its colour, its name (Label), its count at the end, a chevron that turns when open. */
    private fun groupHeader(g: JsonObject, count: Int, open: Boolean): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(44)
        setPadding(dp(6), dp(10), dp(6), dp(6))
        addView(View(context).apply { background = shape(groupColor(g.str("color")), 2) }, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(10) })
        val name = g.str("name")?.ifBlank { null } ?: "Group"
        addView(label(name).apply { type(Type.Label); setTextColor(Tone.dim) }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(label("$count").apply { type(Type.Caption); setTextColor(Tone.faint) })
        addView(android.widget.ImageView(context).apply {
            setImageResource(dev.kore.phone.R.drawable.i_chevron)
            imageTintList = android.content.res.ColorStateList.valueOf(Tone.faint)
            rotation = if (open) 90f else 0f
        }, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginStart = dp(8) })
        contentDescription = "Group $name, $count, ${if (open) "open" else "folded"}"
        val gid = g.str("id") ?: ""
        setOnClickListener { unfolded[gid] = !open; render(snapshot) }
        setOnLongClickListener { groupMenu(it, g); true }
        pressFill(null, Tone.l1, 10)
    }

    private fun sectionHeader(name: String, swatch: String?): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(8), dp(4), dp(4), dp(6))
        swatchColor(swatch)?.let { addView(View(context).apply { background = shape(it, 2) }, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(8) }) }
        addView(label(name).apply { type(Type.Caption); setTextColor(Tone.faint) })
        contentDescription = "Section $name"
    }

    // Long-press menus (frame 4)

    private fun tabMenu(anchor: View, w: JsonObject, tab: JsonObject, chat: JsonObject?) {
        val chatId = chat?.str("id") ?: return
        val tabId = tab.str("id") ?: return
        val can = chat.obj("can")
        val groups = w.objs("groups")
        val boards = w.objs("tabs").filter { it.str("kind") == "board" }
        val items = ArrayList<PopMenu.Item>()
        items += PopMenu.Item("Rename…", enabled = can?.bool("rename") != false) { renameSheet(chat.str("title").orEmpty()) { act(Control.rename(chatId, it)) } }
        if (!isBox) items += PopMenu.Item("Show on the Mac") { act(Control.select(chatId)) { Quiet.say(this, "Shown on the Mac") } }
        val offered = Offers.tabItems(caps(), isBox, boards.isNotEmpty(), CloseHold.offered(chat, isBox))
        if ("Group" in offered) items += PopMenu.Item("Group", sub = {
            groups.map { g ->
                PopMenu.Item(g.str("name")?.ifBlank { null } ?: "Group", dot = groupColor(g.str("color")), checked = g.str("id") == tab.str("groupId")) {
                    if (g.str("id") != tab.str("groupId")) act(Control.groupSet(windowId, tabId, g.str("id")))
                }
            } + PopMenu.Item("New group") { act(Control.groupSet(windowId, tabId, Control.NEW_GROUP)) } +
                listOfNotNull(tab.str("groupId")?.let { PopMenu.Item("Remove from group", rule = true) { act(Control.groupSet(windowId, tabId, null)) } })
        })
        if ("Attach to board" in offered) items += PopMenu.Item("Attach to board", sub = {
            boards.flatMap { b ->
                val bid = b.str("id") ?: return@flatMap emptyList()
                val sections = b.obj("board")?.objs("sections").orEmpty()
                val name = b.str("title") ?: "Board"
                if (sections.size <= 1) listOf(PopMenu.Item(name) { act(Control.boardAttach(windowId, chatId, bid, sections.firstOrNull()?.str("id"))) })
                else sections.map { s -> PopMenu.Item("$name · ${s.str("name")?.ifBlank { null } ?: "Section"}") { act(Control.boardAttach(windowId, chatId, bid, s.str("id"))) } } +
                    PopMenu.Item("$name · New section") { act(Control.boardAttach(windowId, chatId, bid, Control.NEW_SECTION)) }
            }
        })
        if ("Close tab" in offered) items += PopMenu.Item("Close tab", danger = true, rule = true) { closeChat(chat) }
        PopMenu(this).show(anchor, items)
    }

    private fun boardChatMenu(anchor: View, board: JsonObject, chat: JsonObject?) {
        val chatId = chat?.str("id") ?: return
        val boardId = board.str("id") ?: return
        val can = chat.obj("can")
        PopMenu(this).show(anchor, listOfNotNull(
            PopMenu.Item("Rename…", enabled = can?.bool("rename") != false) { renameSheet(chat.str("title").orEmpty()) { act(Control.rename(chatId, it)) } },
            PopMenu.Item("Show on the Mac") { act(Control.select(chatId)) { Quiet.say(this, "Shown on the Mac") } },
            PopMenu.Item("Move to its own tab") { act(Control.boardDetach(windowId, boardId, chatId, toTab = false)) },
            PopMenu.Item("Close", danger = true, rule = true) { closeChat(chat) }.takeIf { CloseHold.offered(chat, isBox) },
        ))
    }

    private fun groupMenu(anchor: View, g: JsonObject) {
        val gid = g.str("id") ?: return
        val folded = g.bool("folded")
        PopMenu(this).show(anchor, listOf(
            PopMenu.Item("Rename…") { renameSheet(g.str("name").orEmpty()) { act(Control.groupEdit(windowId, gid, name = it)) } },
            PopMenu.Item("Colour", sub = {
                GROUP_COLORS.map { c -> PopMenu.Item(c.replaceFirstChar { it.uppercase() }, dot = groupColor(c), checked = c == g.str("color")) { act(Control.groupEdit(windowId, gid, color = c)) } }
            }),
            PopMenu.Item(if (folded) "Unfold" else "Fold") { unfolded.remove(gid); act(Control.groupEdit(windowId, gid, folded = !folded)) },
            PopMenu.Item("Ungroup") { act(Control.groupUngroup(windowId, gid)) },
            PopMenu.Item("Close group", danger = true, rule = true) {
                act(Control.groupClose(windowId, gid), forced = Control.groupClose(windowId, gid, force = true), ask = "A chat in this group is working. Closing stops it.")
            },
        ))
    }

    private fun sectionMenu(anchor: View, board: JsonObject, section: JsonObject) {
        val bid = board.str("id") ?: return
        val sid = section.str("id") ?: return
        val others = board.obj("board")?.objs("sections").orEmpty().filter { it.str("id") != sid }
        PopMenu(this).show(anchor, listOf(
            PopMenu.Item("Rename…") { renameSheet(section.str("name").orEmpty()) { act(Control.boardSection(windowId, bid, sid, Control.SectionChange.Name(it))) } },
            PopMenu.Item("Colour", sub = {
                listOf(PopMenu.Item("None", checked = section.str("swatch") == null) { act(Control.boardSection(windowId, bid, sid, Control.SectionChange.Swatch(null))) }) +
                    SWATCHES.map { sw ->
                        PopMenu.Item(if (sw == "neutral") "Neutral" else "Blue ${sw.drop(1)}", dot = swatchColor(sw), checked = sw == section.str("swatch")) {
                            act(Control.boardSection(windowId, bid, sid, Control.SectionChange.Swatch(sw)))
                        }
                    }
            }),
            PopMenu.Item("Merge into", enabled = others.isNotEmpty(), sub = {
                others.map { o -> PopMenu.Item(o.str("name")?.ifBlank { null } ?: "Section") { act(Control.boardSection(windowId, bid, sid, Control.SectionChange.MergeInto(o.str("id") ?: ""))) } }
            }),
            PopMenu.Item("Remove", danger = true, rule = true) { act(Control.boardSection(windowId, bid, sid, Control.SectionChange.Remove)) },
        ))
    }

    // ＋ (frame 4, middle): a new chat with its model, a board, where it goes, and Reopen closed tab.

    private val newModel = HashMap<String, String?>()
    private var place: Control.Place? = null
    private var choosingModel: String? = null

    private fun openNew() {
        place = null
        choosingModel = null
        newSheet = Sheet(this).show { newContent() }.also { s -> s.onDismiss { newSheet = null } }
    }

    private fun Sheet.newContent() {
        val w = snapshot?.objs("windows")?.firstOrNull { it.str("id") == windowId } ?: return dismiss()
        val providers = link?.welcome?.value?.objs("providers").orEmpty()
        val picking = choosingModel
        if (picking != null) {
            val name = providers.firstOrNull { it.str("id") == picking }?.str("name") ?: picking
            title("$name model")
            item("Default", checked = newModel[picking] == null) { newModel[picking] = null; choosingModel = null; refresh() }
            for (m in ControlModel.models(snapshot, picking)) {
                val id = m.str("id") ?: continue
                item(m.str("name") ?: id, checked = newModel[picking] == id) { newModel[picking] = id; choosingModel = null; refresh() }
            }
            return
        }
        title("New")
        for (p in providers) {
            val id = p.str("id") ?: continue
            val models = ControlModel.models(snapshot, id)
            val chosen = newModel[id]?.let { m -> models.firstOrNull { it.str("id") == m }?.str("name") } ?: "default"
            val row = item("${p.str("name") ?: id} chat", glyph = providerMark(id), detail = chosen, chevron = models.isNotEmpty(), tag = "New ${p.str("name")} chat") {
                dismiss()
                act(Control.newChat(windowId, id, newModel[id], place)) { r ->
                    r.str("chatId")?.let { startActivity(Intent(this@WindowActivity, ChatActivity::class.java).putExtra("chat", it)) }
                        ?: Quiet.say(this@WindowActivity, "Started on $macName")
                }
            } as LinearLayout
            // The model on the right is its own tap: it picks the model before the first send.
            if (models.isNotEmpty()) row.getChildAt(row.childCount - 1).apply {
                setPadding(dp(16), dp(8), 0, dp(8))
                contentDescription = "Model for ${p.str("name")}"
                setOnClickListener { choosingModel = id; refresh() }
            }
        }
        val more = Offers.newItems(caps(), w.bool("canReopenTab"))
        if ("Board" in more) item("Board", glyph = "▦") { dismiss(); act(Control.boardNew(windowId)) { Quiet.say(this@WindowActivity, "New board on $macName") } }
        val boards = w.objs("tabs").filter { it.str("kind") == "board" }
        val groups = w.objs("groups")
        if (boards.isNotEmpty() || groups.isNotEmpty()) {
            section("Put it in")
            item("A new tab", checked = place == null) { place = null; refresh() }
            for (b in boards) {
                val bid = b.str("id") ?: continue
                val sections = b.obj("board")?.objs("sections").orEmpty()
                val here = (place as? Control.Place.Board)?.takeIf { it.boardTabId == bid }
                val shown = sections.firstOrNull { it.str("id") == here?.sectionId } ?: sections.firstOrNull()
                item(b.str("title") ?: "Board", detail = if (sections.size > 1) (shown?.str("name")?.ifBlank { null } ?: "Section") else null,
                    chevron = sections.size > 1 && here == null, checked = here != null) {
                    // A board with sections: each tap moves on to its next section.
                    val i = sections.indexOfFirst { it.str("id") == here?.sectionId }
                    place = Control.Place.Board(bid, sections.getOrNull(if (here == null) maxOf(0, i) else (i + 1) % maxOf(1, sections.size))?.str("id"))
                    refresh()
                }
            }
            for (g in groups) {
                val gid = g.str("id") ?: continue
                item("Group ${g.str("name").orEmpty()}".trim(), dot = groupColor(g.str("color")), checked = (place as? Control.Place.Group)?.groupId == gid) {
                    place = Control.Place.Group(gid); refresh()
                }
            }
        }
        if ("Reopen closed tab" in more) item("Reopen closed tab", glyph = "↺") { dismiss(); act(Control.tabReopen(windowId)) }
    }
}

/** A quiet outlined row (History, Open a folder): a list's last line. */
fun android.app.Activity.quietRow(title: String, detail: String? = null, go: () -> Unit): View = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(dp(14), dp(13), dp(14), dp(13))
    background = rounded(android.graphics.Color.TRANSPARENT, 12, Tone.hair2)
    addView(label(title, 15f, K.dim), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    addView(label(listOfNotNull(detail, "›").joinToString(" "), 12f, K.faint))
    contentDescription = title
    setOnClickListener { go() }
    pressable(12)
    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) }
}

/** One field and Rename: chats, groups, sections, history rows. */
fun android.app.Activity.renameSheet(current: String, go: (String) -> Unit) {
    lateinit var s: Sheet
    s = Sheet(this).show {
        title("Rename")
        val f = field("Name", current)
        buttons("Rename") {
            val t = f.text.toString().trim()
            if (t.isEmpty()) return@buttons say("A name can't be empty.")
            s.dismiss(); go(t)
        }
    }
}
