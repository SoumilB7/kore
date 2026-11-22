package dev.kore.phone

import dev.kore.phone.ui.Markdown
import dev.kore.phone.ui.bool
import dev.kore.phone.ui.int
import dev.kore.phone.ui.objs
import dev.kore.phone.ui.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** A box's answers come as markdown text: the phone parses them into the Mac's render tree. */
class MarkdownTest {
    /** The owner's 0.3.9 screenshot: a box's Claude answer the phone showed raw. */
    private val answer = """
        Here's what fits your workload (several AI chats plus Next.js builds, running 24/7), compared with your current box (2 slow cores, 3.4 GB):

        | Pick | Example | CPU vs now | RAM | Idle power | Price (India, approx.) |
        |---|---|---|---|---|---|
        | **Best value** | **ASUS NUC 14 Essential (Intel N150)** | ~3–4× faster (4 cores) | 16 GB DDR5 | ~6 W | **~₹18–20k** |
        | **Big jump** | Ryzen 7 **5825U / 7735HS** mini PC (e.g. GMKtec Nucbox M5 Plus) | ~8–10× (8 cores / 16 threads) | 16–32 GB | ~8–10 W | ~₹35–55k |
        | **Top pick for builds** | Ryzen 7 **8745HS / 8845HS** (Beelink SER8, Minisforum UM880) | ~12× | 32 GB | 7–10 W | ~₹55–75k |

        **My recommendation:**
        - **If it's mostly chats with an occasional build:** the **N150 NUC with 16 GB**. It's cheap, nearly silent, uses almost no power, and holds about 4× the chats. Builds take minutes instead of crashing. The catch: it has **one RAM slot, 16 GB maximum**.
        - **If you build often or run several builds at once:** the **8745HS with 32 GB**.
    """.trimIndent()

    private fun kinds(blocks: List<JsonObject>) = blocks.map { it.str("k") }
    private fun spans(e: Any?) = (e as JsonArray).map { it as JsonObject }
    private fun plain(spans: List<JsonObject>) = spans.joinToString("") { it.str("text").orEmpty() }
    private fun strong(spans: List<JsonObject>) = spans.filter { it.bool("strong") }.map { it.str("text") }
    private fun header(t: JsonObject) = (t["header"] as JsonArray).map { plain(spans(it)) }
    private fun rows(t: JsonObject) = (t["rows"] as JsonArray).map { r -> (r as JsonArray).map { spans(it) } }
    private fun table(md: String) = Markdown.parse(md).single { it.str("k") == "table" }

    /** Every span's text in the tree, nested blocks and cells too. */
    private fun texts(e: Any?): List<String> = when (e) {
        is JsonObject -> listOfNotNull(e.str("text").takeIf { e.containsKey("spans").not() && e.str("k") == null }) + e.values.flatMap(::texts)
        is JsonArray -> e.flatMap(::texts)
        else -> emptyList()
    }

    @Test fun theScreenshotsAnswerRendersAsATableAndBold() {
        val blocks = Markdown.parse(answer)
        assertEquals(listOf("paragraph", "table", "paragraph", "list"), kinds(blocks))
        val t = blocks[1]
        assertEquals(listOf("Pick", "Example", "CPU vs now", "RAM", "Idle power", "Price (India, approx.)"), header(t))
        val r = rows(t)
        assertEquals(3, r.size)
        assertTrue(r.all { it.size == 6 })
        // Bold in cells: a whole cell, and a run inside one.
        assertEquals(listOf("Best value"), strong(r[0][0]))
        assertEquals(listOf("ASUS NUC 14 Essential (Intel N150)"), strong(r[0][1]))
        assertEquals(listOf("~₹18–20k"), strong(r[0][5]))
        assertEquals("~3–4× faster (4 cores)", plain(r[0][2]))
        assertEquals(listOf("5825U / 7735HS"), strong(r[1][1]))
        assertEquals("Ryzen 7 5825U / 7735HS mini PC (e.g. GMKtec Nucbox M5 Plus)", plain(r[1][1]))
        assertEquals(listOf("My recommendation:"), strong(blocks[2].objs("spans")))
        // Bold in list items.
        val items = blocks[3].objs("items")
        assertEquals(2, items.size)
        val first = items[0].objs("blocks").single().objs("spans")
        assertEquals(listOf("If it's mostly chats with an occasional build:", "N150 NUC with 16 GB", "one RAM slot, 16 GB maximum"), strong(first))
        assertEquals(listOf("If you build often or run several builds at once:", "8745HS with 32 GB"), strong(items[1].objs("blocks").single().objs("spans")))
        // Nothing raw is left anywhere.
        val all = texts(JsonArray(blocks))
        assertTrue(all.isNotEmpty())
        assertTrue(all.joinToString("\n"), all.none { "**" in it || "|" in it })
    }

