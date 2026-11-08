package dev.kore.phone.ui

import dev.kore.link.node.AccountUsage
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * A login's usage as the phone shows it (link 1.14 `clis[].usage`), worked out without views: a
 * thin meter per window (5 h, then the week), amber from 80 %, red at the limit, and one line for
 * the reset that matters ("resets 3:40 PM", as the Mac's usage mark says it). Only what the node
 * pushed: a window whose reset has passed reads empty, with nothing asked.
 */
object UsageMeters {
    enum class Level { NORMAL, NEAR, AT }

    /** From here a meter turns amber (the Mac's usage mark starts at 80 too). */
    const val NEAR = 80
    const val AT = 100

    data class Meter(val kind: String, val label: String, val pct: Int, val level: Level, val resetsAt: Long?)

    /** One login's row: who ([name], [plan]), its meters, and the reset line ([note]) in [noteLevel]'s colour. */
    data class Row(
        val provider: String,
        val login: String,
        val name: String,
        val plan: String?,
        val active: Boolean,
        val meters: List<Meter>,
        val note: String?,
        val noteLevel: Level,
    )

    fun level(pct: Int): Level = when {
        pct >= AT -> Level.AT
        pct >= NEAR -> Level.NEAR
        else -> Level.NORMAL
    }

    fun label(kind: String): String = when (kind) {
        AccountUsage.FIVE_HOUR -> "5 h"
        AccountUsage.WEEK -> "Week"
        else -> kind
    }

    /** A window as it stands at [now]: one whose reset has passed is empty until the node says more. */
    fun meter(limit: AccountUsage.Limit, now: Long): Meter {
        val reset = limit.resetsAt?.takeIf { it > now }
        val pct = if (limit.resetsAt != null && reset == null) 0 else limit.used.coerceAtLeast(0)
        return Meter(limit.kind, label(limit.kind), pct, level(pct), reset)
    }

    /** "3:40 PM" today, else "Mon 9:00 AM" (the Mac's `StayAwake.time`). */
    fun time(at: Long, now: Long, zone: ZoneId = ZoneId.systemDefault(), clock: DateTimeFormatter = DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault())): String {
        val t = Instant.ofEpochMilli(at).atZone(zone)
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val c = clock.format(t)
        return if (t.toLocalDate() == today) c else DateTimeFormatter.ofPattern("EEE", clock.locale).format(t) + " " + c
    }

    /**
     * The one reset worth saying: at a limit, when it's usable again ("resets 3:40 PM", red: the
     * latest of the full windows); else the fullest window's ("5 h resets 3:40 PM"), amber near
     * its limit, faint below. Null with nothing read.
     */
    fun note(meters: List<Meter>, now: Long, time: (Long) -> String = { time(it, now) }): Pair<String?, Level> {
        val full = meters.filter { it.level == Level.AT }
        if (full.isNotEmpty()) {
            val at = full.mapNotNull { it.resetsAt }.maxOrNull() ?: return "Limit reached" to Level.AT
            return "resets ${time(at)}" to Level.AT
        }
        // The fullest window; a tie goes to the week (it waits longer to reset).
        val top = meters.filter { it.resetsAt != null }.maxWithOrNull(compareBy<Meter> { it.pct }.thenBy { it.kind == AccountUsage.WEEK }) ?: return null to Level.NORMAL
        return "${top.label} resets ${time(top.resetsAt!!)}" to top.level
    }

    fun row(login: AccountUsage.Login, now: Long, time: (Long) -> String = { time(it, now) }): Row {
        val meters = listOf(AccountUsage.FIVE_HOUR, AccountUsage.WEEK).mapNotNull { k -> login.limits.firstOrNull { it.kind == k }?.let { meter(it, now) } }
        val (note, level) = note(meters, now, time)
        val name = login.email ?: if (login.login == "main") "Main" else login.login
        return Row(login.provider, login.login, name, login.plan, login.active, meters, note, level)
    }

    /** Every login the node pushed, CLI by CLI as it sends them. */
    fun rows(snapshot: kotlinx.serialization.json.JsonObject?, now: Long, time: (Long) -> String = { time(it, now) }): List<Row> =
        AccountUsage.of(snapshot).map { row(it, now, time) }

    /** The login a chat runs on, or null when the node pushes none for it. */
    fun forChat(snapshot: kotlinx.serialization.json.JsonObject?, chat: kotlinx.serialization.json.JsonObject?, now: Long, time: (Long) -> String = { time(it, now) }): Row? =
        AccountUsage.forChat(snapshot, chat)?.let { row(it, now, time) }

    /** What TalkBack reads for a row: "Claude, ku••••@••il.com, Max, 5 h 42 %, Week 81 %, Week resets Mon 9:00 AM". */
    fun spoken(row: Row, cli: String): String =
        (listOf(cli, row.name) + listOfNotNull(row.plan) + row.meters.map { "${it.label} ${it.pct} %" } + listOfNotNull(row.note ?: "not read yet")).joinToString(", ")
}
