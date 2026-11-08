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
    val pop = Tone.l1
    val menu = Tone.l2
    val divider = Tone.hair2
    val segOn = Tone.l3
    val chipOn = Tone.accentFill
    val field = Tone.bg
    val held = Tone.l2
    val heldLine = Tone.hair2
    val grab = Tone.grab
    val plan = Tone.plan
    val danger = Tone.err
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
    "grey" -> Tone.groupGrey
    "blue" -> Tone.groupBlue
    "teal" -> Tone.groupTeal
    "green" -> Tone.groupGreen
    "sand" -> Tone.groupSand
    "orange" -> Tone.groupOrange
    "rose" -> Tone.groupRose
    "violet" -> Tone.groupViolet
    else -> runCatching { Color.parseColor(name) }.getOrDefault(K.dim)
}
val GROUP_COLORS = listOf("blue", "teal", "green", "sand", "orange", "rose", "violet", "grey")

/** A board section's swatch: Kore's blue shades, or a neutral grey. */
fun swatchColor(name: String?): Int? = when (name) {
    "b200" -> Tone.b200
    "b300" -> Tone.accent
    "b400" -> Tone.b400
    "b600" -> Tone.b600
    "neutral" -> K.dim
    else -> null
}
val SWATCHES = listOf("b200", "b300", "b400", "b600", "neutral")

