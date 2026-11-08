package dev.kore.phone

import dev.kore.phone.ui.CardPicks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A question card's picks: a one-of holds one, Other included; an any-of keeps Other beside. */
class CardPicksTest {
    /** Claude's question id is its text; Codex's is its own. */
    private val ids = listOf("Which layout?", "layout")

    @Test fun optionThenOtherSendsOnlyTheWords() = ids.forEach { q ->
        val picks = CardPicks()
        picks.pick(q, "Tabs", multiple = false)
        picks.pickOther(q, multiple = false)
        assertTrue(!picks.on(q, "Tabs"))
        assertEquals(mapOf(q to listOf("Tabs in a sidebar")), picks.answers(mapOf(q to " Tabs in a sidebar ")))
    }

    @Test fun otherThenOptionSendsOnlyTheOption() = ids.forEach { q ->
        val picks = CardPicks()
        picks.pickOther(q, multiple = false)
        picks.pick(q, "Sidebar", multiple = false)
        assertTrue(q !in picks.other)
        assertEquals(mapOf(q to listOf("Sidebar")), picks.answers(mapOf(q to "Tabs in a sidebar")))
        // Other again: the words go, the option doesn't.
        picks.pickOther(q, multiple = false)
        assertEquals(mapOf(q to listOf("Tabs in a sidebar")), picks.answers(mapOf(q to "Tabs in a sidebar")))
    }

    @Test fun anyOfKeepsOtherBeside() {
        val q = "Which colours?"
        val picks = CardPicks()
        picks.pickOther(q, multiple = true)
        picks.pick(q, "Red", multiple = true)
        picks.pick(q, "Blue", multiple = true)
        assertEquals(mapOf(q to listOf("Red", "Blue", "Green")), picks.answers(mapOf(q to "Green")))
    }
}
