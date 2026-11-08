package dev.kore.phone.ui

import android.content.Context
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.text.style.ImageSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.serialization.json.JsonObject

/**
 * What a chat waits on in the background (link 1.13 `background`): its live sub-agents and its
 * running background commands. Shown as symbols only (spec §4): no names, no list, nothing to
 * tap. A chat with either counts as working, between turns too.
 */
data class Waiting(val agents: Int, val commands: Int) {
    /** What TalkBack reads for the symbols. */
    val words: String
        get() = listOfNotNull("Waiting on a sub-agent".takeIf { agents > 0 }, "Waiting on a command".takeIf { commands > 0 }).joinToString(", ")

    companion object {
        /** A chat's `background`, or null when it's absent or both counts are 0. */
        fun of(chat: JsonObject?): Waiting? {
            val b = chat?.obj("background") ?: return null
            val agents = maxOf(0, b["agents"].int() ?: 0)
            val commands = maxOf(0, b["commands"].int() ?: 0)
            return if (agents > 0 || commands > 0) Waiting(agents, commands) else null
        }

        /**
         * bg-command-cue.html C: only background commands run while the model is idle, or waits
         * on you (a card open beside them). The lead is then ">_", not the spinner; a running
         * sub-agent is the model at work.
         */
        fun promptOnly(chat: JsonObject?): Boolean {
            val w = of(chat) ?: return false
            return w.agents == 0 && w.commands > 0 && (chat?.bool("running") != true || chat.str("state") == "needsYou")
        }
    }
}

/**
 * ">_" in the lead's place (bg-command-cue.html C): `dim`, the cursor blinking (1.1 s, shown 55%),
 * the amber point on its corner while the chat needs you. Ticks only while attached and while
 * animations are on; held still otherwise.
 */
class PromptMark(context: Context) : View(context) {
    private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        style = android.graphics.Paint.Style.STROKE
        strokeCap = android.graphics.Paint.Cap.ROUND
        strokeJoin = android.graphics.Paint.Join.ROUND
    }
    private val point = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = Tone.warn }
    private var shown = true
    var needsYou = false
        set(v) { if (field != v) { field = v; invalidate() } }
    private val tick = object : Runnable {
        override fun run() {
            shown = !shown
            invalidate()
            if (isAttachedToWindow && Motion.scale > 0f) postDelayed(this, if (shown) ON_MS else OFF_MS)
        }
    }

    init {
        contentDescription = "Background commands running"
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        shown = true
        if (Motion.scale > 0f) postDelayed(tick, ON_MS)
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: android.graphics.Canvas) {
        val u = minOf(width, height) / 14f
        val ox = (width - 14f * u) / 2f
        val oy = (height - 14f * u) / 2f
        paint.color = Tone.dim
        paint.strokeWidth = 1.5f * u
        val chevron = android.graphics.Path().apply {
            moveTo(ox + 1.8f * u, oy + 3.6f * u); lineTo(ox + 6f * u, oy + 7f * u); lineTo(ox + 1.8f * u, oy + 10.4f * u)
        }
        canvas.drawPath(chevron, paint)
        if (shown) canvas.drawLine(ox + 7.4f * u, oy + 10.9f * u, ox + 12.4f * u, oy + 10.9f * u, paint)
        if (needsYou) canvas.drawCircle(ox + 13f * u, oy + 1.6f * u, 3f * u, point)
    }

    companion object {
        const val ON_MS = 605L
        const val OFF_MS = 495L
    }
}

/** The terminal symbol's look: ">_" in Roboto Mono 10.5, weight 600, dim. */
private const val TERMINAL = ">_"
private const val TERMINAL_SP = 10.5f

/** The symbols at the start of a row's second line, 4 apart and 8 before the text (spec §4). */
fun Context.waitingPrefix(w: Waiting): CharSequence = SpannableStringBuilder().apply {
    if (w.agents > 0) {
        val d = getDrawable(dev.kore.phone.R.drawable.i_waiting_agent)!!.mutate().apply { setBounds(0, 0, dp(16), dp(16)) }
        append("￼", ImageSpan(d, ImageSpan.ALIGN_CENTER), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        append(" ")
    }
    if (w.commands > 0) {
        val start = length
        append(TERMINAL)
        setSpan(TypefaceSpan("monospace"), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(StyleSpan(Typeface.BOLD), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(AbsoluteSizeSpan(TERMINAL_SP.toInt().coerceAtLeast(10), true), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(ForegroundColorSpan(Tone.dim), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        append(" ")
    }
    append(" ")
}

/** The symbols as views, for the chat's bar (8 after the title, 4 apart). Not focusable or tappable; read as words. */
fun Context.waitingSymbols(): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    isClickable = false
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    addView(ImageView(context).apply { setImageResource(dev.kore.phone.R.drawable.i_waiting_agent) },
        LinearLayout.LayoutParams(dp(16), dp(16)))
    addView(TextView(context).apply {
        text = TERMINAL
        textSize = TERMINAL_SP
        typeface = Typeface.create(Typeface.MONOSPACE, 600, false)
        setTextColor(Tone.dim)
        includeFontPadding = false
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(4) })
}

/** Shows [w]'s symbols in [v] (from [waitingSymbols]), or hides it. */
fun LinearLayout.showWaiting(w: Waiting?) {
    visibility = if (w == null) View.GONE else View.VISIBLE
    if (w == null) return
    getChildAt(0).visibility = if (w.agents > 0) View.VISIBLE else View.GONE
    getChildAt(1).visibility = if (w.commands > 0) View.VISIBLE else View.GONE
    (getChildAt(1).layoutParams as LinearLayout.LayoutParams).marginStart = if (w.agents > 0) context.dp(4) else 0
    contentDescription = w.words
}
