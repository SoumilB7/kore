package dev.kore.phone.ui

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Markdown as the link's render tree (`Block`/`Span`, what the Mac sends as `doc`), for answers
 * that come as text: a box renders nothing and sends the raw markdown. The blocks are the Mac's
 * `MarkdownParser` line for line (CommonMark blocks, GFM tables and task lists); inline syntax
 * (emphasis, code spans, strikethrough, links, escapes) is CommonMark's delimiter runs. A table
 * also carries its columns' alignment (`align`: "left", "center", "right" or null), which only
 * the phone reads. Pure: no Android, tested on the JVM.
 */
object Markdown {
    /**
     * [text]'s blocks. [streaming]: the text is still arriving, so its end is read as unfinished:
     * a pipe line that may become a table's header (and its half-typed delimiter row) waits, and
     * `**`, `*`, `~~` or a backtick still open at the end styles up to the end instead of showing.
     */
    fun parse(text: String, streaming: Boolean = false): List<JsonObject> = top(text, 0, streaming).map { it.second }

    /** Top-level blocks with where each starts in [text] (offsets from [base]). */
    internal fun top(text: String, base: Int, streaming: Boolean): List<Pair<Int, JsonObject>> {
        val lines = ArrayList<Line>()
        var offset = base
        var start = 0
        while (true) {
            val nl = text.indexOf('\n', start)
            val end = if (nl < 0) text.length else nl
            var line = text.substring(start, end)
            if (line.endsWith('\r')) line = line.dropLast(1)
            lines += Line(line, offset)
            if (nl < 0) break
            offset += end - start + 1
            start = nl + 1
        }
        if (streaming) waitForTable(lines)
        lines.indexOfLast { !isBlank(it.text) }.takeIf { it >= 0 }?.let { lines[it] = lines[it].copy(last = streaming) }
        return blocks(lines)
    }

    /**
     * While an answer streams, its last line(s) may be a table's header whose delimiter row hasn't
     * come yet: shown, they'd flash as a raw pipe line and then turn into a table. They wait.
     */
    private fun waitForTable(lines: MutableList<Line>) {
        while (lines.isNotEmpty() && lines.last().text.isEmpty()) lines.removeAt(lines.lastIndex)
        fun pipe(i: Int) = i >= 0 && lines[i].text.trimStart().startsWith("|")
        fun partialDelimiter(s: String) = s.isNotBlank() && s.all { it == '|' || it == '-' || it == ':' || it == ' ' || it == '\t' }
        val n = lines.size
        if (pipe(n - 1) && !pipe(n - 2)) lines.removeAt(n - 1)
        else if (n >= 2 && pipe(n - 2) && partialDelimiter(lines[n - 1].text) && !pipe(n - 3) &&
            !isTableStart(lines, n - 2)
        ) repeat(2) { lines.removeAt(lines.lastIndex) }
    }

    // MARK: - Blocks

    internal data class Line(val text: String, val offset: Int, val last: Boolean = false)

