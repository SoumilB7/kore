package dev.kore.phone

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A Sheet's builder runs inside show(), before show() returns. So in
 * `lateinit var s: Sheet; s = Sheet(a).show { … }`, the builder may only read `s` inside a lambda
 * it hands on (a tap, a callback); reading it at the builder's own level throws
 * UninitializedPropertyAccessException. That was the 0.3.0 crash on the device screen's ＋
 * (`chatHalf(s, …)`). Read straight from the sources: no Robolectric.
 */
class SheetBuilderTest {
    private val ui = listOf(File("src/main/kotlin/dev/kore/phone/ui"), File("app/src/main/kotlin/dev/kore/phone/ui")).first { it.isDirectory }

    /** Every place a lateinit sheet is read at its own builder's level, as "File.kt:line name". */
    private fun eagerReads(name: String, source: String): List<String> {
        val found = ArrayList<String>()
        for (decl in Regex("""lateinit var (\w+): Sheet\b""").findAll(source)) {
            val v = decl.groupValues[1]
            val start = Regex("""\b$v = Sheet\([^\n]*?\)\.show \{""").find(source, decl.range.last) ?: continue
            var i = start.range.last + 1
            var depth = 1
            while (i < source.length && depth > 0) {
                val c = source[i]
                when {
                    c == '"' -> { i++; while (i < source.length && source[i] != '"') { if (source[i] == '\\') i++; i++ } }
                    c == '{' -> depth++
                    c == '}' -> depth--
                    depth == 1 && source.startsWith(v, i) && !source[i - 1].isLetterOrDigit() && source[i - 1] != '.' &&
                        (i + v.length >= source.length || !source[i + v.length].isLetterOrDigit()) ->
                        found += "$name:${source.substring(0, i).count { it == '\n' } + 1} $v"
                }
                i++
            }
        }
        return found
    }

    @Test fun noSheetIsReadByItsOwnBuilderBeforeShowReturns() {
        val reads = ui.listFiles { f -> f.extension == "kt" }!!.sortedBy { it.name }.flatMap { eagerReads(it.name, it.readText()) }
        assertEquals(emptyList<String>(), reads)
    }

    /** The check sees the 0.3.0 ＋ sheet's read, and passes reads that wait for a tap. */
    @Test fun theCheckCatchesTheCrashOf030() {
        val crashed = """
            lateinit var s: Sheet
            s = Sheet(this).show {
                segmented(listOf("chat" to "Chat"), making) { making = it; if (box) readBoxFolders(s); refresh() }
                if (making == "chat") chatHalf(s, snap, box) else windowHalf(s, snap, box)
            }
        """.trimIndent()
        assertEquals(listOf("x.kt:4 s", "x.kt:4 s"), eagerReads("x.kt", crashed))
        val fine = """
            lateinit var s: Sheet
            s = Sheet(this).show {
                title("Rename")
                buttons("Rename") { s.dismiss(); go("a {brace} in a string") }
            }
        """.trimIndent()
        assertTrue(eagerReads("y.kt", fine).isEmpty())
    }
}
