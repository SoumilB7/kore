package dev.kore.phone.ui

import android.content.SharedPreferences

/**
 * Unread, kept by this phone alone: per chat, its last-activity time when the phone last showed
 * it. A chat first seen in a list is taken as read; one that did something since is unread until
 * its chat screen opens. Bounded: past [MAX] chats the book starts again.
 */
class SeenBook(private val prefs: SharedPreferences) : DeviceList.Seen {
    private val memory = HashMap<String, Long>()

    override fun unread(chatId: String, at: Long?): Boolean {
        at ?: return false
        val had = memory[chatId] ?: prefs.getLong(chatId, Long.MIN_VALUE).takeIf { it != Long.MIN_VALUE }
        if (had == null) {
            keep(chatId, at)
            return false
        }
        memory[chatId] = had
        return at > had
    }

    /** The chat's screen showed it as of [at]. */
    fun opened(chatId: String, at: Long?) {
        at ?: return
        if (memory[chatId] == at) return
        keep(chatId, at)
    }

    private fun keep(chatId: String, at: Long) {
        memory[chatId] = at
        val edit = prefs.edit()
        if (prefs.all.size > MAX) edit.clear()
        edit.putLong(chatId, at).apply()
    }

    companion object {
        const val MAX = 1000
    }
}
