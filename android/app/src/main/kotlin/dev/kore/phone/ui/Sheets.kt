package dev.kore.phone.ui

import android.app.Activity
import android.app.Dialog
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import dev.kore.link.node.NodeClient
import dev.kore.phone.nodeId
import dev.kore.phone.kore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/** The sheet and menu colours of the full-control design (Phone/docs/design/full-control.html). */
object KS {
    val pop = Color.parseColor("#171D21")
    val menu = Color.parseColor("#263036")
    val divider = Color.parseColor("#212326")
    val segOn = Color.parseColor("#22303F")
    val chipOn = Color.parseColor("#17202B")
    val field = Color.parseColor("#111113")
    val held = Color.parseColor("#1D252A")
    val heldLine = Color.parseColor("#3A4148")
    val grab = Color.parseColor("#3A3E43")
    val plan = Color.parseColor("#5FB3A8")
    val danger = Color.parseColor("#F0736B")
}

/** A mode's colour by its level: plan, manual, accept edits, auto, full access. */
fun modeColor(level: Int?): Int = when (level) {
    0 -> KS.plan
    1, null -> K.dim
    2 -> K.accent
    3 -> K.warn
    else -> KS.danger
}

/** A tab group's colour, as Kore's eight (TabGroupTheme); a hex value is taken as it is. */
fun groupColor(name: String?): Int = when (name) {
    "grey" -> Color.parseColor("#9AA4AD")
    "blue" -> Color.parseColor("#6FA8DC")
    "teal" -> Color.parseColor("#5FB5AE")
    "green" -> Color.parseColor("#7DBE8B")
    "sand" -> Color.parseColor("#CDB173")
    "orange" -> Color.parseColor("#DE9467")
    "rose" -> Color.parseColor("#DC7F92")
    "violet" -> Color.parseColor("#A390D8")
    else -> runCatching { Color.parseColor(name) }.getOrDefault(K.dim)
}
val GROUP_COLORS = listOf("blue", "teal", "green", "sand", "orange", "rose", "violet", "grey")

/** A board section's swatch: Kore's blue shades, or a neutral grey. */
fun swatchColor(name: String?): Int? = when (name) {
    "b200" -> Color.parseColor("#A3C3DC")
    "b300" -> Color.parseColor("#6AB1E7")
    "b400" -> Color.parseColor("#3C97DD")
    "b600" -> Color.parseColor("#1B6298")
    "neutral" -> K.dim
    else -> null
}
val SWATCHES = listOf("b200", "b300", "b400", "b600", "neutral")

/** The sheet's ground: rounded top, a hairline, and the two accent corner marks. */
private class SheetGround(private val density: Float, var corner: Int) : Drawable() {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = KS.pop }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = K.line; style = Paint.Style.STROKE; strokeWidth = density }
    private val mark = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.5f * density; strokeCap = Paint.Cap.ROUND }

    override fun draw(c: Canvas) {
        val b = bounds
        val r = 22 * density
        val path = Path().apply {
            addRoundRect(RectF(b), floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f), Path.Direction.CW)
        }
        c.drawPath(path, fill)
        c.drawLine(b.left + r, b.top + line.strokeWidth / 2, b.right - r, b.top + line.strokeWidth / 2, line)
        mark.color = corner
        val h = mark.strokeWidth / 2
        c.drawArc(RectF(b.left + h, b.top + h, b.left + 2 * r, b.top + 2 * r), 180f, 90f, false, mark)
        c.drawArc(RectF(b.right - 2 * r, b.top + h, b.right - h, b.top + 2 * r), 270f, 90f, false, mark)
    }
    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(cf: ColorFilter?) = Unit
    @Deprecated("Drawable API") override fun getOpacity() = PixelFormat.TRANSLUCENT
}

/**
 * Kore's one sheet: from the bottom, accent corners (mode-coloured where the mode governs), a
 * grab bar, rows with one fact on the right, and at most one quiet line for what just happened.
 * Its content is a builder, run again by [refresh] when the Mac's state changes under it.
 */
