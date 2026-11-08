package dev.kore.phone

import dev.kore.phone.ui.CloseHold
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Closing a chat from the phone: refused, with its first reason, while it would lose work (as Arsenal's close). */
class ChatCloseTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject

    @Test fun anIdleChatCloses() {
        assertNull(CloseHold.reason(o("""{"id":"c","state":"idle","running":false,"queued":0,"cards":[]}""")))
        assertNull(CloseHold.reason(o("""{"id":"c","state":"idle"}"""), draft = "  \n"))
    }

    @Test fun eachHoldSaysWhy() {
        assertEquals("It's working: stop it first.", CloseHold.reason(o("""{"running":true}""")))
        assertEquals("It's working: stop it first.", CloseHold.reason(o("""{"state":"working"}""")))
        assertEquals("It's working: stop it first.", CloseHold.reason(o("""{"queued":2}""")))
        assertEquals("A message in it waits for the network.", CloseHold.reason(o("""{"rescue":{"connection":"offline"}}""")))
        assertEquals("A card in it waits for an answer.", CloseHold.reason(o("""{"state":"needsYou"}""")))
        assertEquals("A card in it waits for an answer.", CloseHold.reason(o("""{"cards":[{"id":"k"}]}""")))
        assertEquals("Its message isn't sent yet.", CloseHold.reason(o("""{}"""), draft = "half a thought"))
        assertEquals("Its attachments aren't sent yet.", CloseHold.reason(o("""{}"""), files = 1))
        assertEquals("Its sub-agents are running.", CloseHold.reason(o("""{"background":{"agents":1}}""")))
        assertEquals("Commands it started still run.", CloseHold.reason(o("""{"background":{"commands":2}}""")))
    }

    @Test fun theFirstHoldWins() {
        // As ArsenalCloseHold orders them: the turn before a card, a card before the composer.
        assertEquals("It's working: stop it first.", CloseHold.reason(o("""{"running":true,"state":"needsYou","background":{"agents":1}}"""), draft = "x"))
        assertEquals("A card in it waits for an answer.", CloseHold.reason(o("""{"cards":[{}],"background":{"commands":1}}"""), files = 3))
    }

    @Test fun closeShowsWhereTheDeviceTakesIt() {
        // A Mac says so (full control, or the phone's ask view); with only the standard view it doesn't.
        assertTrue(CloseHold.offered(o("""{"can":{"send":true,"close":true}}"""), box = false))
        assertFalse(CloseHold.offered(o("""{"can":{"send":true}}"""), box = false))
        // A box closes its chats: said from 1.13, assumed before.
        assertTrue(CloseHold.offered(o("""{"can":{"send":true}}"""), box = true))
        assertTrue(CloseHold.offered(o("""{"can":{"send":true,"close":true}}"""), box = true))
        assertFalse(CloseHold.offered(o("""{"can":{"close":false}}"""), box = true))
    }
}