    private fun blocks(lines: List<Line>): List<Pair<Int, JsonObject>> {
        val out = ArrayList<Pair<Int, JsonObject>>()
        var i = 0
        val end = lines.size
        while (i < end) {
            val s = lines[i].text
            val id = lines[i].offset
            if (isBlank(s)) { i++; continue }
            val open = fence(s)
            if (open != null) {
                val indent = indentation(s)
                val body = ArrayList<String>()
                var closed = false
                i++
                while (i < end) {
                    val t = lines[i].text
                    i++
                    if (closes(t, open)) { closed = true; break }
                    body += dedent(t, indent)
                }
                out += id to buildJsonObject {
                    put("k", "code"); put("lang", open.info); put("text", body.joinToString("\n")); put("open", !closed)
                }
                continue
            }
            val h = heading(s)
            if (h != null) {
                out += id to buildJsonObject { put("k", "heading"); put("level", h.first); put("spans", inline(h.second, lines[i].last)) }
                i++
                continue
            }
            if (isRule(s)) {
                out += id to buildJsonObject { put("k", "rule") }
                i++
                continue
            }
            if (isQuote(s)) {
                val inner = ArrayList<Line>()
                while (i < end) {
                    val t = lines[i].text
                    if (isQuote(t)) inner += lines[i].copy(text = unquote(t))
                    else if (!isBlank(t) && inner.isNotEmpty() && !isBlank(inner.last().text) && !startsBlock(lines, i)) inner += lines[i]
                    else break
                    i++
                }
                out += id to buildJsonObject { put("k", "quote"); put("blocks", JsonArray(blocks(numbered(inner)).map { it.second })) }
                continue
            }
            if (isTableStart(lines, i)) {
                val header = cells(s)
                val align = cells(lines[i + 1].text).map { c ->
                    val l = c.startsWith(":"); val r = c.endsWith(":")
                    if (l && r) "center" else if (r) "right" else if (l) "left" else null
                }
                val rows = ArrayList<List<JsonArray>>()
                i += 2
                while (i < end && !isBlank(lines[i].text) && lines[i].text.contains('|')) {
                    rows += cells(lines[i].text).map { inline(it, lines[i].last) }
                    i++
                }
                out += id to buildJsonObject {
                    put("k", "table")
                    put("header", JsonArray(header.map { inline(it, false) }))
                    put("rows", JsonArray(rows.map { JsonArray(it) }))
                    put("align", JsonArray(align.map { if (it == null) JsonNull else JsonPrimitive(it) }))
                }
                continue
            }
            val marker = listMarker(s)
            if (marker != null) {
                val (list, next) = list(lines, i, marker)
                out += id to list
                i = next
                continue
            }
            val paragraph = StringBuilder()
            var hardBreak = false
            var last = false
            while (i < end) {
                val t = lines[i].text
                if (isBlank(t) || (paragraph.isNotEmpty() && startsBlock(lines, i))) break
                if (paragraph.isNotEmpty()) paragraph.append(if (hardBreak) "\n" else " ")
                hardBreak = t.endsWith("  ") || t.endsWith("\\")
                paragraph.append(trimLeading(t).trimEnd(' ', '\t', '\\'))
                last = last || lines[i].last
                i++
            }
            out += id to buildJsonObject { put("k", "paragraph"); put("spans", inline(paragraph.toString(), last)) }
        }
        return out
    }

    private fun list(lines: List<Line>, from: Int, first: Marker): Pair<JsonObject, Int> {
        val items = ArrayList<JsonObject>()
        var i = from
        val end = lines.size
        var marker = first
        while (true) {
            val body = arrayListOf(lines[i].copy(text = marker.content))
            i++
            while (i < end) {
                val t = lines[i].text
                if (isBlank(t)) {
                    // Blank lines stay in the item only if what follows is indented into it.
                    var j = i + 1
                    while (j < end && isBlank(lines[j].text)) j++
                    if (j >= end || indentation(lines[j].text) < marker.contentIndent) break
                    while (i < j) { body += lines[i].copy(text = ""); i++ }
                    continue
                }
                if (indentation(t) >= marker.contentIndent) body += lines[i].copy(text = dedent(t, marker.contentIndent))
                else if (listMarker(t) != null || startsBlock(lines, i)) break
                else if (body.isNotEmpty() && !isBlank(body.last().text)) body += lines[i].copy(text = trimLeading(t))
                else break
                i++
            }
            var task: Boolean? = null
            for ((prefix, checked) in listOf("[ ]" to false, "[x]" to true, "[X]" to true)) {
                val head = body[0].text
                if (!head.startsWith(prefix)) continue
                val rest = head.substring(3)
                if (rest.isNotEmpty() && rest[0] != ' ') continue
                task = checked
                body[0] = body[0].copy(text = trimLeading(rest))
            }
            val blocks = blocks(numbered(body)).map { it.second }
            items += buildJsonObject {
                if (task != null) put("task", task)
                put("blocks", JsonArray(blocks))
            }
            var j = i
            while (j < end && isBlank(lines[j].text)) j++
            val next = if (j < end && !isRule(lines[j].text)) listMarker(lines[j].text) else null
            if (next == null || next.ordered != first.ordered) break
            i = j
            marker = next
        }
        return buildJsonObject {
            put("k", "list"); put("ordered", first.ordered); put("start", first.number); put("items", JsonArray(items))
        } to i
    }

