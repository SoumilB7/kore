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
 * for the archived ones. A tap opens the chat in a background tab on the Mac and here; a
 * long-press offers Open, Rename and Archive. Read a page at a time with `history.list`.
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
    private lateinit var archiveButton: android.widget.TextView
    private lateinit var state: android.widget.TextView

    override fun body(): View {
        archiveButton = barButton(barTitle, "▣", "Archived") { archived = !archived; load(reset = true) }
        val search = EditText(this).apply {
            hint = "Search chats…"
            setHintTextColor(K.faint)
            setTextColor(K.text)
            textSize = 14f
            background = rounded(android.graphics.Color.TRANSPARENT, 10, K.line)
            setPadding(dp(12), dp(9), dp(12), dp(9))
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_ACTION_SEARCH
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
        state = label("", 13f, K.faint).apply { setPadding(dp(4), dp(16), dp(4), dp(16)); visibility = View.GONE }
        content.addView(search, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) })
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
        archiveButton.setTextColor(if (archived) K.accent else K.dim)
        val offset = if (reset) 0 else rows.size
        reading = kore.scope.launch {
            if (wait > 0) delay(wait)
            val r = l.read(Control.historyList(windowId, query, archived, offset))
            runOnUiThread {
                if (r == null || r.str("t") == "result") {
                    state.text = if (r == null) "$macName didn't answer." else refusalWords(r.str("code"))
                    state.visibility = View.VISIBLE
                    return@runOnUiThread
                }
                if (reset) rows.clear()
                rows += r.objs("sessions")
                more = r.bool("more")
                draw()
            }
        }
    }

    private fun draw() {
        list.removeAllViews()
        val now = System.currentTimeMillis()
        var header: String? = null
        for (s in rows) {
            val at = (s["updatedAt"] as? JsonPrimitive)?.longOrNull ?: 0L
            val bucket = ControlModel.bucket(at, now)
            if (bucket != header) {
                header = bucket
                list.addView(label(bucket.uppercase(), 11f, K.faint).apply { letterSpacing = 0.06f; setPadding(dp(4), dp(12), 0, dp(6)) })
            }
            val title = (if (s.bool("archived")) "▣ " else "") + (s.str("title")?.ifBlank { null } ?: "Untitled chat")
            val v = row(title, whenText(at, now, bucket), null, providerMark(s.str("provider"))) { open(s) }
            v.setOnLongClickListener { menu(it, s); true }
            list.addView(v)
        }
        state.text = when {
            rows.isEmpty() && query.isNotEmpty() -> "No chats match."
            rows.isEmpty() -> if (archived) "No archived chats." else "No past chats in this folder."
            else -> ""
        }
        state.visibility = if (state.text.isEmpty()) View.GONE else View.VISIBLE
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
            PopMenu.Item("Open") { open(s) },
            PopMenu.Item("Rename…") { renameSheet(s.str("title").orEmpty()) { t -> act(Control.historyRename(windowId, id, t)) { load(reset = true) } } },
            PopMenu.Item(if (isArchived) "Unarchive" else "Archive") { act(Control.historyArchive(windowId, id, !isArchived)) { load(reset = true) } },
        ))
    }
}
