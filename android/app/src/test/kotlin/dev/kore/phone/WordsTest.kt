package dev.kore.phone

import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.State
import dev.kore.phone.ui.arsenalTint
import dev.kore.phone.ui.awayFact
import dev.kore.phone.ui.awayLine
import dev.kore.phone.ui.lastSeenWords
import dev.kore.phone.ui.shownState
import dev.kore.phone.ui.RowAction
import dev.kore.phone.ui.Trouble
import dev.kore.phone.ui.refusalWords
import dev.kore.phone.ui.stateWords
import dev.kore.phone.ui.troubleWords
import org.junit.Assert.assertEquals
import org.junit.Test

/** The one-line words screens show for a device's state and a refused command. */
class WordsTest {
    @Test fun lastSeen() {
        val now = 10_000_000_000L
        assertEquals(null, lastSeenWords(null, now))
        assertEquals("last seen just now", lastSeenWords(now - 30_000, now))
        assertEquals("last seen 12 min ago", lastSeenWords(now - 12 * 60_000, now))
        assertEquals("last seen 2 h ago", lastSeenWords(now - 2 * 3_600_000, now))
        assertEquals("last seen 3 days ago", lastSeenWords(now - 3 * 86_400_000L, now))
    }

    @Test fun statePillIsQuietWhileUp() {
        assertEquals("", stateWords(State.Up).first)
        assertEquals("● Reconnecting", stateWords(State.Connecting).first)
        assertEquals("● Asleep", stateWords(State.Away(NodeMachine.AwayWhy.ASLEEP, null, null)).first)
        assertEquals("● Not answering", stateWords(State.Away(NodeMachine.AwayWhy.UNREACHABLE, 1, null)).first)
        assertEquals("● Offline", stateWords(State.Away(NodeMachine.AwayWhy.OFFLINE, 1, null)).first)
        assertEquals("● Taken offline", stateWords(State.Away(NodeMachine.AwayWhy.OFF, null, null)).first)
        assertEquals("● Waiting for Mac mini", stateWords(State.Away(NodeMachine.AwayWhy.WAITING, 1, null), "Mac mini").first)
        assertEquals("● Not allowed", stateWords(State.Denied("unknown")).first)
        assertEquals("● Signed out", stateWords(State.SignedOut).first)
    }

    @Test fun aRemovedDeviceOffersJoinAgain() {
        assertEquals(Trouble("Removed on MacBook · Join again", "● Removed · Join again", RowAction.JOIN_AGAIN), troubleWords(State.Removed, true, "MacBook", "MacBook"))
        assertEquals("Removed on MacBook · Join again", troubleWords(State.Removed, false, "mybox", "MacBook")?.fact)
    }

    @Test fun aMacThatDoesntHoldThisPhoneOffersAskAgain() {
        assertEquals(Trouble("Not allowed · Ask again", "● Not allowed · Ask again", RowAction.ASK_AGAIN), troubleWords(State.Denied("unknown"), true, "MacBook", "MacBook"))
    }

    @Test fun aDenyOnTheAllowCardIsNotAllowedNotKoreNetOff() {
        assertEquals(RowAction.ASK_AGAIN, troubleWords(State.Denied("refused"), true, "MacBook", "MacBook")?.action)
    }

    @Test fun aBoxThatDoesntHoldThisPhoneYetWaitsForTheMac() {
        assertEquals(Trouble("waiting for MacBook", "● Waiting for MacBook", null), troubleWords(State.Denied("unknown"), false, "mybox", "MacBook"))
    }

    @Test fun aReachableDeviceHasNoTrouble() {
        assertEquals(null, troubleWords(State.Up, true, "MacBook", "MacBook"))
        assertEquals(null, troubleWords(State.Away(NodeMachine.AwayWhy.ASLEEP, null, null), true, "MacBook", "MacBook"))
    }

