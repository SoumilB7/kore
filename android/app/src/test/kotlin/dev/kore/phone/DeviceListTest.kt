package dev.kore.phone

import dev.kore.phone.ui.DeviceList
import dev.kore.phone.ui.DeviceList.Cue
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
            {"id":"design","title":"Kore-design","provider":"codex","state":"idle","lastAt":${now - 2 * min}}]}""")

    @Test fun needsYouThenWorkingThenTheMostRecent() {
        val rows = DeviceList.rows(mac, null, now, none)
        assertEquals(listOf("Kore-3", "Kore-main", "Kore-design", "Kore-2"), rows.map { it.title })
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
        assertEquals("", rows.getValue("Kore-design").line)
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
        assertFalse(rows.getValue("Kore-design").unread)
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
}
