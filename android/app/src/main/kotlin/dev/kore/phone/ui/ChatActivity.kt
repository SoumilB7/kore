package dev.kore.phone.ui

import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.kore.phone.kore
import dev.kore.phone.link.Transcript
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** One chat: the last entries of its transcript, live, newest at the bottom, with a composer and its cards. */
class ChatActivity : NodeActivity() {
    private val chatId by lazy { intent.getStringExtra("chat") ?: "" }
    private val transcript by lazy { Transcript(chatId) }
    private lateinit var list: RecyclerView
    private val adapter = Entries()
    private var follow: Job? = null
    private var results: Job? = null
    private lateinit var actions: ChatActions
    // Until the first page arrives: Kore may be loading this chat on the Mac.
    private lateinit var opening: LinearLayout
    private lateinit var openingSpinner: ProgressBar
    private lateinit var openingText: TextView
    private lateinit var retry: TextView
    private var openTimeout: Job? = null
    private var loaded = false
    private var provider: String? = null

    private var menuButton: TextView? = null
    /** Asked for the earlier conversation; the row says so until the transcript grows. */
    private var askedEarlier = false

    override fun body(): View = column().apply {
        // The chat's one new mark: ⋮ opens its sheet (rename, compact, show on the Mac, close).
        menuButton = barButton(barTitle, "⋮", "Chat menu") { actions.openMenu() }.apply { visibility = View.GONE }
        // ＋: a new chat beside this one, on the same device (phase 18 §3).
        barButton(barTitle, "＋", "New chat here") { newHere() }
        openingSpinner = ProgressBar(this@ChatActivity, null, android.R.attr.progressBarStyleSmall).apply {
            indeterminateTintList = android.content.res.ColorStateList.valueOf(K.accent)
        }
        openingText = label("Opening on $macName…", 13f, K.faint)
        retry = label("Retry", 13f, K.accent, bold = true).apply {
            setPadding(dp(12), dp(6), dp(12), dp(6))
            visibility = View.GONE
            setOnClickListener { open() }
        }
        opening = LinearLayout(this@ChatActivity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(openingSpinner)
            addView(openingText.apply { setPadding(0, dp(10), 0, dp(4)) })
            addView(retry)
        }
        list = RecyclerView(this@ChatActivity).apply {
            layoutManager = LinearLayoutManager(this@ChatActivity).apply { stackFromEnd = true }
            adapter = this@ChatActivity.adapter
            // On a board, a sideways fling moves to the next or previous chat on it.
            val board = intent.getStringArrayExtra("board")
            if (board != null && board.size > 1) {
                val swipe = android.view.GestureDetector(this@ChatActivity, object : android.view.GestureDetector.SimpleOnGestureListener() {
                    override fun onFling(e1: android.view.MotionEvent?, e2: android.view.MotionEvent, vx: Float, vy: Float): Boolean {
                        val dx = e2.x - (e1?.x ?: e2.x)
                        if (kotlin.math.abs(vx) < 900 || kotlin.math.abs(dx) < dp(80) || kotlin.math.abs(vx) < 2 * kotlin.math.abs(vy)) return false
                        val i = board.indexOf(chatId) + if (dx < 0) 1 else -1
                        if (i !in board.indices) return false
                        startActivity(android.content.Intent(this@ChatActivity, ChatActivity::class.java).putExtra("chat", board[i]).putExtra("board", board))
                        @Suppress("DEPRECATION")
                        overridePendingTransition(if (dx < 0) android.R.anim.slide_in_left else android.R.anim.slide_in_left, android.R.anim.fade_out)
                        finish()
                        return true
                    }
                })
                setOnTouchListener { _, ev -> swipe.onTouchEvent(ev); false }
            }
            setPadding(dp(16), 0, dp(16), dp(8))
            clipToPadding = false
        }
        // The transcript fills the space; while the chat opens, its state sits in the middle of it.
        addView(android.widget.FrameLayout(this@ChatActivity).apply {
            addView(list, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(opening, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        addView(View(this@ChatActivity).apply { setBackgroundColor(K.line) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1))
        actions = ChatActions(this@ChatActivity, chatId) { link }
        addView(actions.view)
    }

    override fun onStart() {
        super.onStart()
        val link = link ?: return
        // Subscribed before the open goes out: the transcript flow keeps no replay, so a late
        // collector would miss the first page.
        follow = kore.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            link.transcripts.collect { m ->
                if (transcript.apply(m)) {
                    val entries = transcript.entries
                    runOnUiThread {
                        if (!loaded) { loaded = true; openTimeout?.cancel(); opening.visibility = View.GONE }
                        val atBottom = !list.canScrollVertically(1)
                        val grewAtTop = entries.isNotEmpty() && adapter.firstId != null && entries.first().str("id") != adapter.firstId
                        if (grewAtTop) askedEarlier = false
                        adapter.earlier = transcript.hasEarlier || entries.firstOrNull()?.str("kind") == "divider"
                        adapter.submit(entries)
                        if (atBottom) list.scrollToPosition(maxOf(0, entries.size - 1))
                    }
                }
            }
        }
        results = kore.scope.launch(start = CoroutineStart.UNDISPATCHED) {
            link.results.collect { r ->
                runOnUiThread {
                    if (!loaded && r.str("code") == "gone.chat") couldNotOpen()
                    actions.result(r)
                }
            }
        }
        open()
    }

    /** Asks the Mac for this chat; it may load it in the background first. */
    private fun open() {
        val link = link ?: return
        if (!loaded) {
            opening.visibility = View.VISIBLE
            openingSpinner.visibility = View.VISIBLE
            openingText.text = "Opening on $macName…"
            retry.visibility = View.GONE
            openTimeout?.cancel()
            openTimeout = kore.scope.launch {
                kotlinx.coroutines.delay(10_000)
                runOnUiThread { if (!loaded) couldNotOpen() }
            }
        }
        link.openTranscript(chatId)
    }

    private fun couldNotOpen() {
        openingSpinner.visibility = View.GONE
        openingText.text = "Couldn't open this chat on $macName"
        retry.visibility = View.VISIBLE
    }

    @Deprecated("The platform's activity results")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        actions.onResult(requestCode, resultCode, data)
    }

    override fun onStop() {
        openTimeout?.cancel()
        follow?.cancel()
        results?.cancel()
        link?.closeTranscript(chatId)
        super.onStop()
    }

    override fun render(snapshot: JsonObject?) {
        val chat = snapshot?.chatsById()?.get(chatId)
        actions.render(chat, snapshot)
        adapter.running = chat?.bool("running") == true
        adapter.canFork = chat?.obj("can")?.let { if (it.containsKey("fork")) it.bool("fork") else null }
        adapter.rescue = ControlModel.rescue(chat?.obj("rescue")) { at -> whenText(at) }
        menuButton?.visibility = if (chat != null && (chat.containsKey("controls") || link.hasControl(snapshot))) View.VISIBLE else View.GONE
        provider = chat?.str("provider") ?: provider
        val (dot, word) = stateLook(chat?.str("state"))
        barTitle.text = android.text.SpannableStringBuilder(providerMark(chat?.str("provider"))).append("  ").append(chat?.str("title") ?: "Chat")
        barDot.background = rounded(dot, 4)
        barDot.contentDescription = word
        barDot.visibility = if (chat != null) View.VISIBLE else View.GONE
    }

    /** "4:00 PM" today, else "Thu 9:00 AM", in the phone's own clock style. */
    private fun whenText(at: Long): String {
        val time = android.text.format.DateFormat.getTimeFormat(this).format(java.util.Date(at))
        val same = android.text.format.DateUtils.isToday(at)
        return if (same) "at $time" else java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).format(java.util.Date(at)) + " " + time
    }

    /** The earlier conversation: Kore's earlier entries first, else the CLI's history before a compaction. */
    private fun loadEarlier() {
        val l = link ?: return
        askedEarlier = true
        adapter.notifyItemChanged(0)
        l.post(if (transcript.hasEarlier) dev.kore.link.node.Control.txMore(chatId) else dev.kore.link.node.Control.txEarlier(chatId))
        list.postDelayed({ if (askedEarlier) { askedEarlier = false; adapter.earlier = transcript.hasEarlier; adapter.submit(transcript.entries) } }, 8_000)
    }

    /** Long-press a message: Copy, and Fork from here (a prompt) or Fork after this (an answer). */
    private fun messageMenu(anchor: View, e: JsonObject) {
        val id = e.str("id") ?: return
        val after = e.str("kind") != "user"
        val text = e.str("text")?.takeIf { it.isNotEmpty() } ?: Doc.render(e.objs("doc")).toString()
        val items = mutableListOf(PopMenu.Item("Copy") {
            val clip = getSystemService(android.content.ClipboardManager::class.java)
            clip.setPrimaryClip(android.content.ClipData.newPlainText("Message", text))
        })
        adapter.canFork?.let { can -> items += PopMenu.Item(if (after) "Fork after this" else "Fork from here", enabled = can) { actions.fork(id, after) } }
        PopMenu(this).show(anchor, items)
    }

    /** A tool's file changes: one file opens its diff; several list first. */
    private fun openChanges(e: JsonObject) {
        val changes = e.objs("changes")
        val turn = e.str("turn") ?: return
        fun open(path: String) = startActivity(android.content.Intent(this, DiffActivity::class.java)
            .putExtra("chat", chatId).putExtra("turn", turn).putExtra("path", path))
        if (changes.size == 1) return open(changes[0].str("path") ?: return)
        lateinit var s: Sheet
        s = Sheet(this).show {
            title("Changes")
            for (c in changes) {
                val path = c.str("path") ?: continue
                val counts = android.text.SpannableStringBuilder()
                    .append("+${c["added"].int() ?: 0}", android.text.style.ForegroundColorSpan(K.ok), 0).append(" ")
                    .append("−${c["removed"].int() ?: 0}", android.text.style.ForegroundColorSpan(K.err), 0)
                item(path.substringAfterLast('/'), detail = counts, chevron = true, tag = path) { s.dismiss(); open(path) }
            }
        }
    }

    /** What the list shows: an entry, or a finished stretch of work folded into one line. */
    private sealed class Item {
        data class One(val e: JsonObject) : Item()
        /** The conversation before this page: one quiet row at the top. */
        object Earlier : Item()
        /** A rescue row under the turn: Retry, Continue, "Continues at …" ×. */
        data class Rescue(val line: ControlModel.RescueLine) : Item()
        data class Work(val key: String, val steps: List<JsonObject>) : Item()
        /** The turn still runs: a spinner under the last row. */
        object Running : Item()
    }

    private inner class Entries : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private var entries: List<JsonObject> = emptyList()
        private var items: List<Item> = emptyList()
        private val open = HashSet<String>()
        private val openTools = HashSet<String>()
        var running = false
            set(value) { if (field != value) { field = value; rebuild() } }
        var earlier = false
        /** Null when the Mac doesn't offer forks; false while it can't fork now. */
        var canFork: Boolean? = null
        var rescue: List<ControlModel.RescueLine> = emptyList()
            set(value) { if (field != value) { field = value; rebuild() } }
        val firstId: String? get() = entries.firstOrNull()?.str("id")

        fun submit(list: List<JsonObject>) {
            entries = list
            rebuild()
        }

        /** Runs of tool, thinking and agent rows fold into "Worked · N steps", except the live tail. */
        private fun rebuild() {
            val out = ArrayList<Item>()
            if (earlier && entries.isNotEmpty()) out.add(Item.Earlier)
            var run = ArrayList<JsonObject>()
            fun flush(live: Boolean) {
                if (run.isEmpty()) return
                val key = run.first().str("id") ?: ""
                if (live || run.size < 2 || key in open) {
                    if (run.size >= 2 && key in open) out.add(Item.Work(key, run.toList()))
                    run.forEach { out.add(Item.One(it)) }
                } else out.add(Item.Work(key, run.toList()))
                run = ArrayList()
            }
            for (e in entries) {
                if (e.str("kind") in setOf("tool", "thinking", "agent")) run.add(e) else flush(false).also { out.add(Item.One(e)) }
            }
            flush(true)
            if (running) out.add(Item.Running)
            rescue.forEach { out.add(Item.Rescue(it)) }
            items = out
            notifyDataSetChanged()
        }

        override fun getItemCount() = items.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(
            android.widget.FrameLayout(this@ChatActivity).apply {
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                addView(label("", 15f), android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                // The rule a compaction divider sits on; hidden for every other row.
                addView(View(this@ChatActivity).apply { setBackgroundColor(K.line); visibility = View.GONE },
                    0, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1, Gravity.CENTER_VERTICAL))
                // An answer's render tree as real views (code and tables scroll sideways).
                addView(LinearLayout(this@ChatActivity).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE },
                    android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                        topMargin = dp(6); bottomMargin = dp(6)
                    })
                // The running turn: a small spinner and one word.
                addView(LinearLayout(this@ChatActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    visibility = View.GONE
                    setPadding(dp(4), dp(10), dp(4), dp(10))
                    addView(android.widget.ProgressBar(this@ChatActivity, null, android.R.attr.progressBarStyleSmall).apply {
                        indeterminateTintList = android.content.res.ColorStateList.valueOf(K.accent)
                    }, LinearLayout.LayoutParams(dp(16), dp(16)).apply { rightMargin = dp(10) })
                    addView(label("Working…", 13f, K.dim))
                }, android.widget.FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            },
        ) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val frame = holder.itemView as android.widget.FrameLayout
            val rule = frame.getChildAt(0)
            val v = frame.getChildAt(1) as TextView
            val docBox = frame.getChildAt(2) as LinearLayout
            val spinner = frame.getChildAt(3)
            rule.visibility = View.GONE
            docBox.visibility = View.GONE
            spinner.visibility = View.GONE
            v.visibility = View.VISIBLE
            v.maxWidth = Int.MAX_VALUE
            v.background = null
            v.setOnClickListener(null)
            v.setOnLongClickListener(null)
            v.movementMethod = null
            v.isLongClickable = false
            v.gravity = Gravity.START
            v.contentDescription = null
            frame.setOnLongClickListener(null)
            v.setPadding(dp(4), dp(6), dp(4), dp(6))
            v.setTextColor(K.text)
            v.textSize = 15f
            v.typeface = android.graphics.Typeface.DEFAULT
            v.setLineSpacing(0f, 1f)
            (v.layoutParams as android.widget.FrameLayout.LayoutParams).apply {
                width = ViewGroup.LayoutParams.MATCH_PARENT; gravity = Gravity.START
                topMargin = dp(4); bottomMargin = dp(4); leftMargin = 0; rightMargin = 0
            }
            when (val item = items[position]) {
                is Item.Work -> {
                    val expanded = item.key in open
                    v.text = "Worked · ${item.steps.size} steps  ${if (expanded) "⌄" else "›"}"
                    v.setTextColor(K.faint)
                    v.textSize = 13f
                    v.setOnClickListener { if (!open.add(item.key)) open.remove(item.key); rebuild() }
                }
                is Item.One -> {
                    val doc = item.e.objs("doc")
                    if (item.e.str("kind") in setOf("answer", "plan") && doc.isNotEmpty()) {
                        v.visibility = View.GONE
                        docBox.visibility = View.VISIBLE
                        DocViews.build(this@ChatActivity, doc, docBox)
                    } else bind(v, item.e)
                    if (item.e.str("kind") == "divider") rule.visibility = View.VISIBLE
                    if (item.e.str("kind") in setOf("user", "answer", "plan")) {
                        val hold = View.OnLongClickListener { messageMenu(if (v.visibility == View.VISIBLE) v else docBox, item.e); true }
                        frame.setOnLongClickListener(hold)
                        v.setOnLongClickListener(hold)
                        holdAll(docBox, hold)
                    }
                }
                Item.Earlier -> {
                    v.text = if (askedEarlier) "Loading the earlier conversation…" else "Earlier conversation  ⌃"
                    v.setTextColor(K.faint)
                    v.textSize = 13f
                    v.gravity = Gravity.CENTER
                    v.contentDescription = "Earlier conversation"
                    if (!askedEarlier) v.setOnClickListener { loadEarlier() }
                    return
                }
                is Item.Rescue -> { bindRescue(v, item.line); return }
                Item.Running -> { v.visibility = View.GONE; spinner.visibility = View.VISIBLE }
            }
        }

        /** Every view of a rendered answer takes the long-press (its text views would swallow it). */
        private fun holdAll(v: View, hold: View.OnLongClickListener) {
            v.setOnLongClickListener(hold)
            if (v is ViewGroup) for (i in 0 until v.childCount) holdAll(v.getChildAt(i), hold)
        }

        /** A rescue row: the Mac's words, then its actions as accent words. */
        private fun bindRescue(v: TextView, line: ControlModel.RescueLine) {
            v.textSize = 13f
            v.setTextColor(K.dim)
            v.gravity = Gravity.START
            v.maxLines = Int.MAX_VALUE
            v.ellipsize = null
            v.text = android.text.SpannableStringBuilder().apply {
                if (line.warn) append("⚠  ", android.text.style.ForegroundColorSpan(K.warn), 0)
                append(line.text)
                for (a in line.actions) {
                    val word = when (a) { "retry", "retryTurn" -> "Retry"; "stop" -> "Stop"; "continue" -> "Continue"; else -> "×" }
                    append("    ")
                    val start = length
                    append(word)
                    setSpan(object : android.text.style.ClickableSpan() {
                        override fun onClick(w: View) = actions.rescue(a, line.key.substringAfter(':', "").ifEmpty { null })
                        override fun updateDrawState(ds: android.text.TextPaint) {
                            ds.color = if (a == "stop" || a == "cancelContinue") K.dim else K.accent
                            ds.isFakeBoldText = a != "cancelContinue"
                        }
                    }, start, length, 0)
                }
            }
            v.movementMethod = android.text.method.LinkMovementMethod.getInstance()
            (v.layoutParams as android.widget.FrameLayout.LayoutParams).leftMargin = dp(10)
        }

        /** The message, then each attachment: its thumbnail once the Mac sent it, else its name. */
        private fun userText(e: JsonObject): CharSequence {
            val text = e.str("text").orEmpty()
            val files = e.objs("attachments")
            if (files.isEmpty()) return text
            return android.text.SpannableStringBuilder(text).apply {
                for (f in files) {
                    val ref = f.str("ref") ?: continue
                    if (isNotEmpty()) append("\n")
                    val thumb = Thumbs.get(ref)
                    if (thumb != null) {
                        val w = dp(160)
                        val h = (w.toFloat() * thumb.height / maxOf(1, thumb.width)).toInt()
                        val d = android.graphics.drawable.BitmapDrawable(resources, thumb).apply { setBounds(0, 0, w, h) }
                        append("\uFFFC", android.text.style.ImageSpan(d), 0)
                    } else {
                        append("📎 " + (f.str("name") ?: "attachment"))
                        val l = link
                        if (l != null && f.str("kind") == "image") Thumbs.fetch(kore.scope, l, chatId, ref) { runOnUiThread { notifyDataSetChanged() } }
                    }
                }
            }
        }

        private fun bind(v: TextView, e: JsonObject) {
            when (e.str("kind")) {
                "user" -> {
                    v.text = userText(e)
                    v.background = rounded(K.surface, 14, K.line)
                    v.setPadding(dp(12), dp(8), dp(12), dp(8))
                    v.setLineSpacing(0f, 1.3f)
                    v.maxWidth = (resources.displayMetrics.widthPixels * 0.8f).toInt()
                    (v.layoutParams as android.widget.FrameLayout.LayoutParams).apply {
                        width = ViewGroup.LayoutParams.WRAP_CONTENT; gravity = Gravity.END; topMargin = dp(14); leftMargin = 0
                    }
                }
                "answer", "plan" -> { v.text = e.str("text").orEmpty(); v.setLineSpacing(0f, 1.4f) }
                "tool" -> {
                    val tool = e.obj("tool")
                    val id = e.str("id") ?: ""
                    val name = tool?.str("name").orEmpty()
                    val what = tool?.str("summary") ?: tool?.str("path") ?: ""
                    val expanded = id in openTools
                    v.text = android.text.SpannableStringBuilder().apply {
                        append(name, android.text.style.StyleSpan(android.graphics.Typeface.BOLD), 0)
                        if (what.isNotEmpty()) append("  ").append(what, android.text.style.TypefaceSpan("monospace"), 0)
                        e.objs("changes").takeIf { it.isNotEmpty() }?.let { ch ->
                            val add = ch.sumOf { it["added"].int() ?: 0 }
                            val del = ch.sumOf { it["removed"].int() ?: 0 }
                            append("  ").append("+$add", android.text.style.ForegroundColorSpan(K.ok), 0)
                            append(" ").append("−$del", android.text.style.ForegroundColorSpan(K.err), 0)
                        }
                        if (!e.bool("done")) append("  …", android.text.style.ForegroundColorSpan(K.faint), 0)
                        if (expanded) {
                            tool?.str("input")?.takeIf { it.isNotEmpty() && it != what }?.let { input ->
                                append("\n\n").append(input, android.text.style.TypefaceSpan("monospace"), 0)
                            }
                            tool?.str("result")?.takeIf { it.isNotEmpty() }?.let { result ->
                                append("\n\n")
                                val start = length
                                append(result)
                                setSpan(android.text.style.TypefaceSpan("monospace"), start, length, 0)
                                setSpan(android.text.style.ForegroundColorSpan(K.text), start, length, 0)
                            }
                        }
                    }
                    v.maxLines = if (expanded) 40 else 1
                    v.ellipsize = android.text.TextUtils.TruncateAt.END
                    v.setTextColor(if (e.bool("isError")) K.err else K.dim)
                    v.textSize = 13f
                    if (expanded) {
                        v.background = rounded(K.surface, 10, K.line)
                        v.setPadding(dp(10), dp(8), dp(10), dp(8))
                    }
                    if (e.objs("changes").isNotEmpty() && e.str("turn") != null) v.setOnClickListener { openChanges(e) }
                    else v.setOnClickListener { if (!openTools.add(id)) openTools.remove(id); notifyDataSetChanged() }
                    (v.layoutParams as android.widget.FrameLayout.LayoutParams).leftMargin = dp(10)
                }
                "summary" -> {
                    val who = if (provider == "codex") "Codex" else "Claude"
                    v.text = android.text.SpannableStringBuilder().apply {
                        append("Summary from $who", android.text.style.ForegroundColorSpan(K.faint), 0)
                        setSpan(android.text.style.RelativeSizeSpan(0.85f), 0, length, 0)
                        append("\n")
                        val start = length
                        append(e.str("text").orEmpty())
                        setSpan(android.text.style.QuoteSpan(K.line, dp(2), dp(10)), start, length, 0)
                        setSpan(android.text.style.ForegroundColorSpan(K.dim), start, length, 0)
                    }
                    v.textSize = 14f
                }
                "thinking" -> {
                    v.text = e.str("text")?.takeIf { it.isNotBlank() } ?: "Thinking…"
                    v.setTextColor(K.faint); v.textSize = 13f
                    v.setTypeface(v.typeface, android.graphics.Typeface.ITALIC)
                    (v.layoutParams as android.widget.FrameLayout.LayoutParams).leftMargin = dp(10)
                }
                "agent" -> {
                    v.text = "Agent · ${e.obj("agent")?.str("name") ?: ""} · ${e.obj("agent")?.str("status") ?: ""}"
                    v.setTextColor(K.dim); v.textSize = 13f
                    (v.layoutParams as android.widget.FrameLayout.LayoutParams).leftMargin = dp(10)
                }
                "notice" -> {
                    v.text = (if (e.bool("isError")) "⚠  " else "") + e.str("text").orEmpty()
                    v.setTextColor(if (e.bool("isError")) (K.err and 0x00FFFFFF) or (0xCC shl 24) else K.dim)
                    v.textSize = 13f
                }
                "divider" -> {
                    // A thin rule with its words in the middle: "Compacted automatically · 8:19 PM".
                    v.text = e.str("text").orEmpty().ifEmpty { "Compacted" }
                    v.setTextColor(K.faint)
                    v.textSize = 12f
                    v.setBackgroundColor(K.bg)
                    v.setPadding(dp(10), dp(4), dp(10), dp(4))
                    (v.layoutParams as android.widget.FrameLayout.LayoutParams).apply {
                        width = ViewGroup.LayoutParams.WRAP_CONTENT; gravity = Gravity.CENTER; topMargin = dp(16); bottomMargin = dp(10)
                    }
                    v.gravity = android.view.Gravity.CENTER
                }
                else -> { v.text = e.str("text").orEmpty(); v.setTextColor(K.dim); v.textSize = 13f }
            }
            if (e.str("kind") != "divider") v.gravity = android.view.Gravity.START
            if (e.str("kind") != "tool") { v.maxLines = Int.MAX_VALUE; v.ellipsize = null }
        }
    }

    /** A new chat in this chat's window (a box: its folder), with the CLI picked here. */
    private fun newHere() {
        val snap = link?.snapshot?.value ?: return Quiet.say(this, "Not connected")
        val chat = snap.chatsById()[chatId]
        val window = snap.objs("windows").firstOrNull { w -> w.objs("tabs").any { it.str("chatId") == chatId } }
            ?: snap.objs("windows").firstOrNull { it.str("id") == chat?.str("windowId") }
            ?: return Quiet.say(this, "This chat's window isn't open any more.")
        val box = link?.device?.value?.kind == dev.kore.link.trust.NodeKind.BOX
        val providers = link?.welcome?.value?.objs("providers").orEmpty()
        lateinit var s: Sheet
        s = Sheet(this).show {
            title("New chat in ${window.str("name") ?: "this window"}")
            for (p in providers) {
                val pid = p.str("id") ?: continue
                item("${p.str("name") ?: pid} chat", glyph = providerMark(pid), checked = pid == chat?.str("provider"), tag = "New ${p.str("name")} chat") {
                    s.dismiss()
                    val path = window.str("path")
                    val cmd = if (box && path != null) dev.kore.link.node.Control.newChatInFolder(path, pid) else dev.kore.link.node.Control.newChat(window.str("id") ?: "", pid)
                    act(cmd) { r ->
                        r.str("chatId")?.let { startActivity(android.content.Intent(this@ChatActivity, ChatActivity::class.java).putExtra("chat", it)) }
                            ?: Quiet.say(this@ChatActivity, "Started on $macName")
                    }
                }
            }
        }
    }
}
