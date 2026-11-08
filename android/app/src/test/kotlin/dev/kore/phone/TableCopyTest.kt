package dev.kore.phone

import dev.kore.phone.ui.TableCopy
import org.junit.Assert.assertEquals
import org.junit.Test

/** "Copy table" copies what the Mac's table Copy does (`TranscriptSelectionTests.aTablesCopyIsItsWholeSelection`). */
class TableCopyTest {
    @Test fun headerThenRowsSplitByTabs() {
        assertEquals(
            "Name\tKind\nalpha\tone\nbeta\ttwo",
            TableCopy.text(listOf("Name", "Kind"), listOf(listOf("alpha", "one"), listOf("beta", "two"))),
        )
    }

    @Test fun aShortRowKeepsOnlyItsCells() {
        assertEquals("A\tB\n1", TableCopy.text(listOf("A", "B"), listOf(listOf("1"))))
    }
}