class Sheet(private val a: Activity, corner: Int = K.accent) {
    private val dialog = Dialog(a).apply { requestWindowFeature(Window.FEATURE_NO_TITLE) }
    private val ground = SheetGround(a.resources.displayMetrics.density, corner)
    val body: LinearLayout = a.column()
    private val note = a.label("", 12f, K.faint).apply {
        visibility = View.GONE
        setPadding(a.dp(4), a.dp(8), a.dp(4), 0)
    }
    private var builder: (Sheet.() -> Unit)? = null
    private var lastWasItem = false

    init {
        val scroll = object : ScrollView(a) {
            override fun onMeasure(w: Int, h: Int) =
                super.onMeasure(w, MeasureSpec.makeMeasureSpec((a.resources.displayMetrics.heightPixels * 0.8f).toInt(), MeasureSpec.AT_MOST))
        }.apply { addView(body); isVerticalScrollBarEnabled = false }
        val root = a.column().apply {
            background = ground
            setPadding(a.dp(16), a.dp(10), a.dp(16), a.dp(22))
            addView(View(a).apply { background = a.rounded(KS.grab, 2) }, LinearLayout.LayoutParams(a.dp(36), a.dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = a.dp(10)
            })
            addView(scroll)
            addView(note)
        }
        dialog.setContentView(root)
        dialog.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setGravity(Gravity.BOTTOM)
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.55f)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
        }
    }

    var corner: Int
        get() = ground.corner
        set(v) { ground.corner = v; ground.invalidateSelf() }

    val isShowing get() = dialog.isShowing

    fun show(build: Sheet.() -> Unit): Sheet {
        builder = build
        refresh()
        if (!a.isFinishing) dialog.show()
        return this
    }

    /** Draws the content again (the Mac's state changed under it). */
    fun refresh() {
        body.removeAllViews()
        lastWasItem = false
        builder?.invoke(this)
    }

    fun dismiss() = runCatching { dialog.dismiss() }.let { }
    fun onDismiss(go: () -> Unit) = dialog.setOnDismissListener { go() }

    /** The one quiet line: a refusal or what just happened. Empty hides it. */
    fun say(text: String) {
        note.text = text
        note.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun add(v: View, item: Boolean = false, lp: LinearLayout.LayoutParams? = null) {
        if (item && lastWasItem) body.addView(View(a).apply { setBackgroundColor(KS.divider) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1))
        lastWasItem = item
        if (lp != null) body.addView(v, lp) else body.addView(v)
    }

    fun title(text: String, sub: String? = null) {
        add(a.label(text, 16f, K.text, bold = true).apply { setPadding(a.dp(4), a.dp(2), a.dp(4), 0) })
        if (sub != null) add(a.label(sub, 13f, K.dim).apply { setPadding(a.dp(4), a.dp(3), a.dp(4), a.dp(6)) })
    }

    fun section(text: String) =
        add(a.label(text.uppercase(), 11f, K.faint).apply { letterSpacing = 0.06f; setPadding(a.dp(4), a.dp(14), a.dp(4), a.dp(4)) })

    /**
     * A row: an optional glyph or coloured dot, the title, and on the right one fact, a ✓ or ›.
     * Disabled rows stay visible, faint, and don't take a tap.
     */
    fun item(
        title: CharSequence, glyph: CharSequence? = null, detail: CharSequence? = null, chevron: Boolean = false,
        danger: Boolean = false, checked: Boolean = false, enabled: Boolean = true, dot: Int? = null,
        tag: String? = null, onTap: (() -> Unit)? = null,
    ): View {
        val row = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = a.dp(50)
            setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(10))
            if (dot != null) addView(View(a).apply { background = a.rounded(dot, 4) }, LinearLayout.LayoutParams(a.dp(8), a.dp(8)).apply { marginEnd = a.dp(14) })
            if (glyph != null) addView(a.label(glyph, 14f, if (danger) K.err else K.dim).apply { gravity = Gravity.CENTER },
                LinearLayout.LayoutParams(a.dp(20), ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = a.dp(12) })
            addView(a.label(title, 15f, if (danger) K.err else K.text).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            val right = when {
                checked -> "✓"
                detail != null && chevron -> android.text.SpannableStringBuilder(detail).append(" ›")
                chevron -> "›"
                else -> detail
            }
            if (right != null) addView(a.label(right, if (checked) 16f else 13f, if (checked) K.accent else K.faint).apply {
                maxLines = 1; setPadding(a.dp(10), 0, 0, 0)
            })
            contentDescription = tag ?: title.toString()
            isEnabled = enabled
            alpha = if (enabled) 1f else 0.4f
            if (enabled && onTap != null) {
                setBackgroundResource(android.R.drawable.list_selector_background)
                setOnClickListener { onTap() }
            }
        }
        add(row, item = true)
        return row
    }

    /** Equal segments in one outlined bar (effort, the auto-compact point). */
    fun segmented(options: List<Pair<String, String>>, selected: String?, enabled: Boolean = true, onPick: (String) -> Unit) {
        val bar = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            background = a.rounded(Color.TRANSPARENT, 10, K.line)
            clipToOutline = true
            alpha = if (enabled) 1f else 0.4f
        }
        options.forEachIndexed { i, (key, label) ->
            if (i > 0) bar.addView(View(a).apply { setBackgroundColor(K.line) }, LinearLayout.LayoutParams(1, ViewGroup.LayoutParams.MATCH_PARENT))
            val on = key == selected
            bar.addView(a.label(label, 13f, if (on) K.text else K.dim).apply {
                gravity = Gravity.CENTER
                maxLines = 1
                setPadding(0, a.dp(9), 0, a.dp(9))
                if (on) setBackgroundColor(KS.segOn)
                contentDescription = label
                isSelected = on
                if (enabled && !on) setOnClickListener { onPick(key) }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        add(bar, lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            setMargins(a.dp(4), a.dp(6), a.dp(4), a.dp(6))
        })
    }

    /** Small outlined chips under a row (a model family's versions). */
    fun chips(options: List<Pair<String, String>>, selected: String?, enabled: Boolean = true, onPick: (String) -> Unit) {
        val line = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; setPadding(a.dp(22), 0, 0, a.dp(8)) }
        for ((key, label) in options) {
            val on = key == selected
            line.addView(a.label(label, 13f, if (on) K.text else K.dim).apply {
                background = a.rounded(if (on) KS.chipOn else Color.TRANSPARENT, 8, if (on) K.accent else K.line)
                setPadding(a.dp(10), a.dp(4), a.dp(10), a.dp(4))
                contentDescription = label
                isSelected = on
                alpha = if (enabled) 1f else 0.4f
                if (enabled && !on) setOnClickListener { onPick(key) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = a.dp(6) })
        }
        lastWasItem = false
        body.addView(android.widget.HorizontalScrollView(a).apply { isHorizontalScrollBarEnabled = false; addView(line) })
    }

    /** A row with a switch on the right. */
    fun toggle(title: String, on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
        val track = FrameLayout(a).apply {
            background = a.rounded(if (on) K.accent else Color.parseColor("#3A3F45"), 11)
            addView(View(a).apply { background = a.rounded(Color.parseColor("#DDDDDD"), 8) },
                FrameLayout.LayoutParams(a.dp(16), a.dp(16), Gravity.CENTER_VERTICAL or if (on) Gravity.END else Gravity.START).apply { setMargins(a.dp(2), 0, a.dp(2), 0) })
        }
        val row = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = a.dp(50)
            setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(10))
            addView(a.label(title, 15f), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(track, LinearLayout.LayoutParams(a.dp(38), a.dp(22)))
            contentDescription = title
            isSelected = on
            alpha = if (enabled) 1f else 0.4f
            if (enabled) setOnClickListener { onChange(!on) }
        }
        add(row, item = true)
    }

    /** One text field, no learning from what's typed. */
    fun field(hint: String, text: String = "", lines: Int = 1): EditText {
        val f = EditText(a).apply {
            this.hint = hint
            setHintTextColor(K.faint)
            setTextColor(K.text)
            textSize = 15f
            setText(text)
            setSelection(this.text.length)
            background = a.rounded(KS.field, 10, K.line)
            setPadding(a.dp(12), a.dp(10), a.dp(12), a.dp(10))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
                (if (lines > 1) InputType.TYPE_TEXT_FLAG_MULTI_LINE else InputType.TYPE_TEXT_FLAG_CAP_SENTENCES)
            imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            maxLines = lines
            contentDescription = hint
        }
        add(f, lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            setMargins(a.dp(4), a.dp(8), a.dp(4), a.dp(4))
        })
        return f
    }

    /** Cancel and the one action, side by side. */
    fun buttons(primary: String, danger: Boolean = false, cancel: String = "Cancel", onPrimary: () -> Unit) {
        val row = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
        fun button(text: String, fill: Int, ink: Int, stroke: Int?, go: () -> Unit) = a.label(text, 15f, ink, bold = fill != Color.TRANSPARENT && ink != K.text).apply {
            gravity = Gravity.CENTER
            background = a.rounded(fill, 12, stroke)
            setPadding(0, a.dp(12), 0, a.dp(12))
            contentDescription = text
            setOnClickListener { go() }
        }
        row.addView(button(cancel, Color.TRANSPARENT, K.dim, K.line) { dismiss() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = a.dp(8) })
        row.addView(if (danger) button(primary, Color.TRANSPARENT, K.err, K.err) { onPrimary() } else button(primary, K.accent, Color.parseColor("#0B1220"), null) { onPrimary() },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        add(row, lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            setMargins(a.dp(4), a.dp(12), a.dp(4), 0)
        })
    }

    fun custom(v: View) = add(v)
}

