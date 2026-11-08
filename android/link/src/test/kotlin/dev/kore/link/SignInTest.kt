package dev.kore.link

import dev.kore.link.net.Tailnet
import dev.kore.link.node.JoinFlow
import dev.kore.link.node.JoinFlow.Step
import dev.kore.link.node.TailnetKeeper
import dev.kore.link.node.TailnetSwitch
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sign-in as the phone lives it: the Join flow, the keeper that decides when the tailnet runs,
 * and the switch, over a fake tailnet that (like tsnet) loses its pending node key on a stop.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SignInTest {
    private val me = node("pixel", os = "android", key = "nodekey:me")

    private class World(scope: TestScope, val tailnet: FakeTailnet = FakeTailnet(), var joined: Boolean = false) {
        var networkOn = true
        var background = false
        val io = StandardTestDispatcher(scope.testScheduler)
        val switch = TailnetSwitch(tailnet, io)
        val ups = mutableListOf<Boolean>()
        var downs = 0
        val troubles = mutableListOf<Exception>()
        var knocks = 0
        lateinit var keeper: TailnetKeeper
        val flow = JoinFlow(tailnet, { _, _ -> knocks++; throw java.io.IOException("refused") }, scope.backgroundScope, {},
            { scope.testScheduler.currentTime }, io, start = { keeper.up() })

        init {
            keeper = TailnetKeeper(tailnet, switch, flow, scope.backgroundScope, { TailnetKeeper.Settings(networkOn, joined, background) },
                { ups += it }, { downs++ }, { troubles += it }, io)
        }

        /** The app in front with the Join screen. */
        fun front() {
            keeper.onScreen(true)
            flow.visible(true)
        }

        /** The browser tab over the app: the Join screen hides at once, the app is off screen after its 5 s grace. */
        fun TestScope.toBrowser() {
            flow.visible(false)
            advanceTimeBy(5_001)
            keeper.onScreen(false)
        }
    }

    @Test fun theBrowserRoundTripNeverStopsTheTailnetNorChangesTheUrl() = runTest {
        val w = World(this)
        w.front()
        w.flow.begin()
        runCurrent()
        assertEquals(Step.SigningIn(url), w.flow.step.value)
        with(w) { toBrowser() }
        advanceTimeBy(120_000)
        assertEquals(0, w.tailnet.stops)
        assertTrue(w.switch.up)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
        // Back without finishing: the same page, the same node key.
        w.front()
        advanceTimeBy(3_000)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
        assertEquals(0, w.tailnet.stops)
        assertEquals(1, w.tailnet.started)
    }

    @Test fun aSignInFinishedInTheBrowserShowsOnReturnAndKnocks() = runTest {
        val w = World(this)
        w.front()
        w.flow.begin()
        runCurrent()
        with(w) { toBrowser() }
        w.tailnet.state = Tailnet.RUNNING
        w.tailnet.me = me
        w.tailnet.others = listOf(node("mbp"))
        advanceTimeBy(1_001)
        // Signed in while away: shown at once, no knock off screen.
        assertEquals(Step.Finding(emptyList()), w.flow.step.value)
        assertEquals(0, w.knocks)
        // The sign-in is over and its keys are on disk: off screen, the tailnet may stop now.
        assertEquals(1, w.tailnet.stops)
        assertFalse(w.switch.up)
        w.front()
        advanceTimeBy(100)
        assertEquals(2, w.tailnet.started)
        assertEquals(1, w.knocks)
        assertEquals(Step.Finding(listOf("mbp")), w.flow.step.value)
    }

    @Test fun aSignInAgainForAJoinedPhoneSurvivesTheBrowserToo() = runTest {
        val w = World(this, joined = true)
        w.keeper.onScreen(true)
        runCurrent()
        assertEquals(listOf(false), w.ups) // it wants a sign-in: the node clients say so
        w.flow.visible(true)
        w.flow.begin()
        runCurrent()
        with(w) { toBrowser() }
        advanceTimeBy(60_000)
        assertEquals(0, w.tailnet.stops)
        assertEquals(0, w.downs)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
    }

    @Test fun cancelThenJoinOpensTheSignInPageAgain() = runTest {
        // Joined: Cancel leaves the tailnet up on screen, so the second Join shows the very same URL.
        val w = World(this, joined = true)
        w.front()
        w.flow.begin()
        runCurrent()
        val first = w.flow.step.value
        assertEquals(url, w.flow.tab.toOpen(first))
        assertNull(w.flow.tab.toOpen(first)) // a redraw opens nothing
        w.flow.cancel()
        runCurrent()
        assertEquals(Step.Join(), w.flow.step.value)
        w.flow.begin()
        runCurrent()
        assertEquals(first, w.flow.step.value)
        assertEquals(url, w.flow.tab.toOpen(w.flow.step.value))
        // A step in between (a redraw on another step) frees it too.
        assertNull(w.flow.tab.toOpen(Step.Starting))
        assertEquals(url, w.flow.tab.toOpen(first))
    }

    @Test fun aStartThatFailsReturnsToJoinWithATryAgainCue() = runTest {
        val w = World(this)
        w.tailnet.startFails = IllegalStateException("tailnet: state didn't open (kept)")
        w.front()
        w.flow.begin()
        advanceTimeBy(10_000)
        assertEquals(Step.Join(failed = true), w.flow.step.value)
        assertFalse(w.switch.up)
        w.flow.begin()
        runCurrent()
        assertTrue(w.flow.step.value is Step.SigningIn)
        assertTrue(w.switch.up)
    }

    @Test fun hidingTheScreenWhileStartingNeverCancelsTheStart() = runTest {
        val w = World(this)
        w.front()
        w.flow.begin()
        w.flow.visible(false)
        runCurrent()
        assertEquals(1, w.tailnet.started)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
    }

    @Test fun offlineMidSignInSaysSoAndKeepsTheKey() = runTest {
        val w = World(this)
        w.front()
        w.flow.begin()
        runCurrent()
        w.tailnet.online = false // airplane mode, or Wi-Fi gone before mobile data comes up
        advanceTimeBy(1_001)
        assertTrue(w.flow.offline.value)
        w.tailnet.online = true
        advanceTimeBy(1_000)
        assertFalse(w.flow.offline.value)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
        assertEquals(0, w.tailnet.stops)
    }

    @Test fun tenMinutesAwayMidSignInGivesUp() = runTest {
        val w = World(this)
        w.front()
        w.flow.begin()
        runCurrent()
        with(w) { toBrowser() }
        advanceTimeBy(JoinFlow.AWAY_MS - 10_000)
        assertEquals(Step.SigningIn(url), w.flow.step.value)
        advanceTimeBy(20_000)
        assertEquals(Step.Join(), w.flow.step.value)
        assertFalse(w.switch.up)
    }

    @Test fun whenTheTailnetRuns() {
        fun want(on: Boolean = true, joined: Boolean = false, bg: Boolean = false, step: Step = Step.Join(), screen: Boolean = false) =
            TailnetKeeper.wants(TailnetKeeper.Settings(on, joined, bg), step, screen)
        assertTrue(want(joined = true, screen = true))
        assertFalse(want(joined = true))
        assertTrue(want(joined = true, bg = true))
        assertFalse(want(on = false, joined = true, screen = true))
        assertFalse(want(screen = true)) // signed out, on the Join screen: nothing runs
        for (s in listOf(Step.Starting, Step.SigningIn(url), Step.NeedsApproval(null))) {
            assertTrue("$s", want(step = s))
            assertTrue("$s", want(joined = true, step = s))
            assertFalse("$s", want(on = false, step = s))
        }
        assertTrue(want(step = Step.Finding(emptyList()), screen = true))
        assertFalse(want(step = Step.Finding(emptyList())))
    }

    @Test fun aJoinedPhoneRunsOnScreenOnlyAndRetriesAFailedStart() = runTest {
        val w = World(this, FakeTailnet(Tailnet.RUNNING), joined = true)
        w.tailnet.startFails = java.security.KeyStoreException("busy")
        w.keeper.onScreen(true)
        runCurrent()
        assertEquals(1, w.troubles.size)
        assertFalse(w.switch.up)
        advanceTimeBy(TailnetKeeper.RETRY_MS + 1)
        assertTrue(w.switch.up)
        assertEquals(listOf(true), w.ups)
        w.keeper.onScreen(false)
        runCurrent()
        assertEquals(1, w.downs)
        assertFalse(w.switch.up)
        w.background = true
        w.keeper.apply()
        runCurrent()
        assertTrue(w.switch.up)
    }

    @Test fun networkOffKeepsItDownEvenOnScreen() = runTest {
        val w = World(this, FakeTailnet(Tailnet.RUNNING), joined = true)
        w.networkOn = false
        w.keeper.onScreen(true)
        advanceTimeBy(1_000)
        assertEquals(0, w.tailnet.started)
    }

    private val url = "https://login.tailscale.com/a/x"
}
