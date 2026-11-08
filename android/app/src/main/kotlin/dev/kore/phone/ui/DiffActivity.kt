package dev.kore.phone.ui

import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.kore.link.node.Control
import dev.kore.phone.kore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * One file's changes in a turn (T4), read once with `diff.get`: hunk headers, then the lines with
 * their old and new numbers, removed in red and added in green. Lines wrap; nothing scrolls sideways.
 */
class DiffActivity : NodeActivity() {
    private val chatId by lazy { intent.getStringExtra("chat") ?: "" }
    private val turnId by lazy { intent.getStringExtra("turn") ?: "" }
    private val path by lazy { intent.getStringExtra("path") ?: "" }
    private val lines = ArrayList<Line>()
    private lateinit var list: RecyclerView
    private lateinit var state: TextView
    private var asked = false

    private data class Line(val kind: Char, val text: String, val old: Int?, val new: Int?)

    override fun body(): View = column().apply {
        // Its path (spec §6): Mono 12, faint.
        addView(label(path).apply { type(Type.Mono); textSize = 12f; setTextColor(Tone.faint); setPadding(dp(16), 0, dp(16), dp(10)); maxLines = 2 })
        state = label("Reading the changes…").apply { type(Type.Callout); setTextColor(Tone.faint); gravity = Gravity.CENTER; setPadding(0, dp(40), 0, 0) }
        addView(state)
        list = RecyclerView(this@DiffActivity).apply {
            layoutManager = LinearLayoutManager(this@DiffActivity)
            adapter = Lines()
            setPadding(0, 0, 0, dp(24))
            clipToPadding = false
        }
        addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    }

    override fun render(snapshot: JsonObject?) {
        barTitle.text = path.substringAfterLast('/')
        if (asked || snapshot == null) return
        asked = true
        val l = link ?: return
        kore.scope.launch {
            val r = l.read(Control.diffGet(chatId, turnId, path))
            runOnUiThread { show(r) }
        }
    }

    private fun show(r: JsonObject?) {
        if (r == null || r.str("t") == "result") {
            state.text = if (r == null) "$macName didn't answer." else refusalWords(r.str("code"), r.str("message"))
            return
        }
        lines.clear()
        for (h in r.objs("hunks")) {
            var o = h["oldStart"].int() ?: 0
            var n = h["newStart"].int() ?: 0
            lines += Line('@', "@@ −$o +$n", null, null)
            for (raw in (h["lines"] as? kotlinx.serialization.json.JsonArray).orEmpty()) {
                val t = (raw as? JsonPrimitive)?.content ?: continue
                when (t.firstOrNull()) {
                    '+' -> lines += Line('+', t.drop(1), null, n++)
                    '-' -> lines += Line('-', t.drop(1), o++, null)
                    else -> lines += Line(' ', t.drop(1), o++, n++)
                }
            }
        }
        if (r.bool("more")) lines += Line('…', "The rest is on $macName.", null, null)
        state.visibility = if (lines.isEmpty()) View.VISIBLE else View.GONE
        if (lines.isEmpty()) state.text = "No changes to show."
        list.adapter?.notifyDataSetChanged()
    }

    private inner class Lines : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private val addBg = Tone.okLine
        private val delBg = Tone.errLine

        override fun getItemCount() = lines.size
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(LinearLayout(this@DiffActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            // Spec §6: rows Mono 12 at 1.7; a 44 gutter, right-aligned, faint.
            addView(label("").apply { type(Type.Mono); textSize = 12f; lineHeight = (12f * 1.7f * resources.displayMetrics.scaledDensity).toInt(); setTextColor(Tone.faint); gravity = Gravity.END; setPadding(0, 0, dp(10), 0) },
                LinearLayout.LayoutParams(dp(44), ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(label("").apply { type(Type.Mono); textSize = 12f; lineHeight = (12f * 1.7f * resources.displayMetrics.scaledDensity).toInt(); setPadding(dp(4), 0, dp(12), 0) }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val row = holder.itemView as LinearLayout
            val num = row.getChildAt(0) as TextView
            val text = row.getChildAt(1) as TextView
            val line = lines[position]
            num.text = (line.new ?: line.old)?.toString() ?: ""
            row.setBackgroundColor(when (line.kind) { '+' -> addBg; '-' -> delBg; else -> android.graphics.Color.TRANSPARENT })
            when (line.kind) {
                '@', '…' -> { text.text = line.text; text.setTextColor(K.faint); row.setPadding(0, if (position == 0) 0 else dp(12), 0, dp(4)) }
                else -> {
                    text.text = (if (line.kind == ' ') "  " else "${line.kind} ") + line.text
                    text.setTextColor(when (line.kind) { '+' -> K.ok; '-' -> K.err; else -> K.dim })
                    row.setPadding(0, 0, 0, 0)
                }
            }
        }
    }
}