/**
 * A long-press menu: a small card by the pressed row, the row held while it shows. An item with
 * [Item.sub] opens its list in place, with the parent's name to go back.
 */
class PopMenu(private val a: Activity) {
    class Item(
        val title: String, val detail: String? = null, val danger: Boolean = false, val enabled: Boolean = true,
        val rule: Boolean = false, val checked: Boolean = false, val dot: Int? = null,
        val sub: (() -> List<Item>)? = null, val onTap: (() -> Unit)? = null,
    )

    private val list = a.column().apply { setPadding(0, a.dp(4), 0, a.dp(4)) }
    private val popup = PopupWindow(ScrollView(a).apply {
        addView(list)
        background = a.rounded(KS.menu, 14, K.line)
        isVerticalScrollBarEnabled = false
    }, a.dp(232), ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
        elevation = a.dp(12).toFloat()
        setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        isOutsideTouchable = true
    }

    fun show(anchor: View, items: List<Item>) {
        fill(items, null)
        val oldBg = anchor.foreground
        anchor.foreground = a.rounded(Color.argb(40, 255, 255, 255), 12, KS.heldLine)
        popup.setOnDismissListener { anchor.foreground = oldBg }
        // Just below the row, so the menu never covers the text it acts on.
        popup.showAsDropDown(anchor, a.dp(56), a.dp(4))
    }

