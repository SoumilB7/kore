package dev.kore.phone

import dev.kore.link.node.AccountUsage
import dev.kore.phone.ui.UsageMeters
import dev.kore.phone.ui.UsageMeters.Level
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UsageMetersTest {
    private val zone = ZoneId.of("Asia/Kolkata")
    private val clock = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    /** Wed 18 Nov 2026, 1:30 PM. */
    private val now = ZonedDateTime.of(2026, 11, 18, 13, 30, 0, 0, zone).toInstant().toEpochMilli()
    private fun at(day: Int, h: Int, m: Int) = ZonedDateTime.of(2026, 11, day, h, m, 0, 0, zone).toInstant().toEpochMilli()
    private val time = { t: Long -> UsageMeters.time(t, now, zone, clock) }
    private fun row(five: Int, week: Int, fiveAt: Long? = at(18, 15, 40), weekAt: Long? = at(23, 9, 0)) =
        UsageMeters.row(AccountUsage.Login("claude", "main", "ku••••@••il.com", true, "Max",
            listOf(AccountUsage.Limit("5h", five, fiveAt), AccountUsage.Limit("7d", week, weekAt))), now, time)

    @Test fun amberFromEightyRedAtTheLimit() {
        assertEquals(Level.NORMAL, UsageMeters.level(0))
        assertEquals(Level.NORMAL, UsageMeters.level(79))
        assertEquals(Level.NEAR, UsageMeters.level(80))
        assertEquals(Level.NEAR, UsageMeters.level(99))
        assertEquals(Level.AT, UsageMeters.level(100))
        assertEquals(Level.AT, UsageMeters.level(130))
    }

    @Test fun resetsSayTheTimeTodayAndTheDayAfter() {
        assertEquals("3:40 PM", time(at(18, 15, 40)))
        assertEquals("Mon 9:00 AM", time(at(23, 9, 0)))
    }

    @Test fun belowTheLimitTheFullestWindowsResetIsQuiet() {
        val r = row(42, 61)
        assertEquals(listOf("5 h" to 42, "Week" to 61), r.meters.map { it.label to it.pct })
        assertEquals("Week resets Mon 9:00 AM", r.note)
        assertEquals(Level.NORMAL, r.noteLevel)
        // A tie goes to the week.
        assertEquals("Week resets Mon 9:00 AM", row(50, 50).note)
        assertEquals("5 h resets 3:40 PM", row(70, 20).note)
    }

    @Test fun nearALimitTheMeterAndItsResetTurnAmber() {
        val r = row(86, 40)
        assertEquals(listOf(Level.NEAR, Level.NORMAL), r.meters.map { it.level })
        assertEquals("5 h resets 3:40 PM", r.note)
        assertEquals(Level.NEAR, r.noteLevel)
    }

    @Test fun atTheLimitItSaysWhenItsUsableAgainInRed() {
        val r = row(100, 93)
        assertEquals(listOf(Level.AT, Level.NEAR), r.meters.map { it.level })
        assertEquals("resets 3:40 PM", r.note)
        assertEquals(Level.AT, r.noteLevel)
        // Both full: the later reset is when it works again.
        assertEquals("resets Mon 9:00 AM", row(100, 100).note)
        // Full with no reset said.
        assertEquals("Limit reached", row(100, 20, fiveAt = null).note)
    }

    @Test fun aWindowWhoseResetPassedReadsEmptyWithNothingAsked() {
        val r = row(100, 61, fiveAt = at(18, 12, 0))
        assertEquals(0, r.meters[0].pct)
        assertEquals(Level.NORMAL, r.meters[0].level)
        assertNull(r.meters[0].resetsAt)
        assertEquals("Week resets Mon 9:00 AM", r.note)
    }

    @Test fun aLoginNotReadYetHasNoMetersAndNoLine() {
        val r = UsageMeters.row(AccountUsage.Login("claude", "spare", null, false, null, emptyList()), now, time)
        assertEquals("spare", r.name)
        assertEquals(emptyList<UsageMeters.Meter>(), r.meters)
        assertNull(r.note)
        assertEquals("Main", UsageMeters.row(AccountUsage.Login("codex", "main", null, true, null, emptyList()), now, time).name)
        assertEquals("Codex, Main, not read yet", UsageMeters.spoken(UsageMeters.row(AccountUsage.Login("codex", "main", null, true, null, emptyList()), now, time), "Codex"))
    }

    @Test fun aChatsSheetShowsItsOwnLogin() {
        val snap = Json.parseToJsonElement("""{"clis":[{"provider":"claude","models":[],"effortScale":[],"usage":[
            {"login":"main","email":"ku••••@••il.com","active":true,"plan":"Max","limits":[{"kind":"5h","used":8}]},
            {"login":"ajinkya","email":"aj••••@••il.com","active":false,"plan":"Max","limits":[{"kind":"5h","used":100,"resetsAt":${at(18, 15, 40)}}]}]}]}""") as JsonObject
        val onBox = Json.parseToJsonElement("""{"provider":"claude","controls":{"login":"ajinkya"}}""") as JsonObject
        val r = UsageMeters.forChat(snap, onBox, now, time)!!
        assertEquals("aj••••@••il.com", r.name)
        assertEquals("resets 3:40 PM", r.note)
        assertEquals("main", UsageMeters.forChat(snap, Json.parseToJsonElement("""{"provider":"claude"}""") as JsonObject, now, time)?.login)
        assertNull(UsageMeters.forChat(snap, Json.parseToJsonElement("""{"provider":"codex"}""") as JsonObject, now, time))
        assertEquals(2, UsageMeters.rows(snap, now, time).size)
    }
}