    @Test fun aTableRightAfterAParagraphLine() {
        val blocks = Markdown.parse("Options:\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter.")
        assertEquals(listOf("paragraph", "table", "paragraph"), kinds(blocks))
        assertEquals("Options:", plain(blocks[0].objs("spans")))
        assertEquals(listOf("a", "b"), header(blocks[1]))
        assertEquals(1, rows(blocks[1]).size)
    }

    @Test fun aTableWithoutOuterPipes() {
        val t = table("a | b\n--- | ---\n1 | **2**")
        assertEquals(listOf("a", "b"), header(t))
        assertEquals(listOf("2"), strong(rows(t)[0][1]))
    }

    @Test fun anIndentedTableWithALeadingSpace() {
        val t = table(" | a | b |\n | --- | --- |\n | 1 | 2 |")
        assertEquals(listOf("a", "b"), header(t))
        assertEquals("1", plain(rows(t)[0][0]))
    }

    @Test fun escapedPipesStayInTheirCell() {
        val t = table("| a | b |\n|---|---|\n| x \\| y | 2 |")
        assertEquals(listOf("x | y", "2"), rows(t)[0].map(::plain))
    }

    @Test fun alignmentColons() {
        val t = table("| l | c | r | n |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |")
        assertEquals(JsonArray(listOf(JsonPrimitive("left"), JsonPrimitive("center"), JsonPrimitive("right"), JsonNull)), t["align"])
    }

    @Test fun aOneColumnTable() {
        val t = table("| only |\n|---|\n| 1 |\n| 2 |")
        assertEquals(listOf("only"), header(t))
        assertEquals(listOf("1", "2"), rows(t).map { plain(it.single()) })
    }

    @Test fun crlfLineEnds() {
        val blocks = Markdown.parse("Intro\r\n\r\n| a | b |\r\n|---|---|\r\n| **1** | 2 |\r\n\r\n- **item**\r\n")
        assertEquals(listOf("paragraph", "table", "list"), kinds(blocks))
        assertEquals(listOf("b"), header(blocks[1]).drop(1))
        assertEquals(listOf("1"), strong(rows(blocks[1])[0][0]))
        assertTrue(texts(JsonArray(blocks)).none { '\r' in it })
    }

    @Test fun aDelimiterRowThatDoesntMatchIsText() {
        assertEquals(listOf("paragraph"), kinds(Markdown.parse("| a | b |\n|---|\n| 1 | 2 |")))
    }

    @Test fun inlineStyles() {
        val s = Markdown.parse("**b** *i* _i2_ `c|*d*` ~~s~~ ***bi*** [site](https://kore.dev/a_(b)) <https://x.io> see https://y.io/p.").single().objs("spans")
        fun with(text: String) = s.single { it.str("text") == text }
        assertTrue(with("b").bool("strong"))
        assertTrue(with("i").bool("em"))
        assertTrue(with("i2").bool("em"))
        assertTrue(with("c|*d*").bool("code"))
        assertTrue(with("s").bool("strike"))
        assertTrue(with("bi").bool("strong") && with("bi").bool("em"))
        assertEquals("https://kore.dev/a_(b)", with("site").str("link"))
        assertEquals("https://x.io", with("https://x.io").str("link"))
        assertEquals("https://y.io/p", with("https://y.io/p").str("link"))
        assertEquals("b i i2 c|*d* s bi site https://x.io see https://y.io/p.", plain(s))
    }

    @Test fun literalAsterisksUnderscoresAndTildesStay() {
        val s = Markdown.parse("2 * 3 * 4, snake_case_name, ~5 W and ~6 W, \\*not\\*, a &amp; b").single().objs("spans")
        assertEquals("2 * 3 * 4, snake_case_name, ~5 W and ~6 W, *not*, a & b", plain(s))
        assertTrue(s.none { it.bool("em") || it.bool("strong") || it.bool("strike") })
    }

    @Test fun boldInsideALinkAndALinkInsideBold() {
        val s = Markdown.parse("**see [the **docs**](https://d.io)** now").single().objs("spans")
        assertEquals("see the docs now", plain(s))
        assertTrue(s.filter { it.str("link") == "https://d.io" }.all { it.bool("strong") })
    }

