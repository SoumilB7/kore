package dev.kore.phone

import dev.kore.phone.ui.Commands
import org.junit.Assert.assertEquals
import org.junit.Test

class CommandsTest {
    private val all = listOf("compact" to "Summarise the chat", "clear" to "", "review" to "Review changes", "pr-comments" to "")

    @Test fun slashAloneListsAll() = assertEquals(4, Commands.filter(all, "/").size)
    @Test fun prefixFirstThenContains() = assertEquals(listOf("compact", "clear"), Commands.filter(all, "/c").map { it.first }.take(2))
    @Test fun containsMatches() = assertEquals(listOf("pr-comments"), Commands.filter(all, "/comm").map { it.first })
    @Test fun closesAfterASpace() = assertEquals(0, Commands.filter(all, "/compact now").size)
    @Test fun onlyAtTheStart() = assertEquals(0, Commands.filter(all, "hi /c").size)
}
