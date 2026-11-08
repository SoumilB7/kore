package dev.kore.link

import dev.kore.link.node.Control
import org.junit.Assert.assertEquals
import org.junit.Test

/** Control's builders give link 1.11's command bodies. */
class ControlTest {
    @Test fun basics() {
        assertEquals("""{"type":"chat.send","chatId":"c","text":"hi","blobs":["b1"]}""", Control.send("c", "hi", listOf("b1")).toString())
        assertEquals("""{"type":"chat.answer","chatId":"c","cardId":"k","action":"allow","digest":"d","answers":{"q":["a"]}}""",
            Control.answer("c", "k", "allow", "d", mapOf("q" to listOf("a"))).toString())
        assertEquals("""{"type":"chat.new","folder":"/srv/app","provider":"codex"}""", Control.newChatInFolder("/srv/app", "codex").toString())
        assertEquals("""{"type":"chat.new","windowId":"w","provider":"claude"}""", Control.newChat("w", "claude").toString())
        assertEquals("""{"t":"presence","onScreen":true,"chatId":"c"}""", Control.presence(true, "c").toString())
        assertEquals("""{"t":"presence","onScreen":false}""", Control.presence(false, null).toString())
        assertEquals("""{"t":"cmd","id":"1","cmd":{"type":"chat.stop","chatId":"c"}}""", Control.envelope("1", Control.stop("c")).toString())
    }

    @Test fun renameIsOneLineOfAtMost200() {
        val t = Control.rename("c", "a\nb" + "x".repeat(300))
        assertEquals(200, t["title"].toString().trim('"').length)
    }

    @Test fun readsKnowTheirReplies() {
        assertEquals("history.page", Control.replyTo("history.list"))
        assertEquals("diff.hunks", Control.replyTo("diff.get"))
        assertEquals("raise.chal", Control.replyTo("raise.chal"))
    }

    @Test fun arsenalRaisesOnlyUpward() {
        assertEquals(true, Control.arsenalRaises("watch", "own"))
        assertEquals(false, Control.arsenalRaises("drive", "own"))
        assertEquals(true, Control.arsenalRaises(null, "watch"))
    }
}