    private fun numbered(lines: List<Line>) = lines.mapIndexed { n, l -> l.copy(offset = n) }

    // MARK: - Line tests

    private class Fence(val marker: Char, val count: Int, val info: String)

    internal class Marker(val ordered: Boolean, val number: Int, val contentIndent: Int, val content: String)

    private fun isBlank(s: String) = s.all { it == ' ' || it == '\t' }

    /** Leading columns of whitespace (a tab reaches the next multiple of 4). */
    private fun indentation(s: String): Int {
        var columns = 0
        for (c in s) {
            if (c == ' ') columns++ else if (c == '\t') columns += 4 - columns % 4 else break
        }
        return columns
    }

    private fun dedent(s: String, columns: Int): String {
        var removed = 0
        var i = 0
        while (i < s.length && removed < columns) {
            when (s[i]) {
                ' ' -> removed++
                '\t' -> removed += 4 - removed % 4
                else -> return s.substring(i)
            }
            i++
        }
        return s.substring(i)
    }

    private fun trimLeading(s: String) = s.trimStart(' ', '\t')

    private fun fence(s: String): Fence? {
        if (indentation(s) > 3) return null
        val t = trimLeading(s)
        val c = t.firstOrNull() ?: return null
        if (c != '`' && c != '~') return null
        val count = t.takeWhile { it == c }.length
        if (count < 3) return null
        val rest = t.substring(count)
        if (c == '`' && rest.contains('`')) return null
        return Fence(c, count, trimLeading(rest).takeWhile { it != ' ' })
    }

    private fun closes(s: String, open: Fence): Boolean {
        if (indentation(s) > 3) return false
        val t = trimLeading(s)
        val count = t.takeWhile { it == open.marker }.length
        return count >= open.count && isBlank(t.substring(count))
    }

    private fun heading(s: String): Pair<Int, String>? {
        if (indentation(s) > 3) return null
        val t = trimLeading(s)
        val level = t.takeWhile { it == '#' }.length
        if (level !in 1..6) return null
        val rest = t.substring(level)
        if (rest.isNotEmpty() && rest[0] != ' ' && rest[0] != '\t') return null
        var text = trimLeading(rest).trimEnd(' ', '\t')
        // A closing run of #s, set off by a space, isn't part of the title.
        val closing = text.reversed().takeWhile { it == '#' }.length
        if (closing > 0) {
            val before = text.dropLast(closing)
            if (before.isEmpty() || before.last() == ' ') text = before
        }
        return level to text.trimEnd(' ')
    }

    private fun isRule(s: String): Boolean {
        if (indentation(s) > 3) return false
        var marker: Char? = null
        var count = 0
        for (c in s) {
            if (c == ' ' || c == '\t') continue
            if ((c != '-' && c != '*' && c != '_') || (marker != null && marker != c)) return false
            marker = c
            count++
        }
        return count >= 3
    }

    private fun isQuote(s: String) = indentation(s) <= 3 && trimLeading(s).firstOrNull() == '>'

    private fun unquote(s: String): String {
        val t = trimLeading(s).drop(1)
        return if (t.startsWith(" ")) t.drop(1) else t
    }

    internal fun listMarker(s: String): Marker? {
        val indent = indentation(s)
        if (indent > 3) return null
        val t = trimLeading(s)
        var ordered = false
        var number = 1
        val width: Int
        val c = t.firstOrNull() ?: return null
        if (c == '-' || c == '*' || c == '+') width = 1
        else {
            val digits = t.takeWhile { it in '0'..'9' }
            val delimiter = t.getOrNull(digits.length)
            if (digits.length !in 1..9 || (delimiter != '.' && delimiter != ')')) return null
            ordered = true
            number = digits.toIntOrNull() ?: 1
            width = digits.length + 1
        }
        val rest = t.substring(width)
        if (isBlank(rest)) return Marker(ordered, number, indent + width + 1, "")
        if (rest[0] != ' ' && rest[0] != '\t') return null
        val spaces = indentation(rest)
        val pad = if (spaces > 4) 1 else spaces
        return Marker(ordered, number, indent + width + pad, dedent(rest, pad))
    }

