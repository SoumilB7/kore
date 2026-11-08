package dev.kore.link

import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.AwayWhy
import dev.kore.link.node.NodeMachine.Event
import dev.kore.link.node.NodeMachine.State
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeMachineTest {
    /** No jitter: nextDouble() is 0.5, so a delay is exactly its base. */
    private fun machine() = NodeMachine(object : Random() {
        override fun nextBits(bitCount: Int) = 0
        override fun nextDouble() = 0.5
    })

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

    @Test fun offlinePeersWaitWithoutATimer() {
        val m = machine()
        m.on(Event.Start, 0)
        m.on(Event.Connected, 50)
        m.on(Event.Ended(null), 100)
        val s = m.on(Event.PeerOffline, 100) as State.Away
        assertEquals(AwayWhy.ASLEEP, s.why)
        assertNull(s.at)
        assertEquals(50L, s.lastSeen)
        assertNull(m.wakeAt)
    }

    @Test fun byesMapToStates() {
        fun after(reason: String?): State = machine().apply { on(Event.Start, 0); on(Event.Connected, 0) }.on(Event.Ended(reason), 0)
        assertEquals(State.Removed, after("revoked"))
        assertEquals(State.Denied("unknown"), after("unknown"))
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
