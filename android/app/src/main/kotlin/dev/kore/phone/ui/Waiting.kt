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
