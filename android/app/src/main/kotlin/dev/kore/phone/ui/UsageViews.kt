package dev.kore.phone.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout

/** A meter's colour: accent below 80 %, amber near the limit, red at it. */
fun usageColor(level: UsageMeters.Level): Int = when (level) {
    UsageMeters.Level.NORMAL -> Tone.accent
    UsageMeters.Level.NEAR -> Tone.warn
    UsageMeters.Level.AT -> Tone.err
}

/** A thin meter (4 high, round ends): an `l3` track filled as far as it's used. */
class UsageBar(context: Context) : View(context) {
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Tone.l3 }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    var pct = 0
        set(v) { if (field != v) { field = v; invalidate() } }
    var color = Tone.accent
        set(v) { if (field != v) { field = v; invalidate() } }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onDraw(canvas: Canvas) {
        val r = height / 2f
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        canvas.drawRoundRect(rect, r, r, track)
        val p = pct.coerceIn(0, 100)
        if (p == 0) return
        fill.color = color
        rect.set(0f, 0f, maxOf(height.toFloat(), width * p / 100f), height.toFloat())
        canvas.drawRoundRect(rect, r, r, fill)
    }
}

/**
 * One login's usage (link 1.14), as a device's Accounts row and the chat sheet's: the CLI's
 * logo, who it is and its plan; the two meters side by side ("5 h", "Week", each with its %);
 * then one line for the reset that matters. Nothing read yet: a faint "Not read yet".
 */
fun Context.usageRow(row: UsageMeters.Row, logo: Boolean = true): View = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(16), dp(12), dp(16), dp(12))
    addView(LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL
        if (logo) addView(android.widget.ImageView(context).apply { setImageResource(providerLogo(row.provider)) }, LinearLayout.LayoutParams(dp(17), dp(17)).apply { marginEnd = dp(10) })
        addView(label(row.name).apply { type(Type.BodyMedium); setTextColor(Tone.text); maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.plan?.let { addView(label(it).apply { type(Type.Caption); setTextColor(Tone.faint); setPadding(dp(10), 0, 0, 0) }) }
    })
    if (row.meters.isNotEmpty()) addView(LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL
        setPadding(if (logo) dp(27) else 0, dp(8), 0, 0)
        row.meters.forEachIndexed { i, m ->
            addView(label(m.label).apply { type(Type.Caption); setTextColor(Tone.dim) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { if (i > 0) marginStart = dp(16) })
            addView(UsageBar(context).apply { pct = m.pct; color = usageColor(m.level) }, LinearLayout.LayoutParams(0, dp(4), 1f).apply { marginStart = dp(8); marginEnd = dp(8) })
            addView(label("${m.pct}%").apply {
                type(Type.Caption)
                fontFeatureSettings = "tnum"
                // As wide as "100%": both meters keep their length whatever they read.
                minWidth = paint.measureText("100%").toInt() + 1
                gravity = Gravity.END
                setTextColor(if (m.level == UsageMeters.Level.NORMAL) Tone.dim else usageColor(m.level))
            })
        }
    })
    val note = row.note ?: if (row.meters.isEmpty()) "Not read yet" else null
    if (note != null) addView(label(note).apply {
        type(Type.Caption)
        setTextColor(if (row.note == null || row.noteLevel == UsageMeters.Level.NORMAL) Tone.faint else usageColor(row.noteLevel))
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        setPadding(if (logo) dp(27) else 0, dp(6), 0, 0)
    })
    contentDescription = UsageMeters.spoken(row, cliName(row.provider))
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
}

/** The CLI's name as people say it. */
fun cliName(provider: String): String = when (provider) {
    "claude" -> "Claude"
    "codex" -> "Codex"
    else -> provider.replaceFirstChar { it.uppercase() }
}

/** A device's Accounts (its footer): the section label, then its logins grouped, one row each. */
fun android.app.Activity.usageBlock(rows: List<UsageMeters.Row>): View = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    addView(sectionLabel("Accounts"))
    addView(grouped(rows.map { usageRow(it) }, inset = 43))
    setPadding(0, 0, 0, dp(8))
}
