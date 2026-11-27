package dev.kore.link

import dev.kore.link.node.Control
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** `chat.copyVia` (cap "copyVia") as the phone sends it, on the contract's bytes (the Mac round-trips them too). */
class CopyViaTest {
    private val dir = File(System.getProperty("kore.fixturesV1") ?: error("kore.fixturesV1 not set"))

    @Test fun theCommandIsTheContracts() {
        val fixture = Json.parseToJsonElement(File(dir, "cmd.copyVia.json").readText()) as JsonObject
        val cmd = Control.copyVia(
            "3d2b6f10-0000-4000-8000-0000000000c2",
            Control.CopyEnd("9a3e5c10-0000-4000-8000-0000000000b1", "w_box1", chatId = "5f0c2a1e-0000-4000-8000-000000000007"),
            Control.CopyEnd(null, "w_1"),
            "codex", "Fix the login page",
        )
        assertEquals(fixture, Control.envelope("c21", cmd))
    }

    @Test fun aTargetNamesItsWindowOnlyAndTheTitleIsOneLine() {
        val cmd = Control.copyVia("a1", Control.CopyEnd(null, "w_1", sessionId = "s1"), Control.CopyEnd("b", "w_2", chatId = "x"), "claude", "a\nb" + "x".repeat(300))
        val copy = cmd["copy"] as JsonObject
        assertEquals("""{"device":"b","windowId":"w_2"}""", copy["to"].toString())
        assertEquals("""{"windowId":"w_1","sessionId":"s1"}""", copy["from"].toString())
        assertEquals(null, copy["again"])
        val again = Control.copyVia("a1", Control.CopyEnd(null, "w_1", sessionId = "s1"), Control.CopyEnd(null, "w_2"), "claude", "a", again = true)["copy"] as JsonObject
        assertEquals("a1 true", "${copy["id"].toString().trim('"')} ${again["again"]}")
        assertEquals(200, copy["title"].toString().trim('"').length)
    }
}
