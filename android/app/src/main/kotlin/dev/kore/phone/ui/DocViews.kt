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
    /** The least a table column gets in a grid; under it the table stacks (spec §5). */
    private const val COL_MIN = 72
    /** A stacked card's header column: at least this, at most [STACK_HEADER_CAP] of the card. */
    private const val STACK_HEADER = 52
    private const val STACK_HEADER_CAP = 0.4f
    private const val CELL_SP = 14f
    private const val LINE = 1.4f
    private val CODE = Tone.code

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

    /** A fenced block (spec §5): the well, radius 12, a hair edge, Mono, scrolling sideways so lines never wrap. */
    private fun code(ctx: Context, body: String, lang: String?) = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        background = ctx.shape(Tone.well, 12, Tone.hair)
        setPadding(ctx.dp(14), ctx.dp(10), ctx.dp(14), ctx.dp(10))
        if (!lang.isNullOrBlank()) addView(ctx.label(lang).apply { type(Type.Caption); setTextColor(Tone.faint); setPadding(0, 0, 0, ctx.dp(4)) })
        addView(HorizontalScrollView(ctx).apply {
            isHorizontalScrollBarEnabled = false
            addView(TextView(ctx).apply {
                text = body
                type(Type.Mono)
                setTextColor(K.text)
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

    /**
     * A table that fits the width it gets (spec §5): a grid with wrapping cells when every column
     * can have [COL_MIN] dp, else one card per row. Nothing scrolls sideways. Which one is decided
     * by [TableFit] once the width is known, and again only if it changes (a rotation).
     */
    private fun table(ctx: Context, b: JsonObject): View {
        val header = (b["header"] as? JsonArray)?.map { spans(cellSpans(it)) }.orEmpty()
        val rows = (b["rows"] as? JsonArray)?.map { row -> (row as? JsonArray)?.map { spans(cellSpans(it)) }.orEmpty() }.orEmpty()
        return TableBox(ctx, header, rows)
    }

    /** The table [v] is in (or is), as "Copy table" copies it ([TableCopy]); null outside one. */
    fun tableText(v: View?): String? {
        var at: View? = v
        while (at != null) {
            if (at is TableBox) return TableCopy.text(at.header.map { it.toString() }, at.rows.map { r -> r.map { it.toString() } })
            at = at.parent as? View
        }
        return null
    }

    private class TableBox(ctx: Context, val header: List<CharSequence>, val rows: List<List<CharSequence>>) : LinearLayout(ctx) {
        private var builtFor = -1
        private val pad = ctx.dp(10)

        init { orientation = VERTICAL }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val width = MeasureSpec.getSize(widthMeasureSpec)
            if (width > 0 && width != builtFor) {
                builtFor = width
                build(width)
            }
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        }

        private fun columns(): Int = maxOf(header.size, rows.maxOfOrNull { it.size } ?: 0)

        /** Each column's one-line width (its widest cell) and longest word, padding included. */
        private fun measure(): Pair<List<Int>, List<Int>> {
            val paint = TextView(context).apply { textSize = CELL_SP }.paint
            val bold = TextView(context).apply { textSize = CELL_SP; setTypeface(typeface, Typeface.BOLD) }.paint
            val natural = ArrayList<Int>()
            val words = ArrayList<Int>()
            for (c in 0 until columns()) {
                val cells = listOfNotNull(header.getOrNull(c)?.let { it.toString() to bold }) + rows.mapNotNull { it.getOrNull(c)?.let { cell -> cell.toString() to paint } }
                natural += (cells.maxOfOrNull { (t, p) -> p.measureText(t) } ?: 0f).toInt() + 2 * pad + 1
                words += (cells.maxOfOrNull { (t, p) -> t.split(' ', '\n').maxOfOrNull { w -> p.measureText(w) } ?: 0f } ?: 0f).toInt() + 2 * pad + 1
            }
            return natural to words
        }

        private fun build(width: Int) {
            removeAllViews()
            val (natural, words) = measure()
            when (val fit = TableFit.fit(natural, words, width, context.dp(COL_MIN))) {
                is TableFit.Fit.Grid -> grid(fit.widths)
                TableFit.Fit.Stacked -> stacked(width)
            }
        }

        private fun cell(text: CharSequence, bold: Boolean) = TextView(context).apply {
            this.text = text
            textSize = CELL_SP
            setTextColor(if (bold) K.text else K.dim)
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(pad, context.dp(7), pad, context.dp(7))
        }

        private fun grid(widths: List<Int>) {
            background = context.shape(Tone.l1, 12, Tone.hair)
            val all = listOf(header to true) + rows.map { it to false }
            all.forEachIndexed { i, (cells, bold) ->
                if (cells.isEmpty()) return@forEachIndexed
                addView(LinearLayout(context).apply {
                    orientation = HORIZONTAL
                    widths.forEachIndexed { c, w -> addView(cell(cells.getOrNull(c) ?: "", bold), LayoutParams(w, LayoutParams.WRAP_CONTENT)) }
                })
                if (i < all.lastIndex) addView(View(context).apply { setBackgroundColor(Tone.hair) }, LayoutParams(LayoutParams.MATCH_PARENT, 1))
            }
        }

        /**
         * One card per row (spec §5): `l1`, radius 12, padding 10 × 14, 6 apart; the first column as
         * its title (Body medium), then "Header  value" lines. The header column fits the widest
         * header up to 40 % of the card ([TableFit.headers]); a header too long for it goes above.
         */
        private fun stacked(width: Int) {
            background = null
            val inner = width - context.dp(28)
            val paint = TextView(context).apply { type(Type.Callout) }.paint
            val heads = (1 until columns()).map { header.getOrNull(it)?.toString().orEmpty() }
            val fit = TableFit.headers(
                heads.map { paint.measureText(it).toInt() + 1 },
                heads.map { h -> (h.split(' ', '\n').maxOfOrNull { paint.measureText(it) } ?: 0f).toInt() + 1 },
                context.dp(STACK_HEADER), (inner * STACK_HEADER_CAP).toInt(),
            )
            rows.forEachIndexed { i, row ->
                addView(LinearLayout(context).apply {
                    orientation = VERTICAL
                    background = context.shape(Tone.l1, 12, Tone.hair)
                    setPadding(context.dp(14), context.dp(10), context.dp(14), context.dp(10))
                    addView(TextView(context).apply {
                        text = row.firstOrNull() ?: ""
                        type(Type.BodyMedium)
                        setTextColor(Tone.text)
                    })
                    for (c in 1 until columns()) {
                        val value = row.getOrNull(c)?.takeIf { it.isNotEmpty() } ?: continue
                        val above = fit.above.getOrElse(c - 1) { false }
                        addView(LinearLayout(context).apply {
                            orientation = if (above) VERTICAL else HORIZONTAL
                            setPadding(0, context.dp(4), 0, 0)
                            addView(TextView(context).apply {
                                text = header.getOrNull(c) ?: ""
                                type(Type.Callout)
                                setTextColor(Tone.faint)
                            }, if (above) LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
                            else LayoutParams(fit.width, LayoutParams.WRAP_CONTENT).apply { marginEnd = context.dp(10) })
                            addView(TextView(context).apply {
                                text = value
                                textSize = CELL_SP
                                setTextColor(Tone.text)
                            }, if (above) LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
                            else LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                        })
                    }
                }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { if (i > 0) topMargin = context.dp(6) })
            }
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