    fun dismiss() = popup.dismiss()

    private fun fill(items: List<Item>, back: Pair<String, List<Item>>?) {
        list.removeAllViews()
        if (back != null) {
            list.addView(entry("‹  ${back.first}", null, K.dim, true) { fill(back.second, null) })
            list.addView(View(a).apply { setBackgroundColor(Color.parseColor("#33373C")) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, a.dp(4), 0, a.dp(4)) })
        }
        for (it in items) {
            if (it.rule) list.addView(View(a).apply { setBackgroundColor(Color.parseColor("#33373C")) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, a.dp(4), 0, a.dp(4)) })
            val right = when { it.checked -> "✓"; it.sub != null -> (it.detail?.let { d -> "$d ›" } ?: "›"); else -> it.detail }
            list.addView(entry(it.title, right, if (it.danger) K.err else K.text, it.enabled, it.dot) {
                val sub = it.sub
                if (sub != null) fill(sub(), it.title to items) else { popup.dismiss(); it.onTap?.invoke() }
            })
        }
    }

    private fun entry(title: String, right: String?, color: Int, enabled: Boolean, dot: Int? = null, go: () -> Unit) = LinearLayout(a).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = a.dp(44)
        setPadding(a.dp(16), a.dp(8), a.dp(14), a.dp(8))
        if (dot != null) addView(View(a).apply { background = a.rounded(dot, 3) }, LinearLayout.LayoutParams(a.dp(10), a.dp(10)).apply { marginEnd = a.dp(10) })
        addView(a.label(title, 15f, color).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (right != null) addView(a.label(right, 13f, if (right == "✓") K.accent else K.faint).apply { setPadding(a.dp(8), 0, 0, 0) })
        contentDescription = title
        alpha = if (enabled) 1f else 0.4f
        if (enabled) { setBackgroundResource(android.R.drawable.list_selector_background); setOnClickListener { go() } }
    }
}