    @Test fun refusalsAreOneDeviceNeutralLine() {
        assertEquals("That mode needs your fingerprint.", refusalWords("denied.raiseMode"))
        assertEquals("Not sent: connection lost.", refusalWords("expired"))
        assertEquals("That's no longer there.", refusalWords("gone.chat"))
        assertEquals("Not done (weird).", refusalWords("weird"))
    }

    /** A device's own words win: every `invalid` used to read "Kore there doesn't take that yet". */
    @Test fun refusalsSayTheDevicesOwnWordsWhenItGivesThem() {
        assertEquals("A box doesn't do that.", refusalWords("invalid", "A box doesn't do that."))
        assertEquals("Leaving plan raises the mode; do it in Kore.", refusalWords("denied.raiseMode", "Leaving plan raises the mode; do it in Kore."))
        assertEquals("That chat isn't on the box any more.", refusalWords("gone.chat", "  That chat isn't on the box any more. "))
        // None, or only blanks: the code's line.
        assertEquals("Kore there doesn't take that yet.", refusalWords("invalid", null))
        assertEquals("Kore there doesn't take that yet.", refusalWords("invalid", "  "))
        assertEquals("Too fast. Try again in a moment.", refusalWords("rateLimited", ""))
        assertEquals("That wasn't done.", refusalWords(null, null))
        // An older Mac's or box's terse words: the code's line reads better.
        assertEquals("Kore there doesn't take that yet.", refusalWords("invalid", "Not taken here."))
        assertEquals("Kore there doesn't take that yet.", refusalWords("invalid", "Unknown command."))
        assertEquals("The box's kore-host needs an update for that.", refusalWords("invalid", "The box's kore-host needs an update for that."))
    }

    /** The live bug's words: a box is never "asleep"; each surface tells one story. */
    @Test fun aBoxIsNeverAsleepAndEverySurfaceSaysTheSame() {
        val now = 10_000_000_000L
        val seen = now - 2 * 60_000
        assertEquals("offline · last seen 2 min ago", awayFact(NodeMachine.AwayWhy.OFFLINE, "mybox", "MacBook", seen, now))
        assertEquals("mybox is offline · last seen 2 min ago" to true, awayLine(NodeMachine.AwayWhy.OFFLINE, "mybox", "MacBook", seen, now))
        assertEquals("not answering", awayFact(NodeMachine.AwayWhy.UNREACHABLE, "mybox", "MacBook", seen, now))
        assertEquals("mybox isn't answering" to true, awayLine(NodeMachine.AwayWhy.UNREACHABLE, "mybox", "MacBook", seen, now))
        assertEquals("asleep · last seen 2 min ago", awayFact(NodeMachine.AwayWhy.ASLEEP, "MacBook", "MacBook", seen, now))
    }

    /** A5: taken offline names the Mac that did it, and offers nothing only the Mac can do. */
    @Test fun takenOfflineNamesTheMac() {
        assertEquals("taken offline on Mac mini", awayFact(NodeMachine.AwayWhy.OFF, "gpu", "Mac mini", null))
        assertEquals("Mac mini took this phone offline · Bring it online in Devices there" to false, awayLine(NodeMachine.AwayWhy.OFF, "gpu", "Mac mini", null))
    }

    /** B1: the seconds the tailnet takes on opening read as connecting, never "off". */
    @Test fun idleWithKoreNetOnReadsAsConnecting() {
        assertEquals(State.Connecting, shownState(State.Idle, networkOn = true))
        assertEquals(State.Idle, shownState(State.Idle, networkOn = false))
        assertEquals(State.Up, shownState(State.Up, networkOn = true))
    }

    /** The Arsenal mark's tier colours are the Mac's, Full included. */
    @Test fun arsenalTiersMatchTheMac() {
        assertEquals(0xFFA3C3DC.toInt(), arsenalTint("watch"))
        assertEquals(0xFF3C97DD.toInt(), arsenalTint("own"))
        assertEquals(0xFF6AB1E7.toInt(), arsenalTint("drive"))
        assertEquals(0xFF257DC1.toInt(), arsenalTint("device"))
        assertEquals(0xFFE1C08D.toInt(), arsenalTint("full"))
    }
}
