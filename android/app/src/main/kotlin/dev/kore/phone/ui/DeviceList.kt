package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.longOrNull

/**
 * The Device screen as one list, newest first (option B of phone-device-screen.html), worked out
 * from the device's state without views: a row per chat or board across its windows, two lines
 * each (title and age; then the one thing that matters: it needs you, it's working, or its last
 * word), the windows as filter chips when there is more than one. Idle says nothing.
 */
object DeviceList {
    /** A row's one cue, which takes its second line's place. */
    enum class Cue { NONE, NEEDS, WORKING, FAILED }

    /** A window as a filter chip; [chats] 0 is an empty window (an outlined chip, a tap opens it). */
    data class Chip(val windowId: String, val name: String, val chats: Int)

    /** One row. Equal rows draw the same: the list rebinds only rows that changed. */
    data class Row(
        val key: String,
        val chatId: String?,
        val windowId: String?,
        val boardIds: List<String>?,
        val title: String,
        val provider: String?,
        val age: String,
        val line: String,
        val cue: Cue,
        val unread: Boolean,
        /** Link 1.13: what it waits on in the background (symbols on its second line). */
        val waiting: Waiting? = null,
    )

    /** Which chats moved since this phone last showed them: unread (its own record, nothing on the wire). */
    interface Seen {
        /** Whether a chat that last did something at [at] is unread; a chat first seen is not. */
        fun unread(chatId: String, at: Long?): Boolean
    }

    /** The windows, in the device's order, each with its chats' count. */
    fun chips(snapshot: JsonObject): List<Chip> {
        val chats = snapshot.objs("chats")
        return snapshot.objs("windows").mapNotNull { w ->
            val id = w.str("id") ?: return@mapNotNull null
            Chip(id, w.str("name") ?: "Window", chatsIn(w, chats).size + boardsIn(w).size)
        }
    }

    /**
     * The rows of [window] (null: every window), needs-you first, then working, then the most
     * recent; a chat in a board is shown by its board's row.
     */
    fun rows(snapshot: JsonObject, window: String?, now: Long, seen: Seen): List<Row> {
        val chats = snapshot.objs("chats")
        val byId = chats.associateBy { it.str("id") }
        val windows = snapshot.objs("windows")
        val many = window == null && windows.size > 1
        data class Made(val row: Row, val rank: Int, val at: Long, val order: Int)
        val made = ArrayList<Made>()
        for (w in windows) {
            val wid = w.str("id") ?: continue
            if (window != null && wid != window) continue
            val prefix = if (many) "${w.str("name") ?: "Window"} · " else ""
            for (chat in chatsIn(w, chats)) {
                val id = chat.str("id") ?: continue
                val at = lastAt(chat)
                val waiting = Waiting.of(chat)
                // Background work keeps it working between turns (link 1.13).
                val cue = cue(chat.str("state")).let { if (it == Cue.NONE && waiting != null) Cue.WORKING else it }
                val line = when (cue) {
                    Cue.NEEDS -> chat.objs("cards").firstOrNull()?.str("title")?.let { firstLine(it) } ?: "Needs you"
                    Cue.WORKING -> "Working"
                    Cue.FAILED -> if (chat.str("state") == "stuck") "Stuck" else "Failed"
                    Cue.NONE -> prefix + (chat.str("last") ?: "")
                }.let { if (cue != Cue.NONE && many) prefix + it else it }.trimEnd(' ', '·')
                val row = Row(
                    key = "c:$id", chatId = id, windowId = wid, boardIds = null, title = chat.str("title") ?: "Chat",
                    provider = chat.str("provider"), age = if (cue == Cue.WORKING) "now" else age(at, now), line = line, cue = cue,
                    unread = cue == Cue.NONE && seen.unread(id, at), waiting = waiting,
                )
                made += Made(row, rank(cue), at ?: Long.MIN_VALUE, made.size)
            }
            for (board in boardsIn(w)) {
                val ids = board.obj("board")?.objs("sections").orEmpty().flatMap { it.strs("chatIds") }
                val members = ids.mapNotNull { byId[it] }
                val states = members.map { m -> cue(m.str("state")).let { if (it == Cue.NONE && Waiting.of(m) != null) Cue.WORKING else it } }
                val cue = states.minByOrNull(::rank) ?: Cue.NONE
                val at = members.mapNotNull(::lastAt).maxOrNull()
                val count = if (ids.size == 1) "1 chat" else "${ids.size} chats"
                val line = prefix + when (cue) {
                    Cue.NEEDS -> "$count · needs you"
                    Cue.WORKING -> "$count · working"
                    Cue.FAILED -> "$count · failed"
                    Cue.NONE -> count
                }
                val row = Row(
                    key = "b:${board.str("id")}", chatId = null, windowId = wid, boardIds = ids, title = "▦  " + (board.str("title") ?: "Board"),
                    provider = null, age = if (cue == Cue.WORKING) "now" else age(at, now), line = line, cue = cue, unread = false,
                )
                made += Made(row, rank(cue), at ?: Long.MIN_VALUE, made.size)
            }
        }
        return made.sortedWith(compareBy<Made> { it.rank }.thenByDescending { it.at }.thenBy { it.order }).map { it.row }
    }

    /** "now", "4 m", "2 h", "yesterday", "3 d"; nothing when the time isn't known. */
    fun age(at: Long?, now: Long): String {
        at ?: return ""
        val m = (now - at) / 60_000
        return when {
            m < 1 -> "now"
            m < 60 -> "$m m"
            m < 24 * 60 -> "${m / 60} h"
            m < 48 * 60 -> "yesterday"
            else -> "${m / 1440} d"
        }
    }

    private fun rank(cue: Cue) = when (cue) {
        Cue.NEEDS -> 0
        Cue.WORKING -> 1
        Cue.FAILED -> 2
        Cue.NONE -> 3
    }

    private fun cue(state: String?) = when (state) {
        "needsYou" -> Cue.NEEDS
        "working" -> Cue.WORKING
        "failed", "stuck" -> Cue.FAILED
        else -> Cue.NONE
    }

    private fun lastAt(chat: JsonObject): Long? = (chat["lastAt"] as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull

    private fun firstLine(s: String) = s.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: s

    /** A window's chats: its chat tabs on a Mac; on a box, the chats that name the window. */
    private fun chatsIn(w: JsonObject, chats: List<JsonObject>): List<JsonObject> {
        val byId = chats.associateBy { it.str("id") }
        val tabs = w.objs("tabs").filter { it.str("kind") == "chat" || it.str("kind") == "agent" }.mapNotNull { byId[it.str("chatId")] }
        if (tabs.isNotEmpty() || w.objs("tabs").any { it.str("kind") == "board" }) return tabs
        return chats.filter { it.str("windowId") == w.str("id") }
    }

    private fun boardsIn(w: JsonObject) = w.objs("tabs").filter { it.str("kind") == "board" }
}
