package dev.kore.phone

import dev.kore.phone.ui.FollowEnd
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A chat follows its end while the reader is there; scrolled up, nothing moves and "↓ New" shows. */
class FollowEndTest {
    private val near = 48

    @Test fun atTheEndGrowthKeepsTheEnd() {
        val f = FollowEnd(near)
        // A streaming answer grew 120 px below the view: move to the end.
        assertTrue(f.laidOut(120))
        f.cameBelow()
        assertFalse(f.jump)
        // Already at the end: nothing to do.
        assertFalse(f.laidOut(0))
        assertTrue(f.following)
    }

    @Test fun nearTheEndCountsAsTheEnd() {
        val f = FollowEnd(near)
        f.touched(); f.scrolled(30)
        assertTrue(f.following)
        // Let go a little short of the end: it settles onto it.
        assertTrue(f.released(30))
        assertTrue(f.laidOut(200))
    }

    @Test fun scrolledUpStaysAndShowsTheButton() {
        val f = FollowEnd(near)
        f.touched(); f.scrolled(400)
        assertFalse(f.released(900))
        assertFalse(f.following)
        assertFalse(f.jump)
        // Rows come below: the view stays put, the button shows.
        f.cameBelow()
        assertFalse(f.laidOut(1300))
        assertTrue(f.jump)
    }

    @Test fun theReadersFingerWins() {
        val f = FollowEnd(near)
        f.touched()
        // Content grows while the finger is down: no scroll under it.
        assertFalse(f.laidOut(200))
        f.scrolled(10)
        assertFalse(f.laidOut(200))
        assertTrue(f.released(10))
    }

    @Test fun programmaticScrollsDontStopFollowing() {
        val f = FollowEnd(near)
        // Not the reader's scroll (a layout, a smooth scroll to the end): ignored.
        f.scrolled(5000)
        assertTrue(f.following)
        assertTrue(f.laidOut(5000))
    }

    @Test fun sendOrTheButtonGoesToTheEndAndFollows() {
        val f = FollowEnd(near)
        f.touched(); f.released(2000); f.cameBelow()
        assertTrue(f.jump)
        f.toEnd()
        assertTrue(f.following)
        assertFalse(f.jump)
        // The sent message arrives below: followed.
        assertTrue(f.laidOut(80))
    }

    @Test fun reachingTheEndByScrollResumes() {
        val f = FollowEnd(near)
        f.touched(); f.released(700); f.cameBelow()
        f.touched(); f.scrolled(0)
        assertTrue(f.following)
        assertFalse(f.jump)
        assertEquals(false, f.released(0))
    }

    @Test fun contentFoldingUpToTheEndResumes() {
        val f = FollowEnd(near)
        f.touched(); f.released(300)
        assertFalse(f.following)
        // The turn ended and its steps folded: the end is in view again.
        assertFalse(f.laidOut(0))
        assertTrue(f.following)
        assertTrue(f.laidOut(60))
    }

    @Test fun resizeAtTheEndKeepsIt() {
        val f = FollowEnd(near)
        // The keyboard opened: the end slid under it.
        assertTrue(f.laidOut(260, resized = true))
        // Read above, the keyboard keeps the place, and a smaller view isn't something new.
        f.touched(); f.released(900)
        assertFalse(f.laidOut(1160, resized = true))
        assertFalse(f.jump)
    }

    @Test fun aRowGrowingBelowWhileReadingAboveShowsTheButton() {
        val f = FollowEnd(near)
        // Up the page, the streaming answer still half in view (no row came below it).
        f.touched(); f.scrolled(250); assertFalse(f.released(250))
        assertFalse(f.jump)
        // It grew: more below the view after a layout, nothing moved.
        assertFalse(f.laidOut(390))
        assertTrue(f.jump)
    }

    @Test fun theReadersOwnScrollIsntNew() {
        val f = FollowEnd(near)
        f.touched(); f.released(300)
        // Scrolled further up, by the reader or a fling: more below, but nothing came.
        f.touched(); f.scrolled(700); f.released(700)
        assertFalse(f.laidOut(700))
        assertFalse(f.jump)
    }
}