/** One quiet line at the bottom of a screen, for a moment: a refusal or what just happened. */
object Quiet {
    fun say(a: Activity, text: String) {
        val root = a.findViewById<FrameLayout>(android.R.id.content) ?: return
        val old = root.findViewWithTag<View>("kore.quiet")
        if (old != null) root.removeView(old)
        val v = a.label(text, 13f, K.dim).apply {
            tag = "kore.quiet"
            background = a.rounded(K.surface, 12, K.line)
            setPadding(a.dp(14), a.dp(9), a.dp(14), a.dp(9))
            maxLines = 2
        }
        root.addView(v, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            setMargins(a.dp(24), 0, a.dp(24), a.dp(28))
        })
        v.postDelayed({ root.removeView(v) }, 3500)
    }
}

/** A refused command in one short line. */
fun refusalWords(code: String?): String = when {
    code == null -> "That wasn't done."
    code == "denied.control" || code == "denied.command" -> "That needs the device itself."
    code == "denied.mac" -> "That needs the Mac."
    code == "denied.raiseMode" -> "That mode needs your fingerprint."
    code == "rateLimited" -> "Too fast. Try again in a moment."
    code == "expired" -> "Not sent: connection lost."
    code == "offline" -> "Not connected."
    code == "timeout" -> "No answer. Try again."
    code == "invalid" -> "Kore there doesn't take that yet."
    code.startsWith("busy") -> "Busy there. Try again in a moment."
    code.startsWith("gone") -> "That's no longer there."
    code.startsWith("stale") -> "That changed. Look again."
    code.startsWith("denied") -> "Not allowed from the phone."
    else -> "Not done ($code)."
}

/**
 * Runs one act-tier command and answers on the UI thread: [ok] with the result, a refusal as one
 * quiet line through [say]. `confirm.close` asks [ask] first and sends [forced] on yes.
 */
fun Activity.act(
    cmd: JsonObject, say: (String) -> Unit = { Quiet.say(this, it) }, forced: JsonObject? = null, ask: String? = null,
    ok: (JsonObject) -> Unit = {},
) {
    val link: NodeClient = kore.mesh.node(nodeId) ?: return say("Not connected")
    kore.scope.launch {
        val r = link.call(cmd)
        runOnUiThread {
            when {
                r.bool("ok") -> ok(r)
                r.str("code") == "confirm.close" && forced != null -> confirmClose(ask ?: "It's working. Closing stops it.") { act(forced, say, null, null, ok) }
                else -> say(refusalWords(r.str("code")))
            }
        }
    }
}

/** The close question: work would stop. */
fun Activity.confirmClose(line: String, go: () -> Unit) {
    lateinit var s: Sheet
    s = Sheet(this, K.err).show {
        title("Stop and close?", line)
        buttons("Stop and close", danger = true) { s.dismiss(); go() }
    }
}

/** Whether the device offers link 1.2's control surface: caps say so, or the state carries it. */
fun NodeClient?.hasControl(snapshot: JsonObject?): Boolean {
    val caps = this?.welcome?.value?.strs("caps").orEmpty()
    return "control" in caps || snapshot?.containsKey("mac") == true || snapshot?.objs("chats")?.any { it.containsKey("controls") } == true
}

/** Adds a glyph button at the end of a [NodeActivity]'s top bar. */
fun Activity.barButton(bar: View, glyph: String, description: String, go: (View) -> Unit): TextView {
    val b = label(glyph, 20f, K.dim).apply {
        gravity = Gravity.CENTER
        contentDescription = description
        isClickable = true
        setOnClickListener { go(it) }
    }
    (bar.parent as LinearLayout).addView(b, LinearLayout.LayoutParams(dp(44), dp(48)))
    return b
}
