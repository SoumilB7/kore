package dev.kore.link

import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.AwayWhy
import dev.kore.link.node.NodeMachine.Event
import dev.kore.link.node.NodeMachine.State
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeMachineTest {
    /** No jitter: nextDouble() is 0.5, so a delay is exactly its base. */
    private fun machine(box: Boolean = false) = NodeMachine(object : Random() {
        override fun nextBits(bitCount: Int) = 0
        override fun nextDouble() = 0.5
    }, box = box)

    @Test fun aBoxThatDoesntHoldThePhoneYetWaitsAndTriesAgainUpToAMinute() {
        val m = machine(box = true)
        m.on(Event.Start, 0)
        val delays = (1..9).map {
            val s = m.on(Event.Ended("unknown"), 0) as State.Away
            assertEquals(AwayWhy.WAITING, s.why)
            m.on(Event.Tick, s.at!!)
            s.at
        }
        assertEquals(listOf(1_000L, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000), delays)
    }

    @Test fun aRestartingNodeIsTriedAtOneTwoAndFiveSecondsThenTheUsualBackoff() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Connected, 0)
        var s = m.on(Event.Ended("restart"), 0) as State.Away
        assertEquals(AwayWhy.UNREACHABLE, s.why)
        val delays = mutableListOf(s.at!!)
        repeat(4) {
            m.on(Event.Tick, s.at!!)
            s = m.on(Event.Failed, s.at!!) as State.Away
            delays += s.at!! - delays.sum()
        }
        assertEquals(listOf(1_000L, 2_000, 5_000, 1_000, 2_000), delays)
        // Up again: a later restart starts from one second again; a stop still waits long.
        m.on(Event.Tick, s.at!!)
        m.on(Event.Connected, 20_000)
        assertEquals(21_000L, (m.on(Event.Ended("restart"), 20_000) as State.Away).at)
        m.on(Event.Tick, 21_000)
        m.on(Event.Connected, 21_000)
        assertEquals(AwayWhy.UNREACHABLE, (m.on(Event.Ended("quit"), 21_000) as State.Away).why)
        m.on(Event.Trigger, 22_000)
        m.on(Event.Connected, 22_000)
        // Only a Mac's `bye sleep` is asleep, and it's tried again on the cap.
        val asleep = m.on(Event.Ended("sleep"), 22_000) as State.Away
        assertEquals(AwayWhy.ASLEEP, asleep.why)
        assertNotNull(asleep.at)
    }

    /** S35: the Mac's KoreNet switched off is not a refusal: the phone says so and comes back by itself. */
    @Test fun aMacWhoseKoreNetWentOffIsTriedAgainUpToAMinuteAndComesBack() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Connected, 0)
        var s = m.on(Event.Ended("off"), 0) as State.Away
        assertEquals(AwayWhy.NET_OFF, s.why)
        // Its dials refused meanwhile (no port) stay "KoreNet is off", capped at a minute.
        val delays = mutableListOf(s.at!!)
        repeat(8) {
            m.on(Event.Tick, s.at!!)
            s = m.on(Event.Failed, s.at!!) as State.Away
            assertEquals(AwayWhy.NET_OFF, s.why)
            delays += s.at!! - delays.sum()
        }
        assertEquals(listOf(1_000L, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000), delays)
        // Switched on: the next dial is up, and a later unreachable Mac backs off as before.
        m.on(Event.Tick, s.at!!)
        assertEquals(State.Up, m.on(Event.Connected, s.at!!))
        m.on(Event.Ended(null), s.at!!)
        m.on(Event.Tick, m.wakeAt!!)
        assertEquals(AwayWhy.UNREACHABLE, (m.on(Event.Failed, m.wakeAt ?: 0) as State.Away).why)
    }

    @Test fun offScreenAMacWhoseKoreNetWentOffWaitsForTheAppOrTheNetwork() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Connected, 0)
        m.on(Event.Screen(false), 0)
        val s = m.on(Event.Ended("off"), 0) as State.Away
        assertEquals(AwayWhy.NET_OFF, s.why)
        assertNull(s.at)
        assertNull(m.wakeAt)
        // The app opening or a network change (a trigger) dials it.
        assertEquals(State.Connecting, m.on(Event.Trigger, 5))
        // Gone off screen while waiting: its timer goes.
        m.on(Event.Screen(true), 6)
        assertEquals(1_000L + 6, (m.on(Event.Failed, 6) as State.Away).at)
        assertNull((m.on(Event.Screen(false), 7) as State.Away).at)
    }

    @Test fun theOwnersDenyIsStillDenied() {
        val m = machine()
        m.on(Event.Start, 0)
        assertEquals(State.Denied("refused"), m.on(Event.Ended("refused"), 0))
    }

    @Test fun offScreenAWaitingBoxWaitsForATriggerOnly() {
        val m = machine(box = true)
        m.on(Event.Start, 0)
        assertEquals(1_000L, (m.on(Event.Ended("unknown"), 0) as State.Away).at)
        assertNull((m.on(Event.Screen(false), 1) as State.Away).at)
        assertNull(m.wakeAt)
        assertEquals(State.Connecting, m.on(Event.Trigger, 2))
        assertNull((m.on(Event.Ended("unknown"), 3) as State.Away).at)
        m.on(Event.Screen(true), 4)
        assertEquals(State.Connecting, m.on(Event.Trigger, 5))
        assertEquals(1_005L, (m.on(Event.Ended("unknown"), 5) as State.Away).at)
    }

    @Test fun aBoxStillDeniesRefusedAndAMacThatForgotThisPhoneRemovedIt() {
        fun after(box: Boolean, reason: String): State = machine(box).apply { on(Event.Start, 0) }.on(Event.Ended(reason), 0)
        assertEquals(State.Denied("refused"), after(true, "refused"))
        assertEquals(State.Removed, after(false, "unknown"))
    }

    @Test fun startDialsAndConnectedIsUp() {
        val m = machine()
        assertEquals(State.Connecting, m.on(Event.Start, 0))
        assertEquals(State.Up, m.on(Event.Connected, 10))
    }

    @Test fun failuresBackOffAndDoubleUpToTheCap() {
        val m = machine()
        m.on(Event.Start, 0)
        val delays = (1..12).map {
            val s = m.on(Event.Failed, 0) as State.Away
            assertEquals(AwayWhy.UNREACHABLE, s.why)
            m.on(Event.Tick, s.at!!)
            s.at
        }
        assertEquals(listOf(1_000L, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 256_000, 300_000, 300_000, 300_000), delays)
    }

    @Test fun aTickBeforeItsTimeWaits() {
        val m = machine()
        m.on(Event.Start, 0)
        val away = m.on(Event.Failed, 0) as State.Away
        assertEquals(away, m.on(Event.Tick, 999))
        assertEquals(1_000L, m.wakeAt)
        assertEquals(State.Connecting, m.on(Event.Tick, 1_000))
    }

    @Test fun aTriggerOrThePeerComingOnlineTriesAtOnceWithTheBackoffReset() {
        val m = machine()
        m.on(Event.Start, 0)
        repeat(4) { m.on(Event.Failed, 0); m.on(Event.Tick, Long.MAX_VALUE / 2) }
        m.on(Event.Failed, 0)
        assertEquals(State.Connecting, m.on(Event.Trigger, 5))
        assertEquals(1_005L, (m.on(Event.Failed, 5) as State.Away).at)
        assertEquals(State.Connecting, m.on(Event.PeerOnline, 6))
    }

    /** The live bug: a box the tailnet listed offline was "Asleep" with no timer, and never dialed again. */
    @Test fun offlinePeersAreTriedAgainByBackoffNeverLeftAsleep() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Connected, 50)
        m.on(Event.Ended(null), 100)
        m.on(Event.Tick, m.wakeAt!!)
        val s = m.on(Event.PeerOffline, 2_000) as State.Away
        assertEquals(AwayWhy.OFFLINE, s.why)
        assertEquals(50L, s.lastSeen)
        assertNotNull(m.wakeAt)
        assertEquals(State.Connecting, m.on(Event.Tick, m.wakeAt!!))
        // Each further offline backs off, capped, never without a timer.
        var at = m.wakeAt ?: 0L
        repeat(20) { m.on(Event.PeerOffline, at); at = m.wakeAt!!; m.on(Event.Tick, at) }
        val last = m.on(Event.PeerOffline, at) as State.Away
        assertTrue(last.at!! - at <= NodeMachine.CAP_MS * 12 / 10)
    }

    @Test fun byesMapToStates() {
        fun after(reason: String?): State = machine().apply { on(Event.Start, 0); on(Event.Connected, 0) }.on(Event.Ended(reason), 0)
        assertEquals(State.Removed, after("revoked"))
        assertEquals(State.Removed, after("unknown"))
        assertEquals(State.Denied("refused"), after("refused"))
        assertEquals(AwayWhy.OFF, (after("paused") as State.Away).why)
        assertEquals(300_000L, (after("quit") as State.Away).at)
        assertEquals(State.Connecting, after("abandoned"))
        assertEquals(1_000L, (after(null) as State.Away).at)
        assertEquals(1_000L, (after("replaced") as State.Away).at)
    }

    @Test fun removedStaysRemoved() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Ended("revoked"), 0)
        for (e in listOf(Event.Trigger, Event.PeerOnline, Event.Tick, Event.Failed, Event.Ended(null))) assertEquals(State.Removed, m.on(e, 1))
    }

    @Test fun allowedAgainStartsOverFromRemovedOrDenied() {
        for (bye in listOf("revoked", "refused", "quit")) {
            val m = machine()
            m.on(Event.Start, 0)
            m.on(Event.Connected, 0)
            m.on(Event.Ended(bye), 0)
            assertEquals(State.Connecting, m.on(Event.Allowed, 1))
            assertEquals(State.Up, m.on(Event.Connected, 2))
        }
        val up = machine().apply { on(Event.Start, 0); on(Event.Connected, 0) }
        assertEquals(State.Up, up.on(Event.Allowed, 1))
        assertEquals(State.Idle, machine().on(Event.Allowed, 0))
    }

    @Test fun enrollingWaitsForAllowAndADropThereIsDenied() {
        val m = machine()
        m.on(Event.Start, 0)
        assertEquals(State.AwaitingAllow, m.on(Event.Enrolling, 0))
        assertEquals(State.Up, machine().apply { on(Event.Start, 0); on(Event.Enrolling, 0) }.on(Event.Connected, 1))
        assertEquals(State.Denied("closed"), m.on(Event.Ended(null), 1))
        assertEquals(State.Connecting, m.on(Event.Trigger, 2))
    }

    @Test fun signedOutHoldsUntilSignedInAndStopIsIdle() {
        val m = machine()
        m.on(Event.Start, 0)
        assertEquals(State.SignedOut, m.on(Event.SignedOut, 0))
        assertEquals(State.SignedOut, m.on(Event.Trigger, 0))
        assertEquals(State.Connecting, m.on(Event.SignedIn, 0))
        assertEquals(State.Idle, m.on(Event.Stop, 0))
        assertTrue(m.on(Event.Trigger, 0) is State.Idle)
        assertEquals(State.Connecting, m.on(Event.Start, 0))
    }
}
