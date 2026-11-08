package dev.kore.phone.ui

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
    val claude = Color.parseColor("#D97757")
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
        addView(label(detail, 12f, K.faint))
        if (onClick != null) setOnClickListener { onClick() } else alpha = 0.55f
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

/** A CLI's mark: Claude's spark in its orange, Codex's ring in the dim text colour. */
fun providerMark(provider: String?): CharSequence {
    val (glyph, color) = if (provider == "codex") "◎" to K.dim else "✳" to K.claude
    return android.text.SpannableString(glyph).apply {
        setSpan(android.text.style.ForegroundColorSpan(color), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
}
