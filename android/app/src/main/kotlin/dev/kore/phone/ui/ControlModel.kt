package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/** What the full-control screens draw, worked out from the Mac's state without any views. */
object ControlModel {
    /**
     * One row of the model picker: a family ("Atlas") and its versions as chips, newest first
     * ("5.5", "5.5 · 1M", "5", "4.8"), each with the model id it picks. A name with no number is a
     * family of one whose only chip is its name (`versionless`).
     */
    data class Family(val name: String, val versions: List<Pair<String, String>>) {
        val ids get() = versions.map { it.first }
        val versionless get() = versions.size == 1 && versions[0].second.isEmpty()
    }

    /**
     * The CLI's models as the Mac's picker groups them (`ModelFamily.group`): a display name's
     * first number is its version ("Atlas 5.5" → Atlas · 5.5, "Brook-6 Luna" → Brook Luna · 6); a
     * " · 1M"-style tail stays with the version's chip. Families in the order of their first
     * model; versions newest first. Nothing is hard-coded.
     */
    fun families(models: List<JsonObject>): List<Family> {
        data class Member(val id: String, val version: String, val label: String, val index: Int)
        val order = ArrayList<String>()
        val members = HashMap<String, MutableList<Member>>()
        val names = HashMap<String, String>()
        models.forEachIndexed { i, m ->
            val id = m.str("id") ?: return@forEachIndexed
            val name = m.str("name") ?: id
            val (whole, version) = split(name)
            val cut = whole.indexOf(" · ")
            val family = if (version != null && cut > 0) whole.substring(0, cut) else whole
            val tail = if (version != null && cut > 0) whole.substring(cut) else ""
            val key = if (version == null) "\u0000$id" else family
            if (key !in members) { order += key; names[key] = if (version == null) name else family }
            members.getOrPut(key) { mutableListOf() } += Member(id, version ?: "", if (version == null) "" else version + tail, i)
        }
        return order.map { key ->
            val sorted = members.getValue(key).sortedWith { a, b ->
                when {
                    newer(a.version, b.version) -> -1
                    newer(b.version, a.version) -> 1
                    else -> a.index - b.index
                }
            }
            Family(names.getValue(key), sorted.map { it.id to it.label })
        }
    }

    /** The family and chip the picker lights for [modelId] (the chat's model), if it's listed. */
    fun current(families: List<Family>, modelId: String?): Pair<String, String>? {
        for (f in families) f.versions.firstOrNull { it.first == modelId }?.let { return f.name to it.second }
        return null
    }

    /** A display name's family and version (the first word that is a number), as the Mac's `ModelFamily.split`. */
    fun split(name: String): Pair<String, String?> {
        fun sep(c: Char) = c == ' ' || c == '-' || c == '_'
        val pieces = ArrayList<Pair<String, String>>()
        var i = 0
        while (i < name.length) {
            var w = i
            while (w < name.length && sep(name[w])) w++
            var e = w
            while (e < name.length && !sep(name[e])) e++
            pieces += name.substring(i, w) to name.substring(w, e)
            i = e
        }
        val at = pieces.indexOfFirst { (_, word) ->
            word.isNotEmpty() && word.split('.').all { it.isNotEmpty() && it.length <= 6 && it.all { c -> c in '0'..'9' } }
        }
        if (at < 0) return name to null
        val version = pieces[at].second
        pieces.removeAt(at)
        if (at == 0 && pieces.isNotEmpty()) pieces[0] = "" to pieces[0].second
        val family = pieces.joinToString("") { it.first + it.second }.trim()
        return if (family.isEmpty()) name to null else family to version
    }

    /** Whether version [a] is newer than [b], number by number ("5.5" > "5" > "4.10" > "4.9"). */
    fun newer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val p = x.getOrElse(i) { 0 }
            val q = y.getOrElse(i) { 0 }
            if (p != q) return p > q
        }
        return false
    }

    /** One effort level in the picker's segment: whether the picked model offers it. */
    data class Effort(val level: String, val offered: Boolean)

    /** The levels both CLIs name, lowest first (the Mac's `EffortScale`). */
    private val KNOWN_EFFORTS = listOf("none", "minimal", "low", "medium", "high", "xhigh", "max")

    /**
     * The effort segment under the model rows: the CLI's whole scale (its `effortScale`, else
     * every level its models list, lowest first), each struck when [model] doesn't offer it.
     * Empty when the model takes no effort at all.
     */
    fun efforts(snapshot: JsonObject?, provider: String?, model: JsonObject?): List<Effort> {
        val offered = model?.strs("efforts").orEmpty()
        if (offered.isEmpty()) return emptyList()
        val cli = snapshot?.objs("clis")?.firstOrNull { it.str("provider") == provider }
        val listed = cli?.strs("effortScale").orEmpty().ifEmpty {
            val all = cli?.objs("models").orEmpty().flatMap { it.strs("efforts") }.distinct()
            if (all.all { it in KNOWN_EFFORTS }) all.sortedBy { KNOWN_EFFORTS.indexOf(it) } else all
        }
        val scale = listed.ifEmpty { offered }
        return scale.map { Effort(it, it in offered) }
    }

    /** The level a newly picked model takes: the current one if offered, else the nearest below, else its lowest. */
    fun effortFallback(current: String?, offered: List<String>, scale: List<String>): String? {
        if (current == null || offered.isEmpty()) return null
        if (current in offered) return current
        fun rank(l: String) = scale.indexOf(l).let { if (it < 0) Int.MAX_VALUE else it }
        val sorted = offered.sortedBy(::rank)
        val at = scale.indexOf(current)
        if (at < 0) return sorted[0]
        return sorted.lastOrNull { rank(it) < at } ?: sorted[0]
    }

    /** The composer's model chip: the model's name and its effort ("Atlas 5.5 · high"). */
    fun modelChip(models: List<JsonObject>, modelId: String?, fallbackName: String?, effort: String?): String? {
        val name = models.firstOrNull { it.str("id") == modelId }?.str("name") ?: fallbackName ?: return null
        return if (effort.isNullOrEmpty()) name else "$name · $effort"
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
