package dev.kore.phone

import dev.kore.phone.ui.TableFit
import dev.kore.phone.ui.TableFit.Fit
import dev.kore.phone.ui.revertLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tables fit the screen (spec §5): a grid when every column gets its minimum, else stacked; nothing scrolls sideways. */
class TableFitTest {
    private val min = 72 * 3   // 72 dp at 3x

    @Test fun aTableThatFitsKeepsItsNaturalWidths() {
        assertEquals(Fit.Grid(listOf(200, 300, 150)), TableFit.fit(listOf(200, 300, 150), listOf(0, 0, 0), 1000, min))
    }

    @Test fun aWideTableWrapsItsWidestColumnsMostAndUsesTheWholeWidth() {
        val fit = TableFit.fit(listOf(240, 1800, 900), listOf(0, 0, 0), 1000, min) as Fit.Grid
        assertEquals(1000, fit.widths.sum())
        assertTrue(fit.widths.all { it >= min })
        // The narrow column gets about what it needs; the widest gives up most.
        assertTrue(fit.widths[0] in min..240)
        assertTrue(fit.widths[1] > fit.widths[2])
        assertTrue(fit.widths.zip(listOf(240, 1800, 900)).all { (w, n) -> w <= n })
    }

    @Test fun tooManyColumnsForTheMinimumStack() {
        // 360 dp phone at 3x, 1032 px of room: 5 columns need 1080.
        assertEquals(Fit.Stacked, TableFit.fit(List(5) { 400 }, List(5) { 0 }, 1032, min))
        assertTrue(TableFit.fit(List(4) { 400 }, List(4) { 0 }, 1032, min) is Fit.Grid)
    }

    @Test fun narrowColumnsUnderTheMinimumStillFitAsAGrid() {
        assertEquals(Fit.Grid(listOf(100, 120)), TableFit.fit(listOf(100, 120), listOf(0, 0), 1000, min))
    }

    @Test fun nothingOrNoRoomIsStacked() {
        assertEquals(Fit.Stacked, TableFit.fit(emptyList(), emptyList(), 1000, min))
        assertEquals(Fit.Stacked, TableFit.fit(listOf(100), listOf(0), 0, min))
    }

    /** Seen on the emulator: "$13,333.20" was cut to "$13,333." / "20". A column needs its longest word, or the table stacks. */
    @Test fun aColumnNeverGetsLessThanItsLongestWord() {
        // Five columns, 984 px of room, each at least 189 (72 dp at 2.625): the minimum alone fits,
        // but the money column's longest word is 260 and the last column's 240: they don't.
        assertEquals(Fit.Stacked, TableFit.fit(listOf(400, 300, 300, 200, 500), listOf(150, 260, 260, 180, 240), 984, 189))
        // With room for every longest word, a grid where no column is under its word.
        val fit = TableFit.fit(listOf(400, 300, 500), listOf(150, 260, 240), 984, 189) as Fit.Grid
        assertTrue(fit.widths.zip(listOf(150, 260, 240)).all { (w, word) -> w >= maxOf(189, word) })
    }

    /** Design spec §8: the line says what this revert does; files are never said to come back. */
    @Test fun theRevertLineSaysWhatItDoes() {
        assertEquals("The chat goes back to before this message. Its text returns to the field.", revertLine(prompt = true))
        assertEquals("The chat goes back to this answer; what came after it leaves.", revertLine(prompt = false))
        assertTrue(!revertLine(true).contains("files") && !revertLine(false).contains("files"))
    }
}
