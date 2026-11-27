package dev.kore.phone.ui

import android.content.SharedPreferences

/**
 * Pins, kept by this phone alone: per device, the chats pinned there, by [DeviceList.pinKeys]'
 * keys (a session's "s:…" or a chat's "c:…"), with when each was pinned. One entry per pin,
 * "<device> <key>", so a later sync through the Mac can send them as they are. Bounded: past [MAX]
 * pins the oldest go.
 */
class PinBook(private val prefs: SharedPreferences) {
    /** [device]'s pins, as a list asks. */
    fun of(device: String?): DeviceList.Pins =
        if (device == null) DeviceList.Pins.NONE else DeviceList.Pins { key -> prefs.contains(entry(device, key)) }

    /** Pinned by any of [keys] on [device]. */
    fun pinned(device: String?, keys: List<String>): Boolean = device != null && keys.any { prefs.contains(entry(device, it)) }

    /** Pins it by its first key, or unpins it by every key it has. */
    fun set(device: String, keys: List<String>, on: Boolean, now: Long = System.currentTimeMillis()) {
        val first = keys.firstOrNull() ?: return
        val edit = prefs.edit()
        if (on) {
            if (prefs.contains(entry(device, first))) return
            val all = prefs.all.filterValues { it is Long }
            if (all.size >= MAX) all.entries.sortedBy { it.value as Long }.take(all.size - MAX + 1).forEach { edit.remove(it.key) }
            edit.putLong(entry(device, first), now)
        } else {
            keys.forEach { edit.remove(entry(device, it)) }
        }
        edit.apply()
    }

    /** "Pin" or "Unpin", for a menu. */
    fun word(device: String?, keys: List<String>) = if (pinned(device, keys)) "Unpin" else "Pin"

    private fun entry(device: String, key: String) = "$device $key"

    companion object {
        const val MAX = 500
    }
}