    /**
     * A line that ends a paragraph: any other block's first line. An empty item never does. An
     * ordered list from 1 does (CommonMark); from any other number, as writers number a list on
     * from an earlier one ("**B. The checker**" then "5."), only where it plainly is one: under a
     * lead (a line all in bold, or ending in a colon), or when the next line goes on counting
     * ("5." then "6."). A year or version that wraps to a line's start stays text. The Mac's
     * transcript reads it the same (`MarkdownParser.startsBlock`).
     */
    private fun startsBlock(lines: List<Line>, i: Int): Boolean {
        val s = lines[i].text
        if (fence(s) != null || heading(s) != null || isRule(s) || isQuote(s) || isTableStart(lines, i)) return true
        val marker = listMarker(s) ?: return false
        if (marker.content.isEmpty()) return false
        if (!marker.ordered || marker.number == 1) return true
        return leadsList(lines, i) || countsOn(lines, i, marker)
    }

    /** The line above [i] reads as a list's lead: wholly bold ("**B. The checker**"), or ending in a colon. */
    private fun leadsList(lines: List<Line>, i: Int): Boolean {
        if (i - 1 < 0) return false
        val above = lines[i - 1].text.trim(' ', '\t')
        if (above.endsWith(":")) return true
        for (mark in listOf("**", "__")) {
            if (above.length > mark.length * 2 && above.startsWith(mark) && above.endsWith(mark) &&
                !above.substring(mark.length, above.length - mark.length).contains(mark)
            ) return true
        }
        return false
    }

    /** The line after [i] is the next item of the same list: its number one more, its delimiter the same. */
    private fun countsOn(lines: List<Line>, i: Int, marker: Marker): Boolean {
        if (i + 1 >= lines.size) return false
        val next = listMarker(lines[i + 1].text) ?: return false
        if (!next.ordered || next.content.isEmpty() || next.number != marker.number + 1) return false
        return delimiter(lines[i].text) == delimiter(lines[i + 1].text)
    }

    private fun delimiter(s: String): Char? = trimLeading(s).dropWhile { it in '0'..'9' }.firstOrNull()

    private fun isTableStart(lines: List<Line>, i: Int): Boolean {
        if (i + 1 >= lines.size || !lines[i].text.contains('|')) return false
        val delimiter = lines[i + 1].text
        if (!delimiter.contains('-')) return false
        val columns = cells(delimiter)
        if (columns.isEmpty() || columns.size != cells(lines[i].text).size) return false
        return columns.all { cell -> cell.isNotEmpty() && cell.contains('-') && cell.all { it == '-' || it == ':' } }
    }

    /** A table row's cells: outer pipes dropped, split on unescaped pipes, trimmed. */
    internal fun cells(s: String): List<String> {
        var t = trimLeading(s).trimEnd(' ', '\t')
        if (t.startsWith("|")) t = t.substring(1)
        if (t.endsWith("|") && !t.endsWith("\\|")) t = t.dropLast(1)
        val result = ArrayList<String>()
        var start = 0
        var escaped = false
        for ((i, c) in t.withIndex()) {
            if (c == '|' && !escaped) {
                result += t.substring(start, i)
                start = i + 1
            }
            escaped = c == '\\' && !escaped
        }
        result += t.substring(start)
        return result.map { trimLeading(it).trimEnd(' ', '\t') }
    }

    // MARK: - Inline

    private const val STRONG = 1
    private const val EM = 2
    private const val STRIKE = 4
    private const val CODE = 8

    /** A run of text with one style, or a run of `*`, `_` or `~` that may open or close one. */
    private class Piece(
        var text: String,
        var style: Int = 0,
        var link: String? = null,
        val delim: Char = ' ',
        var count: Int = 0,
        val canOpen: Boolean = false,
        val canClose: Boolean = false,
    ) {
        val original = count
        var active = delim != ' '
    }

