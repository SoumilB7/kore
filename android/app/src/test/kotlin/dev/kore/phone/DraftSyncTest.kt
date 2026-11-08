package dev.kore.phone

import dev.kore.phone.ui.DraftSync
import dev.kore.phone.ui.DraftSync.Companion.QUIET_MS
import dev.kore.phone.ui.DraftSync.Companion.SETTLE_MS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A chat's draft in step with its device's: on a virtual clock, no sleeps. */
class DraftSyncTest {
    private val sent = mutableListOf<String>()
    private val shown = mutableListOf<String>()
    private val d = DraftSync(send = { sent += it }, show = { shown += it })
    private var now = 1_000L

    /** Runs every tick due up to [ms] from now, as the composer's posted runnable would. */
    private fun advance(ms: Long) {
        val end = now + ms
        while (true) {
            val due = d.due ?: break
            if (due > end) break
            now = maxOf(now, due)
            d.tick(now)
        }
        now = end
    }

    private fun type(text: String) = d.edited(text, now)

    @Test fun typingIsSaidOnceItRestsNotPerKey() {
        for (t in listOf("h", "he", "hel", "hell", "hello")) { type(t); advance(100) }
        assertEquals(emptyList<String>(), sent)
        advance(SETTLE_MS)
        assertEquals(listOf("hello"), sent)
        // Nothing new typed: nothing more said.
        advance(10_000)
        assertEquals(listOf("hello"), sent)
        assertNull(d.due)
    }

    @Test fun leavingSaysWhatsTypedAtOnce() {
        type("half typ")
        advance(100)
        d.flush(now)
        assertEquals(listOf("half typ"), sent)
        // The settle that was waiting doesn't say it twice.
        advance(SETTLE_MS * 2)
        assertEquals(listOf("half typ"), sent)
        // Leaving with nothing new typed says nothing.
        d.flush(now)
        assertEquals(listOf("half typ"), sent)
    }

    @Test fun theDevicesDraftLoadsWhenTheChatOpens() {
        d.remote("from the mac", 3, now)
        assertEquals(listOf("from the mac"), shown)
        assertEquals("from the mac", d.text)
        // Shown, not typed: nothing goes back.
        advance(10_000)
        assertEquals(emptyList<String>(), sent)
    }

    @Test fun aRemoteChangeWhileIdleShowsLive() {
        d.remote("", 1, now)
        d.remote("mac typed this", 2, now)
        assertEquals(listOf("mac typed this"), shown)
        // The same rev again (another field of the chat moved): nothing.
        d.remote("mac typed this", 2, now)
        assertEquals(1, shown.size)
    }

    @Test fun aRemoteChangeWhileTypingNeverClobbersAndTheLastWriterWins() {
        d.remote("", 1, now)
        type("phone is typ")
        advance(200)
        d.remote("mac text", 2, now)
        // Not shown while the user types here.
        assertEquals(emptyList<String>(), shown)
        assertEquals("phone is typ", d.text)
        type("phone is typing")
        advance(SETTLE_MS)
        // The phone typed last: its text goes, the Mac's change is dropped.
        assertEquals(listOf("phone is typing"), sent)
        advance(QUIET_MS * 2)
        assertEquals(emptyList<String>(), shown)
        assertEquals("phone is typing", d.text)
    }

    @Test fun aRemoteChangeAfterTypingStopsShowsOnceQuiet() {
        d.remote("", 1, now)
        type("draft")
        advance(SETTLE_MS)
        assertEquals(listOf("draft"), sent)
        // Echo of the phone's own word: nothing.
        d.remote("draft", 2, now)
        // Then the Mac edits it, within the quiet time: held, shown once typing has rested.
        advance(300)
        d.remote("draft, edited on the mac", 3, now)
        assertEquals(emptyList<String>(), shown)
        advance(QUIET_MS)
        assertEquals(listOf("draft, edited on the mac"), shown)
    }

    @Test fun aStaleEchoNeverPutsOlderTextBack() {
        d.remote("", 1, now)
        type("abc")
        advance(SETTLE_MS)
        type("abcd")
        advance(SETTLE_MS)
        assertEquals(listOf("abc", "abcd"), sent)
        // The device's echoes arrive late and in order, long after typing rested.
        advance(QUIET_MS * 2)
        d.remote("abc", 2, now)
        d.remote("abcd", 3, now)
        advance(QUIET_MS * 2)
        assertEquals(emptyList<String>(), shown)
        assertEquals("abcd", d.text)
    }

    @Test fun sendingClearsTheDraftEverywhere() {
        d.remote("", 1, now)
        type("ship it")
        advance(SETTLE_MS)
        d.sent(now)
        assertEquals(listOf("ship it", ""), sent)
        assertEquals("", d.text)
        // A message sent before its draft was ever said: nothing to clear there.
        val other = mutableListOf<String>()
        val fresh = DraftSync(send = { other += it }, show = {})
        fresh.edited("quick", now)
        fresh.sent(now)
        assertEquals(emptyList<String>(), other)
        // A draft loaded from the device and sent as it was: cleared there.
        val loaded = mutableListOf<String>()
        val l = DraftSync(send = { loaded += it }, show = {})
        l.remote("from the mac", 4, now)
        l.sent(now)
        assertEquals(listOf(""), loaded)
    }

    @Test fun theDevicesClearShowsHere() {
        d.remote("draft", 1, now)
        // The Mac sent it: its draft is empty now.
        d.remote("", 2, now)
        assertEquals(listOf("draft", ""), shown)
        assertEquals("", d.text)
    }

    @Test fun aDraftTooLongToSendIsLeftAlone() {
        d.remote("short", 1, now)
        d.remote(null, 2, now)
        assertEquals(listOf("short"), shown)
        // An older device without the draft's count: changes by text.
        val byText = mutableListOf<String>()
        val t = DraftSync(send = {}, show = { byText += it })
        t.remote("one", null, now)
        t.remote("one", null, now)
        t.remote("two", null, now)
        assertEquals(listOf("one", "two"), byText)
    }
}
