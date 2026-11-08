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
        // As a CLI lists them: families in the order of their first model, versions newest first,
        // a " · 1M" tail kept on its version's chip, a name with no number a family of its own.
        val models = list("""[
            {"id":"a","name":"Atlas 5.5"},{"id":"a1m","name":"Atlas 5.5 · 1M"},{"id":"f","name":"Fern 5.2"},
            {"id":"b","name":"Brook 5.5"},{"id":"f51","name":"Fern 5.1"},{"id":"a5","name":"Atlas 5"},
            {"id":"a48","name":"Atlas 4.8"},{"id":"a410","name":"Atlas 4.10"},{"id":"luna","name":"Orbit-6 Luna"},
            {"id":"sol61","name":"Orbit-6.1 Sol"},{"id":"sol","name":"Orbit-6 Sol"},{"id":"auto","name":"Default"}]""")
        val f = ControlModel.families(models)
        assertEquals(listOf("Atlas", "Fern", "Brook", "Orbit Luna", "Orbit Sol", "Default"), f.map { it.name })
        assertEquals(listOf("5.5", "5.5 · 1M", "5", "4.10", "4.8"), f[0].versions.map { it.second })
        assertEquals(listOf("a", "a1m", "a5", "a410", "a48"), f[0].ids)
        assertEquals(listOf("sol61" to "6.1", "sol" to "6"), f[4].versions)
        assertTrue(f[5].versionless && !f[0].versionless)
        // No ids on any chip.
        assertTrue(f.flatMap { it.versions }.none { (id, label) -> label == id && label.isNotEmpty() })
    }

    @Test fun theChatsModelIsLit() {
        val f = ControlModel.families(list("""[{"id":"a","name":"Atlas 5.5"},{"id":"a1m","name":"Atlas 5.5 · 1M"},{"id":"b","name":"Brook 5"}]"""))
        assertEquals("Atlas" to "5.5 · 1M", ControlModel.current(f, "a1m"))
        assertEquals("Brook" to "5", ControlModel.current(f, "b"))
        assertEquals(null, ControlModel.current(f, "gone"))
    }

    @Test fun anEffortTheModelDoesntOfferIsStruck() {
        val snap = o("""{"clis":[{"provider":"p","effortScale":["low","medium","high","xhigh","max"],"models":[
            {"id":"new","name":"Atlas 5","efforts":["low","medium","high","xhigh","max"]},
            {"id":"old","name":"Atlas 4.6","efforts":["low","medium","high","max"]},
            {"id":"none","name":"Brook 4.5","efforts":[]}]}]}""")
        val models = ControlModel.models(snap, "p")
        val old = ControlModel.efforts(snap, "p", models[1])
        assertEquals(listOf("low", "medium", "high", "xhigh", "max"), old.map { it.level })
        assertEquals(listOf("xhigh"), old.filter { !it.offered }.map { it.level })
        assertTrue(ControlModel.efforts(snap, "p", models[0]).all { it.offered })
        // A model with no effort: no segment at all.
        assertTrue(ControlModel.efforts(snap, "p", models[2]).isEmpty())
        // Picking it from xhigh: the nearest level below it offers.
        val scale = old.map { it.level }
        assertEquals("high", ControlModel.effortFallback("xhigh", listOf("low", "medium", "high", "max"), scale))
        assertEquals("max", ControlModel.effortFallback("max", listOf("low", "medium", "high", "max"), scale))
        // A CLI without a scale (a box before its list): the models' own levels, lowest first.
        val bare = o("""{"clis":[{"provider":"q","models":[{"id":"x","name":"Orbit-6 Sol","efforts":["high","low","medium"]}]}]}""")
        assertEquals(listOf("low", "medium", "high"), ControlModel.efforts(bare, "q", ControlModel.models(bare, "q")[0]).map { it.level })
    }

    @Test fun theComposersModelChip() {
        val models = list("""[{"id":"a","name":"Atlas 5.5"}]""")
        assertEquals("Atlas 5.5 · high", ControlModel.modelChip(models, "a", null, "high"))
        assertEquals("Brook", ControlModel.modelChip(models, "gone", "Brook", null))
        assertEquals(null, ControlModel.modelChip(models, "gone", null, "high"))
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