    /** Inline markdown as the wire's spans. [openEnd]: emphasis or code still open at the end runs to it. */
    internal fun inline(text: String, openEnd: Boolean): JsonArray {
        val pieces = ArrayList<Piece>()
        scan(text, pieces, openEnd)
        emphasis(pieces, openEnd)
        // Adjacent runs with the same look are one span.
        val spans = ArrayList<JsonObject>()
        var buf = StringBuilder()
        var style = -1
        var link: String? = null
        fun flush() {
            if (buf.isEmpty()) return
            val s = style; val l = link; val t = buf.toString()
            spans += buildJsonObject {
                put("text", t)
                if (s and CODE != 0) put("code", true)
                if (s and EM != 0) put("em", true)
                if (s and STRONG != 0) put("strong", true)
                if (s and STRIKE != 0) put("strike", true)
                if (l != null) put("link", l)
            }
            buf = StringBuilder()
        }
        for (p in pieces) {
            val t = if (p.delim != ' ') p.delim.toString().repeat(p.count) else p.text
            if (t.isEmpty()) continue
            if (p.style != style || p.link != link) { flush(); style = p.style; link = p.link }
            buf.append(t)
        }
        flush()
        return JsonArray(spans)
    }

    private const val PUNCT = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

    private fun isPunct(c: Char?) = c != null && (c in PUNCT || Character.getType(c).let {
        it == Character.CONNECTOR_PUNCTUATION.toInt() || it == Character.DASH_PUNCTUATION.toInt() ||
            it == Character.START_PUNCTUATION.toInt() || it == Character.END_PUNCTUATION.toInt() ||
            it == Character.INITIAL_QUOTE_PUNCTUATION.toInt() || it == Character.FINAL_QUOTE_PUNCTUATION.toInt() ||
            it == Character.OTHER_PUNCTUATION.toInt() || it == Character.MATH_SYMBOL.toInt() || it == Character.CURRENCY_SYMBOL.toInt()
    })

    private fun isSpace(c: Char?) = c == null || c.isWhitespace()

    /** Text into pieces: code spans, links, escapes and entities resolved; delimiter runs left for [emphasis]. */
    private fun scan(text: String, out: MutableList<Piece>, openEnd: Boolean, link: String? = null) {
        val plain = StringBuilder()
        fun flush() { if (plain.isNotEmpty()) { out += Piece(plain.toString(), link = link); plain.setLength(0) } }
        var i = 0
        val n = text.length
        while (i < n) {
            val c = text[i]
            when {
                c == '\\' && i + 1 < n && text[i + 1] in PUNCT -> { plain.append(text[i + 1]); i += 2 }
                c == '`' -> {
                    val ticks = run(text, i, '`')
                    val close = closingTicks(text, i + ticks, ticks)
                    if (close >= 0 || openEnd && close < 0 && text.indexOf('`', i + ticks) < 0) {
                        flush()
                        var body = text.substring(i + ticks, if (close >= 0) close else n).replace('\n', ' ')
                        if (body.length >= 2 && body.startsWith(" ") && body.endsWith(" ") && body.isNotBlank()) body = body.substring(1, body.length - 1)
                        out += Piece(body, CODE, link)
                        i = if (close >= 0) close + ticks else n
                    } else { plain.append(text, i, i + ticks); i += ticks }
                }
                c == '*' || c == '_' || c == '~' -> {
                    val len = run(text, i, c)
                    val before = text.getOrNull(i - 1)
                    val after = text.getOrNull(i + len)
                    val left = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
                    val right = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
                    val open = if (c == '_') left && (!right || isPunct(before)) else left
                    val close = if (c == '_') right && (!left || isPunct(after)) else right
                    flush()
                    // Streaming, a run at the very end is a marker still arriving: it waits.
                    if (openEnd && i + len == n) Unit
                    else if (c == '~' && len != 2) plain.append(text, i, i + len)
                    else out += Piece("", link = link, delim = c, count = len, canOpen = open, canClose = close)
                    i += len
                }
                c == '!' && text.getOrNull(i + 1) == '[' -> {
                    val l = linkAt(text, i + 1)
                    if (l != null) {
                        // An image shows as its words.
                        flush(); scan(text.substring(i + 2, l.textEnd), out, false, link); i = l.end
                    } else { plain.append(c); i++ }
                }
                c == '[' && link == null -> {
                    val l = linkAt(text, i)
                    if (l != null) {
                        flush(); scan(text.substring(i + 1, l.textEnd), out, false, l.url); i = l.end
                    } else { plain.append(c); i++ }
                }
                c == '<' && link == null -> {
                    val close = text.indexOf('>', i + 1)
                    val inside = if (close > 0) text.substring(i + 1, close) else ""
                    if (close > 0 && inside.none { it.isWhitespace() || it == '<' } &&
                        (scheme(inside, 0) > 0 || inside.startsWith("mailto:", true))
                    ) { flush(); out += Piece(inside, link = inside); i = close + 1 } else { plain.append(c); i++ }
                }
                c == '&' -> {
                    val semi = text.indexOf(';', i)
                    val entity = if (semi in i + 2..i + 9) entity(text.substring(i + 1, semi)) else null
                    if (entity != null) { plain.append(entity); i = semi + 1 } else { plain.append(c); i++ }
                }
                (c == 'h' || c == 'H') && link == null && scheme(text, i) > 0 &&
                    (i == 0 || !text[i - 1].isLetterOrDigit()) -> {
                    val from = i + scheme(text, i)
                    var end = from
                    while (end < n && !text[end].isWhitespace() && text[end] != '<') end++
                    end = trimmedUrl(text, i, end)
                    if (end > from) {
                        flush(); val url = text.substring(i, end); out += Piece(url, link = url); i = end
                    } else { plain.append(c); i++ }
                }
                else -> { plain.append(c); i++ }
            }
        }
        flush()
    }

