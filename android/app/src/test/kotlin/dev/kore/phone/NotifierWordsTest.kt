package dev.kore.phone

import dev.kore.phone.background.Notifier
import org.junit.Assert.assertEquals
import org.junit.Test

/** Spec §6 notifications: what a card asks by its kind (never its words), and the fold's title. */
class NotifierWordsTest {
    @Test fun eachKindSaysWhatItAsks() {
        assertEquals("Asks to go ahead", Notifier.ask("permission"))
        assertEquals("Has a question", Notifier.ask("question"))
        assertEquals("Waiting for you", Notifier.ask("somethingNew"))
        assertEquals("Waiting for you", Notifier.ask(null))
        assertEquals("3 chats need you", Notifier.folded(3))
    }
}
