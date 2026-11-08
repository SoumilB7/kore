package dev.kore.phone

import dev.kore.phone.ui.TextPick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which chat rows pick text, and what in a bubble is a tap rather than a selection's start. */
class TextPickTest {
    @Test fun messagesAndAnswersPickToolRowsDont() {
        for (kind in listOf("user", "answer", "plan")) assertTrue(kind, TextPick.selectable(kind))
        // Tool, thinking and the rest open on a tap: their text stays a control.
        for (kind in listOf("tool", "thinking", "agent", "summary", "notice", "divider", null)) assertFalse("$kind", TextPick.selectable(kind))
    }

    @Test fun aTapIsShortAndStill() {
        assertTrue(TextPick.isTap(3f, 4f, 120, slop = 8, longPressMs = 400))
        // Moved past the slop: a scroll or a drag.
        assertFalse(TextPick.isTap(6f, 7f, 120, slop = 8, longPressMs = 400))
        // Held to the long-press: a selection starts, no image opens.
        assertFalse(TextPick.isTap(0f, 0f, 400, slop = 8, longPressMs = 400))
    }

    @Test fun messageSitsAfterTheSystemsItems() {
        // Copy 5, Share 7, Select all 8 in the system's toolbar; its text actions from 100.
        assertTrue(TextPick.ORDER in 9 until 100)
        assertEquals("Message…", TextPick.MESSAGE)
    }
}
