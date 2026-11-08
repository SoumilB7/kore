package dev.kore.link

import dev.kore.link.node.AccountUsage
import dev.kore.link.node.Control
import dev.kore.link.node.NodeClient
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Link 1.14's usage, on the contract's own bytes (Tests/Fixtures/link/v1, which the Mac round-trips too). */
class AccountUsageTest {
    private val dir = File(System.getProperty("kore.fixturesV1") ?: error("kore.fixturesV1 not set"))
    private fun fixture(name: String) = Json.parseToJsonElement(File(dir, name).readText()) as JsonObject

    @Test fun theDeltaReadsAsEachLoginsWindows() {
        val delta = fixture("delta.usage.json")
        // A delta's clis replace the snapshot's whole (NodeClient.merge), as the Mac sends them.
        val snap = NodeClient.merge(buildJsonObject { put("t", "snapshot"); put("rev", 8) }, delta)
        val all = AccountUsage.of(snap)
        assertEquals(listOf("claude/main", "claude/work", "codex/main"), all.map { "${it.provider}/${it.login}" })
        val main = all[0]
        assertEquals("ku••••@••il.com", main.email)
        assertEquals("Max", main.plan)
        assertEquals(true, main.active)
        assertEquals(listOf(AccountUsage.Limit("5h", 42, 1795161600000), AccountUsage.Limit("7d", 81, 1795507200000)), main.limits)
        // A login not read yet: who it is, no plan, no windows.
        assertEquals(AccountUsage.Login("claude", "work", "so••••@••rp.com", false, null, emptyList()), all[1])
        // A window without its reset.
        assertEquals(AccountUsage.Limit("7d", 63, null), all[2].limits[1])
        assertEquals(listOf("claude", "codex"), AccountUsage.providers(snap))
    }

    @Test fun aChatShowsTheLoginItNamesElseTheActiveOne() {
        val snap = fixture("delta.usage.json")
        fun chat(provider: String, login: String?) = buildJsonObject {
            put("provider", provider)
            if (login != null) put("controls", buildJsonObject { put("login", login) })
        }
        assertEquals("work", AccountUsage.forChat(snap, chat("claude", "work"))?.login)
        assertEquals("main", AccountUsage.forChat(snap, chat("claude", null))?.login)
        // A login the node doesn't list (gone since): the active one.
        assertEquals("main", AccountUsage.forChat(snap, chat("claude", "gone"))?.login)
        assertEquals("codex", AccountUsage.forChat(snap, chat("codex", null))?.provider)
        assertNull(AccountUsage.forChat(snap, chat("gemini", null)))
        // A node from before 1.14 sends no usage.
        assertNull(AccountUsage.forChat(fixture("delta.account.json"), chat("codex", null)))
        assertEquals(emptyList<String>(), AccountUsage.providers(fixture("delta.account.json")))
    }

    @Test fun theReadIsTheFixturesCommand() {
        val want = fixture("cmd.account.usage.json")
        assertEquals(want, Control.envelope("u1", Control.accountUsage("codex")))
    }
}