    @Test fun headingsQuotesCodeRulesAndNestedLists() {
        val md = """
            # Title with **bold**
            ### Small

            > a **quoted** line
            lazily continued

            ```kotlin
            val a = "**not bold**"
            ```

            ---

            3. third
            4. fourth
               - nested *em*
               - [x] done
        """.trimIndent()
        val b = Markdown.parse(md)
        assertEquals(listOf("heading", "heading", "quote", "code", "rule", "list"), kinds(b))
        assertEquals(1, b[0]["level"].int())
        assertEquals(listOf("bold"), strong(b[0].objs("spans")))
        assertEquals(3, b[1]["level"].int())
        val quoted = b[2].objs("blocks").single().objs("spans")
        assertEquals("a quoted line lazily continued", plain(quoted))
        assertEquals("kotlin", b[3].str("lang"))
        assertEquals("val a = \"**not bold**\"", b[3].str("text"))
        assertFalse(b[3].bool("open"))
        val list = b[5]
        assertTrue(list.bool("ordered"))
        assertEquals(3, list["start"].int())
        val nested = list.objs("items")[1].objs("blocks")
        assertEquals(listOf("paragraph", "list"), kinds(nested))
        val inner = nested[1].objs("items")
        assertTrue(inner[0].objs("blocks").single().objs("spans").single { it.str("text") == "em" }.bool("em"))
        assertTrue(inner[1].bool("task"))
        assertEquals("done", plain(inner[1].objs("blocks").single().objs("spans")))
    }

    // MARK: Streaming

    @Test fun aHalfReceivedTableWaitsInsteadOfFlashingRaw() {
        val intro = "Here:\n\n"
        assertEquals(listOf("paragraph"), kinds(Markdown.parse(intro + "| Pick | Example |", streaming = true)))
        assertEquals(listOf("paragraph"), kinds(Markdown.parse(intro + "| Pick | Example |\n", streaming = true)))
        assertEquals(listOf("paragraph"), kinds(Markdown.parse(intro + "| Pick | Example |\n|--", streaming = true)))
        val header = Markdown.parse(intro + "| Pick | Example |\n|---|---|", streaming = true)
        assertEquals(listOf("paragraph", "table"), kinds(header))
        // A row coming in shows as far as it got, its open bold already bold.
        val row = Markdown.parse(intro + "| Pick | Example |\n|---|---|\n| **Best val", streaming = true)
        val cells = rows(row[1]).single()
        assertEquals(listOf("Best val"), strong(cells[0]))
        // Finished, a lone pipe line is what it is.
        assertEquals("| Pick | Example |", plain(Markdown.parse(intro + "| Pick | Example |")[1].objs("spans")))
    }

    @Test fun openBoldWhileStreamingIsBoldNotAsterisks() {
        val s = Markdown.parse("- **If it's mostly ch", streaming = true).single().objs("items").single().objs("blocks").single().objs("spans")
        assertEquals("If it's mostly ch", plain(s))
        assertTrue(s.single().bool("strong"))
        assertEquals("a b", plain(Markdown.parse("a b**", streaming = true).single().objs("spans")).trimEnd())
        // Finished and never closed: literal.
        assertEquals("**If", plain(Markdown.parse("**If").single().objs("spans")))
        // Earlier lines aren't read as unfinished.
        assertEquals("**x", plain(Markdown.parse("**x\n\nnext", streaming = true)[0].objs("spans")))
    }

    @Test fun anOpenCodeSpanAndFenceWhileStreaming() {
        val s = Markdown.parse("run `npm i", streaming = true).single().objs("spans")
        assertTrue(s.last().bool("code"))
        assertEquals("npm i", s.last().str("text"))
        val fence = Markdown.parse("```sh\nls", streaming = true).single()
        assertTrue(fence.bool("open"))
    }

    @Test fun theCacheParsesOnlyTheLastBlockAndKeepsTheRest() {
        val cache = Markdown.Cache()
        val long = List(5) { answer }.joinToString("\n\n")
        var text = ""
        var previous: List<JsonObject> = emptyList()
        var parsed = 0
        var whole = 0
        // Token by token, as a box streams the answer.
        for (piece in long.chunked(7)) {
            // Each step parses from where the last block started, not from the top.
            val from = Markdown.top(text, 0, true).lastOrNull()?.first ?: 0
            text += piece
            val blocks = cache.blocks("e1", text, streaming = true)
            assertEquals(text.length - from, cache.parsed)
            parsed += cache.parsed
            whole += text.length
            // Blocks before the last are the same objects: their views stay.
            if (previous.size >= 2 && blocks.size >= previous.size) for (i in 0 until previous.size - 1) assertSame(previous[i], blocks[i])
            previous = blocks
        }
        assertTrue("parsed $parsed of $whole", parsed * 5 < whole)
        assertSame(previous, cache.blocks("e1", text, streaming = true))
        assertEquals(0, cache.parsed)
        assertEquals(Markdown.parse(long), cache.blocks("e1", text, streaming = false))
        // A text that isn't an extension (an edit, another entry) parses whole.
        assertEquals(Markdown.parse("other"), cache.blocks("e1", "other", streaming = false))
    }
}
