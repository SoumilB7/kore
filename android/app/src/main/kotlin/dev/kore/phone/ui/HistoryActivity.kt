package dev.kore.phone.ui

import android.content.Intent
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.kore.link.node.Control
import dev.kore.phone.kore
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * A window's history, as the Mac's panel (L7–L9): search, newest first under day headers, ▣
 * for the archived ones. A tap opens the chat in this window (a background tab on a Mac) and
 * here; a long-press offers Open here, Rename and Archive. Read a page at a time with `history.list`.
 */
class HistoryActivity : NodeActivity() {
    private val windowId by lazy { intent.getStringExtra("window") ?: "" }
    private val rows = ArrayList<JsonObject>()
    private var more = false
    private var archived = false
    private var query = ""
    private var reading: Job? = null
    private var started = false
    private lateinit var list: LinearLayout
    private lateinit var archiveButton: android.view.View
    private lateinit var state: LinearLayout

    override fun body(): View {
        archiveButton = barButton(barTitle, "▣", "Archived") { archived = !archived; load(reset = true) }
        // The search field (spec §6): 44 high, radius 22, l1 with a hair edge, a search icon, Body.
        val search = EditText(this).apply {
            hint = "Search"
            type(Type.Body)
            setHintTextColor(Tone.faint)
            setTextColor(Tone.text)
            background = shape(Tone.l1, 22, Tone.hair)
            minHeight = dp(44)
            setPadding(dp(14), 0, dp(14), 0)
            setCompoundDrawablesRelativeWithIntrinsicBounds(getDrawable(dev.kore.phone.R.drawable.i_search)?.mutate()?.apply {
                setTint(Tone.faint); setBounds(0, 0, dp(18), dp(18))
            }, null, null, null)
            compoundDrawablePadding = dp(10)
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            contentDescription = "Search chats"
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                // Typing settles before a read: the Mac takes two a second.
                override fun afterTextChanged(s: Editable?) { query = s.toString().trim(); load(reset = true, wait = 400) }
            })
        }
        list = column()
        state = column()
        content.addView(search, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(44)).apply { bottomMargin = dp(4) })
        content.addView(list)
        content.addView(state)
        return object : ScrollView(this) {
            override fun onScrollChanged(l: Int, t: Int, oldl: Int, oldt: Int) {
                super.onScrollChanged(l, t, oldl, oldt)
                // The next page as the end comes into view.
                if (more && reading?.isActive != true && t + height >= content.height - dp(200)) load(reset = false)
            }
        }.apply { addView(content) }
    }

    override fun render(snapshot: JsonObject?) {
        barTitle.text = if (archived) "Archived" else "History"
        if (!started && snapshot != null) { started = true; load(reset = true) }
    }

    private fun load(reset: Boolean, wait: Long = 0) {
        val l = link ?: return
        reading?.cancel()
        barTitle.text = if (archived) "Archived" else "History"
        (archiveButton as android.widget.ImageView).imageTintList = android.content.res.ColorStateList.valueOf(if (archived) Tone.accent else Tone.dim)
        val offset = if (reset) 0 else rows.size
        reading = kore.scope.launch {
            if (wait > 0) delay(wait)
            val r = l.read(Control.historyList(windowId, query, archived, offset))
            runOnUiThread {
                if (r == null || r.str("t") == "result") {
                    state.removeAllViews()
                    state.addView(emptyState(dev.kore.phone.R.drawable.i_wifi_off, if (r == null) "$macName didn't answer" else "History isn't open", if (r == null) "Try again in a moment." else refusalWords(r.str("code"))))
                    return@runOnUiThread
                }
                if (reset) rows.clear()
                rows += r.objs("sessions")
                more = r.bool("more")
                draw()
            }
        }
    }

    /**
     * Newest first under "Today", "This week" and "Earlier" (spec §6), each a grouped list of rows
     * 52 high: the CLI's logo, the title, the time. A tap opens it; a long-press holds its menu.
     */
    private fun draw() {
        list.removeAllViews()
        state.removeAllViews()
        val now = System.currentTimeMillis()
        val buckets = LinkedHashMap<String, MutableList<JsonObject>>()
        for (s in rows) {
            val at = (s["updatedAt"] as? JsonPrimitive)?.longOrNull ?: 0L
            buckets.getOrPut(ControlModel.bucket(at, now)) { ArrayList() } += s
        }
        var first = true
        for ((bucket, sessions) in buckets) {
            list.addView(sectionLabel(bucket, first))
            first = false
            list.addView(grouped(sessions.map { s ->
                val at = (s["updatedAt"] as? JsonPrimitive)?.longOrNull ?: 0L
                historyRow(s, whenText(at, now, bucket)).apply { setOnLongClickListener { menu(it, s); true } }
            }, inset = 47))
        }
        when {
            rows.isNotEmpty() -> Unit
            query.isNotEmpty() -> state.addView(emptyState(dev.kore.phone.R.drawable.i_search, "No chats match", "Search looks at titles and the first message."))
            archived -> state.addView(emptyState(dev.kore.phone.R.drawable.i_archive, "No archived chats", "Chats you archive here or on $macName show up here."))
            else -> state.addView(emptyState(dev.kore.phone.R.drawable.i_archive, "No past chats here", "Chats you close in this folder show up here."))
        }
    }

    /** One past chat: its CLI's logo (17), its title (Body), its time (Caption, faint). */
    private fun historyRow(s: JsonObject, time: String): View = LinearLayout(this).apply {
        gravity = android.view.Gravity.CENTER_VERTICAL
        minimumHeight = dp(52)
        setPadding(dp(16), dp(10), dp(16), dp(10))
        addView(android.widget.ImageView(context).apply { setImageResource(providerLogo(s.str("provider"))) },
            LinearLayout.LayoutParams(dp(17), dp(17)).apply { marginEnd = dp(14) })
        val title = s.str("title")?.ifBlank { null } ?: "Untitled chat"
        addView(label(title).apply { type(Type.Body); setTextColor(Tone.text); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (s.bool("archived")) addView(android.widget.ImageView(context).apply {
            setImageResource(dev.kore.phone.R.drawable.i_archive); imageTintList = android.content.res.ColorStateList.valueOf(Tone.faint)
        }, LinearLayout.LayoutParams(dp(15), dp(15)).apply { marginStart = dp(8) })
        addView(label(time).apply { type(Type.Caption); setTextColor(Tone.faint); setPadding(dp(10), 0, 0, 0) })
        contentDescription = listOfNotNull(title, if (s.bool("archived")) "archived" else null, time).joinToString(", ")
        setOnClickListener { open(s) }
        pressFill(null, Tone.l2, 0)
    }

    private fun whenText(at: Long, now: Long, bucket: String): String {
        val d = java.util.Date(at)
        return when (bucket) {
            "Today" -> android.text.format.DateFormat.getTimeFormat(this).format(d)
            "This week" -> java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).format(d)
            else -> android.text.format.DateFormat.getMediumDateFormat(this).format(d)
        }
    }

    private fun open(s: JsonObject) {
        val id = s.str("id") ?: return
        act(Control.historyOpen(windowId, id)) { r ->
            r.str("chatId")?.let { startActivity(Intent(this, ChatActivity::class.java).putExtra("chat", it)) }
                ?: Quiet.say(this, "Opened on $macName")
        }
    }

    private fun menu(anchor: View, s: JsonObject) {
        val id = s.str("id") ?: return
        val isArchived = s.bool("archived")
        PopMenu(this).show(anchor, listOf(
            PopMenu.Item("Open here") { open(s) },
            PopMenu.Item("Rename…") { renameSheet(s.str("title").orEmpty()) { t -> act(Control.historyRename(windowId, id, t)) { load(reset = true) } } },
            PopMenu.Item(if (isArchived) "Unarchive" else "Archive") { act(Control.historyArchive(windowId, id, !isArchived)) { load(reset = true) } },
        ))
    }
}
