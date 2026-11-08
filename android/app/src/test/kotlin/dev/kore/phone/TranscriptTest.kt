package dev.kore.phone

import dev.kore.phone.link.Transcript
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One chat's transcript window: a page, deltas (upserts, removals, order), a reset. Link 1.11 shapes. */
class TranscriptTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject

    @Test fun pageThenDeltasThenReset() {
        val t = Transcript("c1")
        assertTrue(t.apply(o("""{"t":"tx.page","chatId":"c1","txRev":1,"entries":[{"id":"a","kind":"user"},{"id":"b","kind":"assistant"}],"turns":[],"hasEarlier":true}""")))
        assertEquals(listOf("a", "b"), t.order)
        assertTrue(t.hasEarlier)
        assertTrue(t.apply(o("""{"t":"tx.delta","chatId":"c1","txRev":2,"upserts":[{"id":"c","kind":"assistant"},{"id":"b","kind":"assistant","text":"more"}],"removed":["a"]}""")))
        assertEquals(listOf("b", "c"), t.order)
        assertEquals("more", t.entries[0]["text"].toString().trim('"'))
        assertTrue(t.apply(o("""{"t":"tx.delta","chatId":"c1","txRev":3,"upserts":[],"order":["c","b"],"hasEarlier":false}""")))
        assertEquals(listOf("c", "b"), t.order)
        assertFalse(t.hasEarlier)
        assertTrue(t.apply(o("""{"t":"tx.reset","chatId":"c1"}""")))
        assertEquals(0, t.entries.size)
    }

    @Test fun anotherChatsMessagesAreIgnored() {
        val t = Transcript("c1")
        assertFalse(t.apply(o("""{"t":"tx.page","chatId":"c2","entries":[{"id":"x"}]}""")))
        assertFalse(t.apply(o("""{"t":"snapshot","chatId":"c1"}""")))
        assertEquals(0, t.entries.size)
    }
}
