package dev.kore.phone.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Kore's dark look, in code: the Mac's one-hue ramp (206°, the logo's blue; Theme.swift). Grounds
 * and lines are that hue at low saturation, raised layers lighter, saturation kept for what acts;
 * red is the one exception.
 */
object K {
    val bg = Color.parseColor("#111113")
    val surface = Color.parseColor("#171D21")
    val hover = Color.parseColor("#1D252A")
    val raised = Color.parseColor("#263036")
    /** `#BED7EB` at 9 % over the ground. */
    val line = Color.parseColor("#212326")
    val text = Color.parseColor("#EDEDED")
    val dim = Color.parseColor("#89959F")
    val faint = Color.parseColor("#77828B")
    val accent = Color.parseColor("#6AB1E7")
    /** Text on an accent fill. */
    val onAccent = Color.parseColor("#0F1418")
    val ok = Color.parseColor("#74C991")
    val warn = Color.parseColor("#E1C08D")
    val err = Color.parseColor("#F0736B")
    val claude = Color.parseColor("#F59A55")
    /** The hue's saturated steps. */
    val b200 = Color.parseColor("#A3C3DC")
    val b400 = Color.parseColor("#3C97DD")
}

fun Context.dp(v: Int) = (v * resources.displayMetrics.density).toInt()

fun Context.label(text: CharSequence = "", size: Float = 15f, color: Int = K.text, bold: Boolean = false, mono: Boolean = false) =
    TextView(this).apply {
        this.text = text
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
        if (mono) typeface = Typeface.MONOSPACE
    }

fun Context.column(padding: Int = 0) = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
}

fun Context.rounded(color: Int, radius: Int = 10, stroke: Int? = null) = GradientDrawable().apply {
    setColor(color)
    cornerRadius = dp(radius).toFloat()
    stroke?.let { setStroke(dp(1), it) }
}

/** The press: a soft light over the view's own ground, clipped to its corners, drawn only while held. */
fun View.pressable(radius: Int = 10): View {
    val mask = context.rounded(Color.WHITE, radius)
    background = RippleDrawable(ColorStateList.valueOf(0x22FFFFFF), background, mask)
    return this
}

/** Kore's switch (38×22, the full-control mockup's pill): the one toggle style on the phone. */
fun Context.switchTrack(on: Boolean): View = android.widget.FrameLayout(this).apply {
    background = rounded(if (on) K.accent else Color.parseColor("#3A3F45"), 11)
    addView(View(context).apply { background = rounded(Color.parseColor("#DDDDDD"), 8) },
        android.widget.FrameLayout.LayoutParams(dp(16), dp(16), Gravity.CENTER_VERTICAL or if (on) Gravity.END else Gravity.START).apply { setMargins(dp(2), 0, dp(2), 0) })
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
}

/** A row that holds a [switchTrack]: read aloud as a switch with its title and state. */
fun View.switchSemantics(title: String, on: Boolean) {
    contentDescription = title
    accessibilityDelegate = object : View.AccessibilityDelegate() {
        override fun onInitializeAccessibilityNodeInfo(host: View, info: android.view.accessibility.AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(host, info)
            info.className = android.widget.Switch::class.java.name
            info.isCheckable = true
            info.isChecked = on
        }
    }
}

/** A line glyph inline with text (a file, an attachment), sized to the text around it. */
fun Context.glyphSpan(res: Int, size: Int = 14): CharSequence {
    val d: Drawable = getDrawable(res)?.mutate() ?: return ""
    d.setBounds(0, 0, dp(size), dp(size))
    return android.text.SpannableString("\uFFFC").apply {
        setSpan(android.text.style.ImageSpan(d, android.text.style.DynamicDrawableSpan.ALIGN_CENTER), 0, 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
}

/** A tappable row: a dot for the state, a title, and a faint word on the right. */
fun Context.row(title: String, detail: String, dot: Int?, mark: CharSequence? = null, onClick: (() -> Unit)?): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(13), dp(14), dp(13))
        background = rounded(K.surface)
        if (dot != null) addView(View(context).apply { background = rounded(dot, 4) }, LinearLayout.LayoutParams(dp(8), dp(8)).apply { rightMargin = dp(12) })
        if (mark != null) addView(label(mark, 15f).apply { setPadding(0, 0, dp(8), 0) })
        addView(label(title, 15f).apply { maxLines = 2 }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (detail.isNotEmpty()) addView(label(detail, 12f, K.faint))
        if (onClick != null) { setOnClickListener { onClick() }; pressable() } else alpha = 0.55f
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(6) }
    }

/** A chat's state as its dot colour and word. */
fun stateLook(state: String?): Pair<Int, String> = when (state) {
    "needsYou" -> K.warn to "needs you"
    "failed" -> K.err to "failed"
    "stuck" -> K.err to "stuck"
    "working" -> K.accent to "working"
    else -> K.faint to "idle"
}

/** A list row's state: idle is the default and says nothing (its dot's place stays, empty). */
fun rowLook(state: String?): Pair<Int, String> =
    if (state == null || state == "idle") android.graphics.Color.TRANSPARENT to "" else stateLook(state)

/** A CLI's mark: Claude's spark in its orange, Codex's ring in the dim text colour. */
fun providerMark(provider: String?): CharSequence {
    val (glyph, color) = if (provider == "codex") "◎" to K.dim else "✳\uFE0E" to K.claude
    return android.text.SpannableString(glyph).apply {
        setSpan(android.text.style.ForegroundColorSpan(color), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
}

/**
 * Edge to edge (Android 15 draws every screen under the system bars): the content keeps clear of
 * the status bar, the gesture bar, a cutout and the keyboard, and is at most 560 dp wide, centred.
 * Runs once per screen; a size change (rotation, a fold) measures the sides again.
 */
fun fitBars(a: android.app.Activity) {
    val content = a.findViewById<android.view.ViewGroup>(android.R.id.content) ?: return
    a.window.setDecorFitsSystemWindows(false)
    val widest = a.dp(560)
    val kinds = android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout() or android.view.WindowInsets.Type.ime()
    content.setOnApplyWindowInsetsListener { v, insets ->
        val bars = insets.getInsets(kinds)
        val side = maxOf(0, (v.width - bars.left - bars.right - widest) / 2)
        v.setPadding(bars.left + side, bars.top, bars.right + side, bars.bottom)
        android.view.WindowInsets.CONSUMED
    }
    content.addOnLayoutChangeListener { v, left, _, right, _, oldLeft, _, oldRight, _ -> if (right - left != oldRight - oldLeft) v.requestApplyInsets() }
}

/**
 * Rows kept between redraws by what they show: a redraw reuses each unchanged row's view instead
 * of building it again, and drops the rest. The key holds everything the row draws or acts on.
 */
class RowCache {
    private var kept = HashMap<Any, View>()
    private var used = HashMap<Any, View>()

    fun row(key: Any, make: () -> View): View {
        // The same key twice in one draw: the second gets its own view.
        if (key in used) return make()
        val v = kept.remove(key) ?: make()
        (v.parent as? android.view.ViewGroup)?.removeView(v)
        used[key] = v
        return v
    }

    /** The draw is over: rows not used this time are let go. */
    fun done() {
        kept = used
        used = HashMap()
    }
}
