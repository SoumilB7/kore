package dev.kore.phone.ui

import android.content.Context
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.view.View
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * The Mac's render tree as real views: paragraphs read at 15sp with room between lines, code and
 * tables scroll sideways in their own box instead of wrapping into mush, and lists keep their
 * indent. No markdown parser on the phone; Kore sends the tree.
 */
object DocViews {
    private const val BODY = 15f
    private const val LINE = 1.4f
    private val CODE = android.graphics.Color.parseColor("#E8C08A")

    fun build(ctx: Context, blocks: List<JsonObject>, into: LinearLayout, color: Int = K.text) {
        into.removeAllViews()
        blocks.forEachIndexed { i, b -> into.addView(block(ctx, b, color), gap(ctx, if (i == 0) 0 else spacing(b))) }
    }

    private fun spacing(b: JsonObject) = when (b.str("k")) { "heading" -> 14; "code", "table" -> 10; else -> 8 }

    private fun gap(ctx: Context, top: Int) = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply { topMargin = ctx.dp(top) }

    private fun block(ctx: Context, b: JsonObject, color: Int): View = when (b.str("k")) {
        "heading" -> text(ctx, spans(b.objs("spans")), color).apply {
            textSize = when (b["level"].int() ?: 2) { 1 -> 20f; 2 -> 18f; else -> 16f }
            setTypeface(typeface, Typeface.BOLD)
        }
        "paragraph" -> text(ctx, spans(b.objs("spans")), color)
        "code" -> code(ctx, b.str("text").orEmpty().trimEnd(), b.str("lang"))
        "list" -> list(ctx, b, color)
        "quote" -> LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(View(ctx).apply { setBackgroundColor(K.line) }, LinearLayout.LayoutParams(ctx.dp(2), LinearLayout.LayoutParams.MATCH_PARENT).apply { rightMargin = ctx.dp(10) })
            addView(LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; build(ctx, b.objs("blocks"), this, K.dim) },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        "table" -> table(ctx, b)
        "rule" -> View(ctx).apply { setBackgroundColor(K.line); minimumHeight = 1 }
        else -> View(ctx)
    }

    private fun text(ctx: Context, s: CharSequence, color: Int) = TextView(ctx).apply {
        text = s
        textSize = BODY
        setTextColor(color)
        setLineSpacing(0f, LINE)
        setTextIsSelectable(true)
    }

    /** A fenced block: its own surface box, monospaced, scrolling sideways so lines never wrap. */
    private fun code(ctx: Context, body: String, lang: String?) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        background = ctx.rounded(K.surface, 8, K.line)
        setPadding(ctx.dp(12), ctx.dp(8), ctx.dp(12), ctx.dp(10))
        if (!lang.isNullOrBlank()) addView(ctx.label(lang, 11f, K.faint).apply { setPadding(0, 0, 0, ctx.dp(4)) })
        addView(HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            addView(TextView(ctx).apply {
                text = body
                typeface = Typeface.MONOSPACE
                textSize = 13f
                setTextColor(K.text)
                setLineSpacing(0f, 1.25f)
                setHorizontallyScrolling(true)
                setTextIsSelectable(true)
            })
        })
    }

    private fun list(ctx: Context, b: JsonObject, color: Int) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        val ordered = b.bool("ordered")
        var n = b["start"].int() ?: 1
        b.objs("items").forEachIndexed { i, item ->
            addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(ctx.label(if (ordered) "${n++}." else "•", BODY, K.dim).apply {
                    setLineSpacing(0f, LINE)
                    gravity = android.view.Gravity.END
                }, LinearLayout.LayoutParams(ctx.dp(22), LinearLayout.LayoutParams.WRAP_CONTENT).apply { rightMargin = ctx.dp(8) })
                addView(LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL; build(ctx, item.objs("blocks"), this, color) },
                    LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            }, gap(ctx, if (i == 0) 0 else 4))
        }
    }

    /** A grid in its own box that scrolls sideways; the header row is bold. */
    private fun table(ctx: Context, b: JsonObject): View {
        val header = (b["header"] as? JsonArray)?.map { cellSpans(it) }.orEmpty()
        val rows = (b["rows"] as? JsonArray)?.map { row -> (row as? JsonArray)?.map { cellSpans(it) }.orEmpty() }.orEmpty()
        val grid = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        fun addRow(cells: List<List<JsonObject>>, bold: Boolean, last: Boolean) {
            grid.addView(LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                cells.forEach { cell ->
                    addView(TextView(ctx).apply {
                        text = spans(cell)
                        textSize = 14f
                        setTextColor(if (bold) K.text else K.dim)
                        if (bold) setTypeface(typeface, Typeface.BOLD)
                        minWidth = ctx.dp(96)
                        setPadding(ctx.dp(10), ctx.dp(7), ctx.dp(10), ctx.dp(7))
                    })
                }
            })
            if (!last) grid.addView(View(ctx).apply { setBackgroundColor(K.line) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1))
        }
        addRow(header, true, rows.isEmpty())
        rows.forEachIndexed { i, r -> addRow(r, false, i == rows.lastIndex) }
        return HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            background = ctx.rounded(K.surface, 8, K.line)
            addView(grid)
        }
    }

    private fun cellSpans(e: kotlinx.serialization.json.JsonElement): List<JsonObject> =
        (e as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()

    private fun spans(spans: List<JsonObject>): CharSequence = SpannableStringBuilder().apply {
        for (s in spans) {
            val start = length
            append(s.str("text").orEmpty())
            val end = length
            if (start == end) continue
            if (s.bool("strong")) setSpan(StyleSpan(Typeface.BOLD), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("em")) setSpan(StyleSpan(Typeface.ITALIC), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("strike")) setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("code")) {
                // Monospaced and tinted, not boxed: a background slab grows with the line spacing.
                setSpan(TypefaceSpan("monospace"), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(ForegroundColorSpan(CODE), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (s.str("link") != null) setSpan(ForegroundColorSpan(K.accent), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }
}
