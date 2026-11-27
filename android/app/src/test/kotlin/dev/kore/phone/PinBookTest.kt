package dev.kore.phone

import android.content.SharedPreferences
import dev.kore.phone.ui.PinBook
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins: this phone's own, per device, by a chat's keys, bounded. */
class PinBookTest {
    /** SharedPreferences in memory, as much as the book uses. */
    private class Prefs : SharedPreferences {
        val map = LinkedHashMap<String, Any?>()
        override fun getAll(): MutableMap<String, *> = LinkedHashMap(map)
        override fun getString(key: String?, defValue: String?) = map[key] as? String ?: defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?) = defValues
        override fun getInt(key: String?, defValue: Int) = map[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long) = map[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float) = map[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean) = map[key] as? Boolean ?: defValue
        override fun contains(key: String?) = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            val put = LinkedHashMap<String, Any?>()
            val gone = HashSet<String>()
            var clear = false
            override fun putString(key: String, value: String?) = apply { put[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { put[key] = values }
            override fun putInt(key: String, value: Int) = apply { put[key] = value }
            override fun putLong(key: String, value: Long) = apply { put[key] = value }
            override fun putFloat(key: String, value: Float) = apply { put[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { put[key] = value }
            override fun remove(key: String) = apply { gone += key }
            override fun clear() = apply { clear = true }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                if (clear) map.clear()
                gone.forEach { map.remove(it) }
                map.putAll(put)
            }
        }
    }

    @Test fun aPinIsPerDevice() {
        val book = PinBook(Prefs())
        book.set("mac", listOf("s:a", "c:1"), true)
        assertTrue(book.of("mac").pinned("s:a"))
        assertTrue(book.pinned("mac", listOf("s:a")))
        assertFalse(book.pinned("mybox", listOf("s:a")))
        assertFalse(book.of(null).pinned("s:a"))
        assertEquals("Unpin", book.word("mac", listOf("s:a", "c:1")))
        assertEquals("Pin", book.word("mybox", listOf("s:a")))
    }

    /** Pinned by the first key; unpinned by every key, so a pin made before the session goes too. */
    @Test fun unpinTakesEveryKey() {
        val prefs = Prefs()
        val book = PinBook(prefs)
        book.set("mac", listOf("c:1"), true)
        assertTrue(book.pinned("mac", listOf("s:a", "c:1")))
        book.set("mac", listOf("s:a", "c:1"), false)
        assertFalse(book.pinned("mac", listOf("s:a", "c:1")))
        assertTrue(prefs.map.isEmpty())
    }

    @Test fun pastTheBoundTheOldestGo() {
        val prefs = Prefs()
        val book = PinBook(prefs)
        for (i in 0 until PinBook.MAX) book.set("mac", listOf("s:$i"), true, now = i.toLong())
        book.set("mac", listOf("s:new"), true, now = 10_000)
        assertEquals(PinBook.MAX, prefs.map.size)
        assertFalse(book.pinned("mac", listOf("s:0")))
        assertTrue(book.pinned("mac", listOf("s:1")) && book.pinned("mac", listOf("s:new")))
    }
}
