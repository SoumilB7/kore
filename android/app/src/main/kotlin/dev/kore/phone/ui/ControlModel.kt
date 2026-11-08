package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/** What the full-control screens draw, worked out from the Mac's state without any views. */
object ControlModel {
    /** A model family ("Atlas") and its versions ("4.8", "4.7"), in the Mac's order. */
    data class Family(val name: String, val versions: List<Pair<String, String>>) {
        val ids get() = versions.map { it.first }
    }

    /** "Atlas 4.8", "Atlas 4.7", "Brook 4.6" → Atlas [4.8, 4.7], Brook [4.6]; a name without a version is its own family. */
    fun families(models: List<JsonObject>): List<Family> {
        val out = LinkedHashMap<String, MutableList<Pair<String, String>>>()
        for (m in models) {
            val id = m.str("id") ?: continue
            val name = m.str("name") ?: id
            val cut = name.lastIndexOf(' ')
            val (family, version) = if (cut > 0 && name.substring(cut + 1).firstOrNull()?.isDigit() == true)
                name.substring(0, cut) to name.substring(cut + 1) else name to ""
            out.getOrPut(family) { mutableListOf() }.add(id to version)
        }
        return out.map { (name, v) -> Family(name, v) }
    }

    /** The CLI's models for a provider, from the snapshot's `clis`. */
    fun models(snapshot: JsonObject?, provider: String?): List<JsonObject> =
        snapshot?.objs("clis")?.firstOrNull { it.str("provider") == provider }?.objs("models").orEmpty()

    /** "high" → "High". */
    fun word(s: String) = s.replaceFirstChar { it.uppercase() }

    /** One rescue line under the transcript: its words and the actions it offers. */
    data class RescueLine(val key: String, val text: String, val actions: List<String>, val warn: Boolean = false)

    /**
     * The Mac's rescue rows, word for word (TimelineRows, LiveRows, ChatEvent): a stalled turn
     * (Retry, Stop), offline, a retryable ended turn (Retry), a turn the Mac's sleep cut off
     * (Continue), and the limit's "Continues at …" or a draft that sends at the reset (×).
     */
    fun rescue(rescue: JsonObject?, time: (Long) -> String): List<RescueLine> {
        if (rescue == null) return emptyList()
        val out = ArrayList<RescueLine>()
        when (rescue.str("connection")) {
            "stalled" -> out += RescueLine("stalled", "No response · the connection may have dropped", listOf("retry", "stop"), warn = true)
            "offline" -> out += RescueLine("offline", "Offline · waiting for the network", emptyList(), warn = true)
        }
        idOf(rescue, "retryTurn")?.let { out += RescueLine("retry:$it", "The turn didn't finish", listOf("retryTurn")) }
        idOf(rescue, "sleptTurn")?.let { out += RescueLine("slept:$it", "Stopped while the Mac slept", listOf("continue")) }
        val at = long(rescue, "continuesAt")
        val sends = rescue.str("sendsAtReset")?.lineSequence()?.firstOrNull()
        if (at != null) out += RescueLine(
            "continues",
            if (sends != null) "“$sends” · sends ${time(at)}" else "Continues ${time(at)}",
            listOf("cancelContinue"),
        )
        return out
    }

    /** When the limit resets, if the chat is at one: the send-at-reset ring shows then. */
    fun limitReset(rescue: JsonObject?): Long? = rescue?.let { long(it, "limitReset") }

    private fun long(o: JsonObject, key: String): Long? = (o[key] as? JsonPrimitive)?.longOrNull
    /** A turn as an id, or an object carrying one. */
    private fun idOf(o: JsonObject, key: String): String? = o.str(key) ?: o.obj(key)?.let { it.str("turnId") ?: it.str("id") }

    /** A window's tabs in order, with the runs that share a group under its header. */
    sealed class Segment {
        data class Group(val group: JsonObject, val tabs: List<JsonObject>) : Segment()
        data class Tab(val tab: JsonObject) : Segment()
    }

    fun segments(window: JsonObject): List<Segment> {
        val groups = window.objs("groups").associateBy { it.str("id") }
        val out = ArrayList<Segment>()
        for (tab in window.objs("tabs")) {
            val g = tab.str("groupId")?.let { groups[it] }
            val last = out.lastOrNull()
            when {
                g == null -> out += Segment.Tab(tab)
                last is Segment.Group && last.group.str("id") == g.str("id") -> out[out.size - 1] = last.copy(tabs = last.tabs + tab)
                else -> out += Segment.Group(g, listOf(tab))
            }
        }
        return out
    }

    /** History's day headers: Today, This week, Earlier. */
    fun bucket(at: Long, now: Long, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): String {
        val day = java.time.Instant.ofEpochMilli(at).atZone(zone).toLocalDate()
        val today = java.time.Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return when {
            !day.isBefore(today) -> "Today"
            day.isAfter(today.minusDays(7)) -> "This week"
            else -> "Earlier"
        }
    }

    /** A recent folder's place: "~/Code" for "Code/api", "~" for a folder in home. */
    fun parentOf(path: String?): String {
        val p = path?.trim('/')?.removePrefix("~")?.trim('/') ?: return ""
        val cut = p.lastIndexOf('/')
        return if (cut <= 0) "~" else "~/" + p.substring(0, cut)
    }
}