    private fun run(text: String, i: Int, c: Char): Int { var j = i; while (j < text.length && text[j] == c) j++; return j - i }

    /** Where a code span of [ticks] backticks from [from] closes: a run of exactly that many. */
    private fun closingTicks(text: String, from: Int, ticks: Int): Int {
        var j = from
        while (true) {
            val at = text.indexOf('`', j)
            if (at < 0) return -1
            val len = run(text, at, '`')
            if (len == ticks) return at
            j = at + len
        }
    }

    private class Link(val textEnd: Int, val url: String, val end: Int)

    /** `[text](url "title")` at [open] (its `[`), brackets and parentheses nested. */
    private fun linkAt(text: String, open: Int): Link? {
        var depth = 0
        var i = open
        var close = -1
        while (i < text.length) {
            val c = text[i]
            if (c == '\\') { i += 2; continue }
            if (c == '`') { val t = run(text, i, '`'); val e = closingTicks(text, i + t, t); i = if (e >= 0) e + t else i + t; continue }
            if (c == '[') depth++
            if (c == ']' && --depth == 0) { close = i; break }
            i++
        }
        if (close < 0 || text.getOrNull(close + 1) != '(') return null
        var j = close + 2
        var parens = 0
        val url = StringBuilder()
        while (j < text.length && text[j] == ' ') j++
        if (text.getOrNull(j) == '<') {
            val e = text.indexOf('>', j)
            if (e < 0) return null
            url.append(text, j + 1, e)
            j = e + 1
        } else {
            while (j < text.length) {
                val c = text[j]
                if (c == '\\' && j + 1 < text.length && text[j + 1] in PUNCT) { url.append(text[j + 1]); j += 2; continue }
                if (c.isWhitespace()) break
                if (c == '(') parens++
                if (c == ')') { if (parens == 0) break; parens-- }
                url.append(c)
                j++
            }
        }
        while (j < text.length && text[j] == ' ') j++
        // An optional title, dropped.
        val q = text.getOrNull(j)
        if (q == '"' || q == '\'') {
            val e = text.indexOf(q, j + 1)
            if (e < 0) return null
            j = e + 1
            while (j < text.length && text[j] == ' ') j++
        }
        if (text.getOrNull(j) != ')') return null
        return Link(close, url.toString(), j + 1)
    }

    /** The length of `http://` or `https://` at [i], if one starts there. */
    private fun scheme(text: String, i: Int): Int {
        for (p in listOf("https://", "http://")) if (text.regionMatches(i, p, 0, p.length, ignoreCase = true)) return p.length
        return 0
    }

