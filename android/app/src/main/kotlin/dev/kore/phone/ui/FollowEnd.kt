package dev.kore.phone.ui

/**
 * A chat's transcript follows its end, as the Mac's does: while the reader is at the end (within
 * [near] px of it), whatever comes (streaming text, new steps, the live line, a card, a resize)
 * keeps the end in view. Once the reader scrolls up past [near], nothing moves under them; what
 * comes below shows the "↓ New" button instead, which takes them back and follows again. Only
 * the reader's own scroll stops following; reaching the end any way starts it again. Text picked
 * in the transcript holds the list as a finger does, until its toolbar closes; the reader's own
 * fold opened or closed isn't new.
 *
 * Pure: the screen tells it the gap to the end (px of content below the view) and asks it what to do.
 */
class FollowEnd(private val near: Int) {
    var following = true
        private set
    /** Something came below the view while the reader was up the page. */
    var unseen = false
        private set
    /** The reader's finger is on the list (dragging, or its fling). */
    private var finger = false
    /** Text is picked in the transcript (its toolbar is open): the handles stay on their words. */
    var picking = false
        private set
    /** The reader holds the list (a finger, or a selection): nothing scrolls it but them. */
    val holding: Boolean get() = finger || picking
    /** The next layout is the reader's own fold opened or closed: not new content. */
    private var own = false
    /** Px below the view as last seen, after a scroll or a layout: more after a layout is what came. */
    private var seenGap = 0

    /** The "↓ New" button: shown while the reader reads above and something new came below. */
    val jump: Boolean get() = !following && unseen

    /** The reader put a finger on the list. */
    fun touched() { finger = true }

    /** A selection opened ([on]) or closed in the transcript; closed, the next layout settles as usual. */
    fun picked(on: Boolean) { picking = on }

    /** The reader opened or closed a fold: what that lays out isn't new. */
    fun ownChange() { own = true }

    /**
     * The list scrolled ([gap] px left below). Only the reader's own scroll changes following:
     * near the end it follows, above it it stays put.
     */
    fun scrolled(gap: Int) {
        seenGap = gap
        if (!finger) return
        following = gap <= near
        if (following) unseen = false
    }

    /** The reader's scroll came to rest: true when it ended near the end and the list should settle onto it. */
    fun released(gap: Int): Boolean {
        if (!finger) return false
        scrolled(gap)
        finger = false
        return !picking && following && gap > 0
    }

    /** Rows came or changed below what the reader sees. */
    fun cameBelow() { if (!following) unseen = true }

    /**
     * A layout finished with [gap] px below the view: true when the list should move to the end.
     * Reading above, more below than before (a row grew or came, not a [resized] view) is new.
     * Content that shrank up to the end (a turn's steps folding) brings following back.
     */
    fun laidOut(gap: Int, resized: Boolean = false): Boolean {
        if (!following && !resized && !own && gap > seenGap) unseen = true
        own = false
        seenGap = gap
        if (holding) return false
        if (!following && gap <= 0) { following = true; unseen = false }
        return following && gap > 0
    }

    /** Opened, sent, or the "↓ New" button: to the end, and follow from there. */
    fun toEnd() {
        following = true
        unseen = false
        finger = false
    }
}
