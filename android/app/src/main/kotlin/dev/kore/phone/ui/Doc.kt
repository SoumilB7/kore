package dev.kore.phone.ui

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StrikethroughSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import kotlinx.serialization.json.JsonObject

/** The Mac's render tree (`Block`/`Span`) as styled text: no markdown parser on the phone. */
object Doc {
    fun render(blocks: List<JsonObject>): CharSequence = SpannableStringBuilder().also { out -> blocks.forEach { block(out, it, "") } }.trimEnd('\n')

    private fun block(out: SpannableStringBuilder, b: JsonObject, indent: String) {
        when (b.str("k")) {
            "heading" -> styled(out, Typeface.BOLD, 1.15f) { spans(out, b.objs("spans")) }.also { out.append("\n\n") }
            "paragraph" -> { out.append(indent); spans(out, b.objs("spans")); out.append("\n\n") }
            "code" -> {
                val start = out.length
                out.append(b.str("text").orEmpty().trimEnd())
                out.setSpan(TypefaceSpan("monospace"), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                out.setSpan(ForegroundColorSpan(K.dim), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                out.append("\n\n")
            }
            "list" -> {
                val ordered = b.bool("ordered")
                var n = b["start"].int() ?: 1
                for (item in b.objs("items")) {
                    out.append(indent).append(if (ordered) "${n++}. " else "• ")
                    val inner = SpannableStringBuilder()
                    item.objs("blocks").forEach { block(inner, it, "") }
                    out.append(inner.trimEnd('\n')).append("\n")
                }
                out.append("\n")
            }
            "quote" -> {
                val start = out.length
                b.objs("blocks").forEach { block(out, it, "│ ") }
                out.setSpan(ForegroundColorSpan(K.dim), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            "table" -> {
                val start = out.length
                val cells = { row: List<List<JsonObject>> -> row.joinToString("  │  ") { cell -> cell.joinToString("") { it.str("text").orEmpty() } } }
                out.append(cells(b.listOfLists("header"))).append("\n")
                b.listOfRows().forEach { out.append(cells(it)).append("\n") }
                out.setSpan(TypefaceSpan("monospace"), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                out.append("\n")
            }
            "rule" -> out.append("—\n\n")
            else -> Unit
        }
    }

    private fun spans(out: SpannableStringBuilder, spans: List<JsonObject>) {
        for (s in spans) {
            val start = out.length
            out.append(s.str("text").orEmpty())
            val end = out.length
            if (start == end) continue
            if (s.bool("strong")) out.setSpan(StyleSpan(Typeface.BOLD), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("em")) out.setSpan(StyleSpan(Typeface.ITALIC), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("strike")) out.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (s.bool("code")) out.setSpan(TypefaceSpan("monospace"), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            // Links show as text: nothing on the phone opens them.
            if (s.str("link") != null) out.setSpan(ForegroundColorSpan(K.accent), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    private inline fun styled(out: SpannableStringBuilder, style: Int, size: Float, body: () -> Unit) {
        val start = out.length
        body()
        out.setSpan(StyleSpan(style), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        out.setSpan(RelativeSizeSpan(size), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun JsonObject.listOfLists(key: String): List<List<JsonObject>> =
        (this[key] as? kotlinx.serialization.json.JsonArray)?.map { cell -> (cell as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty() }.orEmpty()

    private fun JsonObject.listOfRows(): List<List<List<JsonObject>>> =
        (this["rows"] as? kotlinx.serialization.json.JsonArray)?.map { row ->
            (row as? kotlinx.serialization.json.JsonArray)?.map { cell -> (cell as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty() }.orEmpty()
        }.orEmpty()
}

private fun SpannableStringBuilder.trimEnd(c: Char): CharSequence {
    var end = length
    while (end > 0 && this[end - 1] == c) end--
    return subSequence(0, end)
}
