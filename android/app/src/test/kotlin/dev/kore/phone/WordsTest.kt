package dev.kore.phone

import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.State
import dev.kore.phone.ui.lastSeenWords
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
        assertEquals("● Offline · retrying", stateWords(State.Away(NodeMachine.AwayWhy.UNREACHABLE, 1, null)).first)
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

    @Test fun aMacWhoseKoreNetWentOffOffersTryAgain() {
        assertEquals(RowAction.TRY_AGAIN, troubleWords(State.Denied("refused"), true, "MacBook", "MacBook")?.action)
        assertEquals("KoreNet is off on MacBook · Try again", troubleWords(State.Denied("refused"), true, "MacBook", "MacBook")?.fact)
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
}