    /** Where a bare URL from [start] really ends (GitHub's rules): trailing punctuation off, an unmatched `)` off. */
    private fun trimmedUrl(text: String, start: Int, end0: Int): Int {
        var end = end0
        while (end > start) {
            val last = text[end - 1]
            if (last in "?!.,:*_~'\";") end--
            else if (last == ')') {
                val s = text.substring(start, end)
                if (s.count { it == ')' } > s.count { it == '(' }) end-- else break
            } else break
        }
        return end
    }

    private fun entity(name: String): String? = when (name) {
        "amp" -> "&"; "lt" -> "<"; "gt" -> ">"; "quot" -> "\""; "apos" -> "'"; "nbsp" -> " "
        else -> when {
            name.startsWith("#x") || name.startsWith("#X") -> name.substring(2).toIntOrNull(16)
            name.startsWith("#") -> name.substring(1).toIntOrNull()
            else -> null
        }?.takeIf { it in 1..0x10FFFF }?.let { String(Character.toChars(it)) }
    }

    /** CommonMark's process emphasis: closers matched to the nearest opener of their kind, inner pieces styled. */
    private fun emphasis(pieces: MutableList<Piece>, openEnd: Boolean) {
        var c = 0
        while (c < pieces.size) {
            val closer = pieces[c]
            if (!closer.active || !closer.canClose || closer.count == 0) { c++; continue }
            var o = c - 1
            var found = -1
            while (o >= 0) {
                val opener = pieces[o]
                if (opener.active && opener.canOpen && opener.delim == closer.delim && opener.count > 0) {
                    val tilde = closer.delim == '~'
                    val odd = !tilde && (opener.canClose || closer.canOpen) &&
                        (opener.original + closer.original) % 3 == 0 && !(opener.original % 3 == 0 && closer.original % 3 == 0)
                    if (!odd && (!tilde || opener.count == closer.count)) { found = o; break }
                }
                o--
            }
            if (found < 0) { c++; continue }
            val opener = pieces[found]
            val use = if (closer.delim == '~') closer.count else if (opener.count >= 2 && closer.count >= 2) 2 else 1
            val style = if (closer.delim == '~') STRIKE else if (use == 2) STRONG else EM
            for (k in found + 1 until c) {
                pieces[k].style = pieces[k].style or style
                if (pieces[k].delim != ' ') pieces[k].active = false
            }
            opener.count -= use
            closer.count -= use
            if (closer.count == 0) c++
        }
        if (!openEnd) return
        // Streaming: what's still open styles to the end, its marker hidden until its closer comes.
        for ((k, p) in pieces.withIndex()) {
            if (!p.active || !p.canOpen || p.count == 0) continue
            val style = when { p.delim == '~' -> STRIKE; p.count >= 2 -> STRONG; else -> EM }
            for (j in k + 1 until pieces.size) pieces[j].style = pieces[j].style or style
            p.count = 0
        }
    }

    /**
     * Parsed answers by entry: while one streams, only its last block is parsed again (the ones
     * before are final, as on the Mac). The same list comes back while the text is unchanged.
     */
    class Cache(private val limit: Int = 200) {
        private class Entry(val text: String, val streaming: Boolean, val blocks: List<Pair<Int, JsonObject>>, val list: List<JsonObject>)

        private val entries = object : LinkedHashMap<String, Entry>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?) = size > limit
        }

        /** How many characters the last [blocks] call parsed (tests: streaming parses only the end). */
        var parsed = 0
            private set

        fun blocks(key: String, text: String, streaming: Boolean): List<JsonObject> {
            val old = entries[key]
            if (old != null && old.text == text && old.streaming == streaming) { parsed = 0; return old.list }
            val blocks = if (old != null && text.startsWith(old.text) && old.blocks.isNotEmpty()) {
                val from = old.blocks.last().first
                parsed = text.length - from
                old.blocks.dropLast(1) + top(text.substring(from), from, streaming)
            } else {
                parsed = text.length
                top(text, 0, streaming)
            }
            val list = blocks.map { it.second }
            entries[key] = Entry(text, streaming, blocks, list)
            return list
        }
    }

    /** The app's one cache of answers sent as text. */
    val cache = Cache()
}