/** The sheet's ground: rounded top, a hairline, and the two accent corner marks. */
private class SheetGround(private val density: Float, var corner: Int) : Drawable() {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Tone.l1 }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Tone.hair2; style = Paint.Style.STROKE; strokeWidth = density }
    private val mark = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.5f * density; strokeCap = Paint.Cap.ROUND }

    override fun draw(c: Canvas) {
        val b = bounds
        val r = Radius.sheet * density
        val path = Path().apply {
            addRoundRect(RectF(b), floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f), Path.Direction.CW)
        }
        c.drawPath(path, fill)
        c.drawLine(b.left + r, b.top + line.strokeWidth / 2, b.right - r, b.top + line.strokeWidth / 2, line)
        mark.color = corner
        val h = mark.strokeWidth / 2
        // Each mark is 24 dp of the corner's arc, centred on it (spec §5), as the Mac's corner marks.
        val sweep = Math.toDegrees(24.0 / Radius.sheet).toFloat()
        c.drawArc(RectF(b.left + h, b.top + h, b.left + 2 * r, b.top + 2 * r), 225f - sweep / 2, sweep, false, mark)
        c.drawArc(RectF(b.right - 2 * r, b.top + h, b.right - h, b.top + 2 * r), 315f - sweep / 2, sweep, false, mark)
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
    private val note = a.label("").apply {
        type(Type.Caption); setTextColor(Tone.faint)
        visibility = View.GONE
        setPadding(a.dp(4), a.dp(8), a.dp(4), 0)
    }
    private var builder: (Sheet.() -> Unit)? = null
    private var lastWasItem = false

    init {
        val scroll = object : ScrollView(a) {
            override fun onMeasure(w: Int, h: Int) =
                super.onMeasure(w, MeasureSpec.makeMeasureSpec((a.resources.displayMetrics.heightPixels * 0.82f).toInt(), MeasureSpec.AT_MOST))
        }.apply { addView(body); isVerticalScrollBarEnabled = false }
        val root = a.column().apply {
            background = ground
            setPadding(a.dp(16), a.dp(8), a.dp(16), a.dp(26))
            addView(View(a).apply { background = a.shape(Tone.grab, 2) }, LinearLayout.LayoutParams(a.dp(36), a.dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL; topMargin = a.dp(4); bottomMargin = a.dp(14)
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
            setDimAmount(0.6f)
            @Suppress("DEPRECATION")
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
        // A builder that dismissed (its state was gone) leaves nothing to show: never an empty sheet.
        if (!dismissed && !a.isFinishing) dialog.show()
        return this
    }

    private var dismissed = false

    /** Draws the content again (the Mac's state changed under it). */
    fun refresh() {
        body.removeAllViews()
        lastWasItem = false
        builder?.invoke(this)
    }

    fun dismiss() { dismissed = true; runCatching { dialog.dismiss() } }
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
        add(a.label(text).apply { type(Type.Headline); setTextColor(Tone.text); setPadding(a.dp(4), a.dp(2), a.dp(4), 0) })
        if (sub != null) add(a.label(sub).apply { type(Type.Callout); setTextColor(Tone.dim); setPadding(a.dp(4), a.dp(4), a.dp(4), a.dp(6)) })
    }

    /** A section label (spec §2): sentence case, Label, dim; never uppercase and tracked. */
    fun section(text: String) =
        add(a.label(text).apply { type(Type.Label); setTextColor(Tone.dim); setPadding(a.dp(4), a.dp(16), a.dp(4), a.dp(6)) })

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
            minimumHeight = a.dp(52)
            setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(10))
            if (dot != null) addView(View(a).apply { background = a.shape(dot, 4) }, LinearLayout.LayoutParams(a.dp(8), a.dp(8)).apply { marginEnd = a.dp(14) })
            val icon = glyph?.let { iconFor(it.toString()) }
            if (icon != null) addView(android.widget.ImageView(a).apply {
                setImageResource(icon)
                imageTintList = android.content.res.ColorStateList.valueOf(if (danger) Tone.err else Tone.dim)
            }, LinearLayout.LayoutParams(a.dp(18), a.dp(18)).apply { marginEnd = a.dp(14) })
            else if (glyph != null) addView(a.label(glyph, 14f, if (danger) Tone.err else Tone.dim).apply { gravity = Gravity.CENTER },
                LinearLayout.LayoutParams(a.dp(20), ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = a.dp(12) })
            addView(a.label(title).apply { type(Type.Body); setTextColor(if (danger) Tone.err else Tone.text); maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            if (detail != null && !checked) addView(a.label(detail).apply { type(Type.Caption); setTextColor(Tone.faint); maxLines = 1; setPadding(a.dp(10), 0, 0, 0) })
            val end = when { checked -> dev.kore.phone.R.drawable.i_check; chevron -> dev.kore.phone.R.drawable.i_chevron; else -> null }
            if (end != null) addView(android.widget.ImageView(a).apply {
                setImageResource(end)
                imageTintList = android.content.res.ColorStateList.valueOf(if (checked) Tone.accent else Tone.faint)
            }, LinearLayout.LayoutParams(a.dp(18), a.dp(18)).apply { marginStart = a.dp(8) })
            contentDescription = tag ?: title.toString()
            isEnabled = enabled
            alpha = if (enabled) 1f else 0.4f
            if (enabled && onTap != null) {
                pressable()
                setOnClickListener { onTap() }
            }
        }
        add(row, item = true)
        return row
    }

    /**
     * Equal segments in one outlined bar (effort, the auto-compact point, Arsenal). [off]: shown
     * struck and faint, no tap (a level the model doesn't offer); [marked]: the fingerprint glyph
     * beside it (a raise).
     */
    fun segmented(
        options: List<Pair<String, String>>, selected: String?, enabled: Boolean = true, off: Set<String> = emptySet(),
        marked: Set<String> = emptySet(), onPick: (String) -> Unit,
    ) {
        // Spec §5: a bg well (radius 12, padding 3, a hair edge); segments 34 high, radius 9, Label;
        // the chosen one lifted on l3.
        val bar = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            background = a.shape(Tone.bg, 12, Tone.hair)
            val p = a.dp(3)
            setPadding(p, p, p, p)
            alpha = if (enabled) 1f else 0.4f
        }
        options.forEachIndexed { i, (key, label) ->
            val on = key == selected
            val struck = key in off
            bar.addView(a.label(label).apply {
                type(Type.Label)
                setTextColor(if (on) Tone.text else if (struck) Tone.faint else Tone.dim)
                gravity = Gravity.CENTER
                maxLines = 1
                minHeight = a.dp(34)
                if (on) { background = a.shape(Tone.l3, 9); elevation = a.dp(1).toFloat() }
                if (struck) { paintFlags = paintFlags or android.graphics.Paint.STRIKE_THRU_TEXT_FLAG; alpha = 0.5f }
                if (key in marked) {
                    setCompoundDrawablesRelativeWithIntrinsicBounds(0, 0, dev.kore.phone.R.drawable.ic_fingerprint, 0)
                    compoundDrawablePadding = a.dp(4)
                }
                contentDescription = when {
                    struck -> "$label, not offered"
                    key in marked -> "$label, takes your fingerprint"
                    else -> label
                }
                isSelected = on
                if (enabled && !on && !struck) { setOnClickListener { onPick(key) }; pressFill(null, Tone.l2, 9) }
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
            // Spec §5 version chip: 30 high, radius 15, l2 + dim at rest, accentFill + b200 chosen.
            line.addView(a.label(label).apply {
                type(Type.Label)
                setTextColor(if (on) Tone.b200 else Tone.dim)
                background = a.shape(if (on) Tone.accentFill else Tone.l2, 15)
                gravity = Gravity.CENTER
                minHeight = a.dp(30)
                setPadding(a.dp(12), 0, a.dp(12), 0)
                contentDescription = label
                isSelected = on
                alpha = if (enabled) 1f else 0.4f
                if (enabled && !on) { setOnClickListener { onPick(key) }; pressable(8) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = a.dp(6) })
        }
        lastWasItem = false
        body.addView(android.widget.HorizontalScrollView(a).apply { isHorizontalScrollBarEnabled = false; addView(line) })
    }

    /**
     * A model family's row (the picker, take 1): its name, then its versions as chips that wrap,
     * the chat's own lit. One tap on a chip picks it; a family of one is its name, a tap away.
     */
    fun family(name: String, versions: List<Pair<String, String>>, selected: String?, enabled: Boolean = true, onPick: (String) -> Unit) {
        val row = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = a.dp(50)
            setPadding(a.dp(4), a.dp(8), a.dp(4), a.dp(8))
        }
        val single = versions.size == 1 && versions[0].second.isEmpty()
        row.addView(a.label(name, 15f, K.text).apply { maxLines = 2 },
            if (single) LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f) else LinearLayout.LayoutParams(a.dp(76), ViewGroup.LayoutParams.WRAP_CONTENT))
        if (single) {
            val (id, _) = versions[0]
            if (id == selected) row.addView(a.label("✓", 16f, K.accent))
            row.contentDescription = "model $name"
            row.isSelected = id == selected
            if (enabled && id != selected) { row.setOnClickListener { onPick(id) }; row.pressable(0) }
        } else {
            val flow = Flow(a, a.dp(6))
            for ((id, label) in versions) {
                val on = id == selected
                flow.addView(a.label(label, 13f, if (on) K.text else K.dim).apply {
                    background = a.rounded(if (on) KS.chipOn else Color.TRANSPARENT, 14, if (on) K.accent else K.line)
                    setPadding(a.dp(10), a.dp(5), a.dp(10), a.dp(5))
                    maxLines = 1
                    contentDescription = "model $name $label"
                    isSelected = on
                    alpha = if (enabled) 1f else 0.4f
                    if (enabled && !on) { setOnClickListener { onPick(id) }; pressable(14) }
                })
            }
            row.addView(flow, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        add(row, item = true)
    }

    /** A row with a switch on the right. */
    fun toggle(title: String, on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
        val track = a.switchTrack(on)
        val row = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = a.dp(50)
            setPadding(a.dp(4), a.dp(10), a.dp(4), a.dp(10))
            addView(a.label(title, 15f), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(track, LinearLayout.LayoutParams(a.dp(38), a.dp(22)))
            switchSemantics(title, on)
            isSelected = on
            alpha = if (enabled) 1f else 0.4f
            if (enabled) { pressable(); setOnClickListener { onChange(!on) } }
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
            // Titles, names, compact notes: never a secret, so voice typing and suggestions stay on.
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
                (if (lines > 1) InputType.TYPE_TEXT_FLAG_MULTI_LINE else 0)
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
        // Spec §5 buttons: Cancel is secondary; the primary is accent, or destructive when it destroys something.
        row.addView(a.button(cancel, Btn.Secondary) { dismiss() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = a.dp(8) })
        row.addView(a.button(primary, if (danger) Btn.Destructive else Btn.Primary) { onPrimary() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
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

    private val list = a.column().apply { val p = a.dp(6); setPadding(p, p, p, p) }
    // Spec §5 pop menu: l2, radius 16, padding 6, a hair2 edge; rows 46 high, radius 11.
    private val popup = PopupWindow(ScrollView(a).apply {
        addView(list)
        background = a.shape(Tone.l2, Radius.menu, Tone.hair2)
        isVerticalScrollBarEnabled = false
    }, a.dp(232), ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
        elevation = a.dp(16).toFloat()
        setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        isOutsideTouchable = true
    }

    fun show(anchor: View, items: List<Item>) {
        fill(items, null)
        val oldBg = anchor.foreground
        // The held item gets a 2 dp accent ring at 50 %.
        anchor.foreground = a.shape(0, 12, null).apply { setStroke(a.dp(2), 0x806AB1E7.toInt()) }
        popup.setOnDismissListener { anchor.foreground = oldBg }
        // Just below the row, so the menu never covers the text it acts on.
        popup.showAsDropDown(anchor, a.dp(56), a.dp(4))
    }

    fun dismiss() = popup.dismiss()

    private fun fill(items: List<Item>, back: Pair<String, List<Item>>?) {
        list.removeAllViews()
        if (back != null) {
            list.addView(entry("‹  ${back.first}", null, K.dim, true) { fill(back.second, null) })
            list.addView(View(a).apply { setBackgroundColor(Tone.hair2) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, a.dp(4), 0, a.dp(4)) })
        }
        for (it in items) {
            if (it.rule) list.addView(View(a).apply { setBackgroundColor(Tone.hair2) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { setMargins(0, a.dp(4), 0, a.dp(4)) })
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
        minimumHeight = a.dp(46)
        setPadding(a.dp(12), 0, a.dp(12), 0)
        if (dot != null) addView(View(a).apply { background = a.shape(dot, 3) }, LinearLayout.LayoutParams(a.dp(10), a.dp(10)).apply { marginEnd = a.dp(12) })
        iconFor(title)?.let { icon ->
            addView(android.widget.ImageView(a).apply { setImageResource(icon); imageTintList = android.content.res.ColorStateList.valueOf(if (color == K.err) Tone.err else Tone.dim) },
                LinearLayout.LayoutParams(a.dp(18), a.dp(18)).apply { marginEnd = a.dp(12) })
        }
        addView(a.label(title).apply { type(Type.Body); setTextColor(color); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (right != null) addView(a.label(right).apply { type(Type.Callout); setTextColor(if (right == "✓") Tone.accent else Tone.faint); setPadding(a.dp(8), 0, 0, 0) })
        contentDescription = title
        alpha = if (enabled) 1f else 0.4f
        if (enabled) { pressFill(null, Tone.l3, Radius.menuRow); setOnClickListener { go() } }
    }
}

/** One quiet line at the bottom of a screen, for a moment: a refusal or what just happened. */
object Quiet {
    fun say(a: Activity, text: String) {
        val root = a.findViewById<FrameLayout>(android.R.id.content) ?: return
        val old = root.findViewWithTag<View>("kore.quiet")
        if (old != null) root.removeView(old)
        // Spec §5 toast: l3, radius 20, padding 10 × 16, Callout; 110 above the bottom, centred, 3.5 s.
        val v = a.label(text).apply {
            tag = "kore.quiet"
            type(Type.Callout)
            setTextColor(Tone.text)
            background = a.shape(Tone.l3, 20)
            elevation = a.dp(10).toFloat()
            setPadding(a.dp(16), a.dp(10), a.dp(16), a.dp(10))
            maxLines = 2
        }
        root.addView(v, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            setMargins(a.dp(24), 0, a.dp(24), a.dp(110))
        })
        v.postDelayed({ root.removeView(v) }, 3500)
    }
}

/** A refused command in one short line. */
fun refusalWords(code: String?): String = when {
    code == null -> "That wasn't done."
    code == "denied.control" || code == "denied.command" -> "Only on the Mac or box itself, not from the phone."
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
fun Activity.barButton(bar: View, glyph: String, description: String, go: (View) -> Unit): View {
    // The bar's glyphs as the icon set (spec §4: 22 in a 48 round target); another glyph stays text.
    val icon = when (glyph) {
        "＋" -> dev.kore.phone.R.drawable.i_plus
        "⋮" -> dev.kore.phone.R.drawable.i_more
        "▣" -> dev.kore.phone.R.drawable.i_archive
        else -> null
    }
    val b: View = if (icon != null) barIcon(icon, description) else label(glyph, 20f, K.dim).apply { gravity = Gravity.CENTER; contentDescription = description }
    b.setOnClickListener { go(it) }
    b.pressFill(null, Tone.l2, 24)
    if (glyph == "⋮") b.tag = MORE
    // The bar's row: the title sits in a column (its state line goes under it), so the button
    // goes on the first horizontal row above it, at the end, never under the title; ⋮ stays last.
    var row = bar.parent
    while (row is LinearLayout && row.orientation != LinearLayout.HORIZONTAL) row = row.parent
    val bar = row as LinearLayout
    val more = (0 until bar.childCount).firstOrNull { bar.getChildAt(it).tag == MORE }
    bar.addView(b, if (more != null && glyph != "⋮") more else bar.childCount, LinearLayout.LayoutParams(dp(48), dp(48)))
    return b
}

private const val MORE = "bar.more"

/** One of the bar's icons: 22 dp in a 48 dp round target, `dim` at rest. */
fun Activity.barIcon(icon: Int, description: String): android.widget.ImageView = android.widget.ImageView(this).apply {
    setImageResource(icon)
    imageTintList = android.content.res.ColorStateList.valueOf(Tone.dim)
    scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
    val pad = dp(13)
    setPadding(pad, pad, pad, pad)
    contentDescription = description
}

/** Children left to right, wrapping to the next line when the row is full (a family's version chips). */
class Flow(context: android.content.Context, private val gap: Int) : ViewGroup(context) {
    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val width = MeasureSpec.getSize(widthSpec)
        var x = 0
        var y = 0
        var line = 0
        var widest = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            c.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            if (x > 0 && x + c.measuredWidth > width) { x = 0; y += line + gap; line = 0 }
            x += c.measuredWidth + gap
            widest = maxOf(widest, x - gap)
            line = maxOf(line, c.measuredHeight)
        }
        setMeasuredDimension(if (MeasureSpec.getMode(widthSpec) == MeasureSpec.EXACTLY) width else minOf(widest, width), y + line)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val width = r - l
        var x = 0
        var y = 0
        var line = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (x > 0 && x + c.measuredWidth > width) { x = 0; y += line + gap; line = 0 }
            c.layout(x, y, x + c.measuredWidth, y + c.measuredHeight)
            x += c.measuredWidth + gap
            line = maxOf(line, c.measuredHeight)
        }
    }
}

/**
 * The icon set for a row's glyph or a menu row's title (spec §4): the old text glyphs and the
 * long-press menu's words map to their vector; anything else keeps its text.
 */
fun iconFor(glyphOrTitle: String): Int? = when (glyphOrTitle.trim()) {
    "✎", "Rename…", "Rename" -> dev.kore.phone.R.drawable.i_pencil
    "◔", "↓", "⤓", "Compact now", "Compact", "Auto-compact" -> dev.kore.phone.R.drawable.i_compact
    "□", "▦" -> dev.kore.phone.R.drawable.i_folder
    "⇢", "Show on the Mac" -> dev.kore.phone.R.drawable.i_mac_display
    "×", "Close window", "Close tab" -> dev.kore.phone.R.drawable.i_close_window
    "Copy" -> dev.kore.phone.R.drawable.i_copy
    "Fork from here", "Fork after this" -> dev.kore.phone.R.drawable.i_fork
    "Revert to here" -> dev.kore.phone.R.drawable.i_revert
    "Forget on this phone" -> dev.kore.phone.R.drawable.i_logout
    else -> null
}
