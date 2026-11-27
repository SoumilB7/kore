package dev.kore.phone

import dev.kore.phone.ui.DeviceList
import dev.kore.phone.ui.DeviceList.Cue
import dev.kore.phone.ui.objs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Device screen as one recent list: order, the one cue, empty windows, unread, ages. */
class DeviceListTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject
    private val now = 1_800_000_000_000L
    private val min = 60_000L
    private val none = object : DeviceList.Seen { override fun unread(chatId: String, at: Long?) = false }

    /** A Mac: one window, its chats as tabs. */
    private val mac = o("""{
        "windows":[{"id":"w1","name":"kore","path":"~/Code/Projects/kore","tabs":[
            {"kind":"chat","chatId":"main"},{"kind":"chat","chatId":"two"},{"kind":"chat","chatId":"three"},
            {"kind":"chat","chatId":"design"},{"kind":"file","title":"a.swift"}]}],
        "chats":[
            {"id":"two","title":"Kore-2","provider":"claude","state":"idle","lastAt":${now - 14 * min},"last":"Landed 3 commits on main"},
            {"id":"main","title":"Kore-main","provider":"claude","state":"working","lastAt":${now - 30 * min},"last":"You: land it"},
            {"id":"three","title":"Kore-3","provider":"claude","state":"needsYou","lastAt":${now - 90 * min},"cards":[{"id":"c","title":"Allow Bash: swift test\nmore"}]},
            {"id":"design","title":"Kore-notes","provider":"codex","state":"idle","lastAt":${now - 2 * min}}]}""")

    @Test fun needsYouThenWorkingThenTheMostRecent() {
        val rows = DeviceList.rows(mac, null, now, none)
        assertEquals(listOf("Kore-3", "Kore-main", "Kore-notes", "Kore-2"), rows.map { it.title })
        assertEquals(listOf(Cue.NEEDS, Cue.WORKING, Cue.NONE, Cue.NONE), rows.map { it.cue })
    }

    @Test fun oneCuePerRowAndIdleSaysNothing() {
        val rows = DeviceList.rows(mac, null, now, none).associateBy { it.title }
        assertEquals("Allow Bash: swift test", rows.getValue("Kore-3").line)
        assertEquals("Working", rows.getValue("Kore-main").line)
        assertEquals("now", rows.getValue("Kore-main").age)
        assertEquals("Landed 3 commits on main", rows.getValue("Kore-2").line)
        assertEquals("14 m", rows.getValue("Kore-2").age)
        // Idle with nothing said: an empty second line, never "idle".
        assertEquals("", rows.getValue("Kore-notes").line)
        assertTrue(rows.values.none { "idle" in it.line || "idle" in it.age })
    }

    /** A box: four windows, one empty; its chats name their window. */
    private val box = o("""{
        "windows":[{"id":"t","name":"Test1","tabs":[]},{"id":"s","name":"soumil","tabs":[]},{"id":"o","name":"Onfinance","tabs":[]},{"id":"p","name":"Platform","tabs":[]}],
        "chats":[
            {"id":"c1","title":"Claude","windowId":"t","state":"idle","lastAt":${now - 120 * min},"last":"All 12 tests pass."},
            {"id":"m","title":"Main-struc","windowId":"o","state":"idle","lastAt":${now - 40 * min},"last":"Split the ledger module"},
            {"id":"sl","title":"Slack","windowId":"o","state":"idle","lastAt":${now - 180 * min},"last":"You: draft the release note"},
            {"id":"c2","title":"Claude","windowId":"p","state":"idle","lastAt":${now - 2 * 1440 * min},"last":"Deployed to staging."}]}""")

    @Test fun manyWindowsAreChipsAndRowsNameTheirWindow() {
        val chips = DeviceList.chips(box)
        assertEquals(listOf("Test1" to 1, "soumil" to 0, "Onfinance" to 2, "Platform" to 1), chips.map { it.name to it.chats })
        val all = DeviceList.rows(box, null, now, none)
        assertEquals(listOf("m", "c1", "sl", "c2"), all.map { it.chatId })
        assertEquals("Onfinance · Split the ledger module", all[0].line)
        assertEquals(listOf("40 m", "2 h", "3 h", "2 d"), all.map { it.age })
        // Filtered to one window: its own rows, no prefix.
        val one = DeviceList.rows(box, "o", now, none)
        assertEquals(listOf("Split the ledger module", "You: draft the release note"), one.map { it.line })
        assertTrue(DeviceList.rows(box, "s", now, none).isEmpty())
    }

    @Test fun unreadIsThePhonesOwn() {
        val seen = object : DeviceList.Seen {
            override fun unread(chatId: String, at: Long?) = chatId == "two"
        }
        val rows = DeviceList.rows(mac, null, now, seen).associateBy { it.title }
        assertTrue(rows.getValue("Kore-2").unread)
        assertFalse(rows.getValue("Kore-notes").unread)
    }

    @Test fun ages() {
        assertEquals("now", DeviceList.age(now - 20_000, now))
        assertEquals("59 m", DeviceList.age(now - 59 * min, now))
        assertEquals("23 h", DeviceList.age(now - 23 * 60 * min, now))
        assertEquals("yesterday", DeviceList.age(now - 30 * 60 * min, now))
        assertEquals("3 d", DeviceList.age(now - 3 * 1440 * min, now))
        assertEquals("", DeviceList.age(null, now))
    }

    @Test fun equalRowsAreEqualSoTheListRebindsOnlyChanges() {
        val a = DeviceList.rows(mac, null, now, none)
        val b = DeviceList.rows(mac, null, now + 10_000, none)
        assertEquals(a, b)
    }

    /** Spec §5: chips whose names match add their parent folder; if those match too, the folder above. */
    @Test fun collidingChipNamesAddTheirFolder() {
        val chips = listOf(
            DeviceList.Chip("a", "kore", 1, "~/Code/Projects/kore"),
            DeviceList.Chip("b", "kore", 1, "~/Code/clones/kore"),
            DeviceList.Chip("c", "api", 1, "~/Work/x/api"),
            DeviceList.Chip("d", "api", 1, "~/Play/x/api"),
            DeviceList.Chip("e", "solo", 1, "~/solo"),
        )
        assertEquals(listOf("Projects", "clones", "Work/x", "Play/x", null), DeviceList.chipSuffixes(chips))
    }

    /** Arsenal at any tier: the row knows, and its logo, spinner and ">_" take the Arsenal mark's blue; off, their own colours. */
    @Test fun arsenalTintsTheLogoSpinnerAndPrompt() {
        for (provider in listOf("claude", "codex")) {
            val own = if (provider == "codex") dev.kore.phone.ui.Tone.spinCodex else dev.kore.phone.ui.Tone.spinClaude
            for (tier in listOf(null, "off")) {
                val row = DeviceList.chatRow(o("""{"id":"a","provider":"$provider"${tier?.let { ",\"arsenal\":\"$it\"" } ?: ""}}"""), "w1", "", false, now, none)!!
                assertFalse(row.arsenal)
                assertEquals(null, dev.kore.phone.ui.logoTint(row.arsenal))
                assertEquals(own, dev.kore.phone.ui.workTint(provider, row.arsenal))
            }
            for (tier in listOf("watch", "own", "drive", "device", "full")) {
                val row = DeviceList.chatRow(o("""{"id":"a","provider":"$provider","arsenal":"$tier"}"""), "w1", "", false, now, none)!!
                assertTrue(row.arsenal)
                assertEquals(dev.kore.phone.ui.Tone.accent, dev.kore.phone.ui.logoTint(row.arsenal))
                assertEquals(dev.kore.phone.ui.Tone.accent, dev.kore.phone.ui.workTint(provider, row.arsenal))
            }
        }
    }

    // Pins: this phone's own, per device.

    @Test fun pinnedChatsComeFirstInTheirUsualOrder() {
        val pins = DeviceList.Pins { it == "c:two" || it == "c:design" }
        val rows = DeviceList.rows(mac, null, now, none, pins)
        assertEquals(listOf("Kore-notes", "Kore-2", "Kore-3", "Kore-main"), rows.map { it.title })
        assertEquals(listOf(true, true, false, false), rows.map { it.pinned })
    }

    @Test fun aWindowsListPinsToo() {
        val rows = DeviceList.rows(box, "o", now, none, DeviceList.Pins { it == "c:sl" })
        assertEquals(listOf("Slack", "Main-struc"), rows.map { it.title })
    }

    @Test fun noPinsKeepsTheOrder() {
        assertEquals(DeviceList.rows(mac, null, now, none).map { it.title }, DeviceList.rows(mac, null, now, none, DeviceList.Pins.NONE).map { it.title })
    }

    @Test fun aChatPinsByItsSessionThenItsId() {
        assertEquals(listOf("s:abc", "c:x"), DeviceList.pinKeys(o("""{"id":"x","sessionId":"abc"}""")))
        assertEquals(listOf("c:x"), DeviceList.pinKeys(o("""{"id":"x"}""")))
        assertEquals(listOf("c:x"), DeviceList.pinKeys(o("""{"id":"x","sessionId":""}""")))
        // A History row's key is its session's: the same chat, closed.
        assertEquals("s:abc", DeviceList.historyPinKey("abc"))
    }

    /** Pinned before its first turn (by its id), it stays pinned once its session comes. */
    @Test fun aPinByIdHoldsOnceTheSessionComes() {
        val pins = DeviceList.Pins { it == "c:x" }
        val later = DeviceList.chatRow(o("""{"id":"x","sessionId":"abc","title":"T","state":"idle"}"""), null, "", false, now, none, pins)
        assertTrue(later!!.pinned)
        assertEquals(listOf("s:abc", "c:x"), later.pinKeys)
    }

    /** The contract: the session as the Mac and the box send it (`delta.session.json`). */
    @Test fun theSessionIsReadAsTheLinkSendsIt() {
        val dir = checkNotNull(System.getProperty("kore.fixturesV1")) { "kore.fixturesV1 is set by the app's test task" }
        val delta = o(java.io.File(dir, "delta.session.json").readText())
        val chat = delta.objs("chats").single()
        assertEquals("s:0b4f6a2e-7c1d-4e8a-9f3b-5d2c1a0e9b77", DeviceList.pinKeys(chat).first())
        val row = DeviceList.chatRow(chat, null, "", false, now, none, DeviceList.Pins { it == "s:0b4f6a2e-7c1d-4e8a-9f3b-5d2c1a0e9b77" })
        assertTrue(row!!.pinned)
        assertFalse(DeviceList.chatRow(chat, null, "", false, now, none)!!.pinned)
    }
}
