package dev.kore.phone

import dev.kore.phone.ui.ControlModel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the full-control screens draw from the Mac's state: models, rescue rows, groups, history days. */
class ControlModelTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject
    private fun list(s: String) = Json.parseToJsonElement(s).let { it as kotlinx.serialization.json.JsonArray }.map { it.jsonObject }

    @Test fun modelFamilies() {
        val f = ControlModel.families(list("""[{"id":"o48","name":"Atlas 4.8"},{"id":"o47","name":"Atlas 4.7"},{"id":"s46","name":"Brook 4.6"},{"id":"luna","name":"gpt-6-luna"}]"""))
        assertEquals(listOf("Atlas", "Brook", "gpt-6-luna"), f.map { it.name })
        assertEquals(listOf("o48" to "4.8", "o47" to "4.7"), f[0].versions)
        assertEquals(listOf("luna" to ""), f[2].versions)
    }

    @Test fun rescueRowsInTheMacsWords() {
        val rows = ControlModel.rescue(o("""{"connection":"stalled","sleptTurn":"r3","retryTurn":"r2","continuesAt":1793500000000,"sendsAtReset":"Then update the changelog.\nAnd more"}""")) { "at 4:00 PM" }
        assertEquals(listOf("stalled", "retry:r2", "slept:r3", "continues"), rows.map { it.key })
        assertEquals(listOf("retry", "stop"), rows[0].actions)
        assertEquals("Stopped while the Mac slept", rows[2].text)
        assertEquals("“Then update the changelog.” · sends at 4:00 PM", rows[3].text)
        assertEquals("Continues at 4:00 PM", ControlModel.rescue(o("""{"connection":"ok","continuesAt":1}""")) { "at 4:00 PM" }.single().text)
        assertTrue(ControlModel.rescue(o("""{"connection":"ok"}""")) { "" }.isEmpty())
        assertEquals(1793500000000, ControlModel.limitReset(o("""{"connection":"ok","limitReset":1793500000000}""")))
    }

    @Test fun groupRunsUnderOneHeader() {
        val w = o("""{"groups":[{"id":"g1","name":"Auth","color":"blue","folded":false}],"tabs":[{"id":"t1","groupId":"g1"},{"id":"t2","groupId":"g1"},{"id":"t3"},{"id":"t4","groupId":"gone"}]}""")
        val segs = ControlModel.segments(w)
        assertEquals(3, segs.size)
        assertEquals(2, (segs[0] as ControlModel.Segment.Group).tabs.size)
        // A tab whose group isn't listed shows as a loose tab.
        assertTrue(segs[2] is ControlModel.Segment.Tab)
    }

    @Test fun historyDaysAndFolders() {
        val zone = java.time.ZoneId.of("Asia/Kolkata")
        val now = java.time.ZonedDateTime.of(2026, 11, 1, 14, 0, 0, 0, zone).toInstant().toEpochMilli()
        assertEquals("Today", ControlModel.bucket(now - 3_600_000, now, zone))
        assertEquals("This week", ControlModel.bucket(now - 3 * 86_400_000L, now, zone))
        assertEquals("Earlier", ControlModel.bucket(now - 9 * 86_400_000L, now, zone))
        assertEquals("~/Code", ControlModel.parentOf("Code/api-gateway"))
        assertEquals("~", ControlModel.parentOf("dotfiles"))
        assertEquals("~/Code/Projects", ControlModel.parentOf("~/Code/Projects/kore"))
    }
}
