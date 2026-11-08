package dev.kore.phone.ui

/**
 * A chat's draft kept in step with its device's (link `chat.setDraft` one way, the chat's
 * `controls.draft` / `draftRev` the other). Typing here is said once it rests ([SETTLE_MS]), and
 * at once on leave or send; the device's own changes show here while nobody types here (the last
 * writer wins; a change that came while typing waits until typing has rested [QUIET_MS]). The
 * device's echoes of what this phone said never put older text back.
 *
 * Pure: the caller passes the clock, sends with [send], shows with [show], and calls [tick] at
 * [due].
 */
class DraftSync(private val send: (String) -> Unit, private val show: (String) -> Unit) {
    /** What the composer holds. */
    var text = ""
        private set
    /** The draft as the device has it, as far as this phone knows (null: not heard yet). */
    private var said: String? = null
    private var seenRev: Int? = null
    private var seenText: String? = null
    private var editedAt = Long.MIN_VALUE / 2
    /** Typing waits to be said until then. */
    private var sayAt: Long? = null
    /** What this phone said lately: their echoes are this phone's own, not the device's change. */
    private val recent = ArrayDeque<String>()
    /** The device's change that came while typing here, shown once typing rests. */
    private var held: String? = null

    /** When [tick] is next due; null when nothing waits. */
    val due: Long?
        get() = listOfNotNull(sayAt, held?.let { editedAt + QUIET_MS }).minOrNull()

    /** The user changed the composer. */
    fun edited(text: String, now: Long) {
        this.text = text
        editedAt = now
        held = null
        sayAt = now + SETTLE_MS
    }

    fun tick(now: Long) {
        sayAt?.let { if (now >= it) flush(now) }
        val waiting = held
        if (waiting != null && sayAt == null && now - editedAt >= QUIET_MS) {
            held = null
            take(waiting)
        }
    }

    /** Says what's typed now (leaving the chat, the app going to the background). */
    fun flush(now: Long) {
        sayAt ?: return
        sayAt = null
        editedAt = now
        if (text == said) return
        say(text)
    }

    /** A message went: the draft is cleared here and on the device. */
    fun sent(now: Long) {
        text = ""
        sayAt = null
        held = null
        editedAt = now
        // Only a draft the device had (or was told) is cleared there: never one this phone didn't see.
        if (!said.isNullOrEmpty()) say("")
    }

    /** The chat's state from the device: its draft ([text] null when it isn't sent) and its count. */
    fun remote(text: String?, rev: Int?, now: Long) {
        if (text == null) return
        val moved = if (rev != null) rev != seenRev else text != seenText
        seenRev = rev
        seenText = text
        if (!moved) return
        if (text == said) {
            // This phone's own last word came back: nothing older is in flight any more.
            recent.clear()
            return
        }
        // An echo of something this phone said before its last word: stale.
        if (text in recent) return
        if (sayAt != null || now - editedAt < QUIET_MS) {
            held = text
            return
        }
        take(text)
    }

    private fun take(remote: String) {
        said = remote
        if (remote == text) return
        text = remote
        show(remote)
    }

    private fun say(value: String) {
        // Said after the device's change came: this phone's word is the last.
        held = null
        said = value
        recent.addLast(value)
        while (recent.size > RECENT_MAX) recent.removeFirst()
        send(value)
    }

    companion object {
        /** Typing rests this long before the draft is said (8 drafts/s is the link's cap). */
        /**
         * Typing is said this long after it rests (the owner's choice, 2026-11-17): a 120-character
         * message typed with pauses under 2 s goes in 2 messages (its text, then the clear on
         * Send), about 2.8 bytes a character, where 600 ms sent 12 to 14 (about 19). Send and
         * leaving the chat still say it at once.
         */
        const val SETTLE_MS = 2_000L
        /** After typing here, the device's changes wait this long. */
        const val QUIET_MS = 2_000L
        private const val RECENT_MAX = 8
    }
}
