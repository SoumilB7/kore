package dev.kore.link

import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetFailure
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.node.JoinFlow
import dev.kore.link.node.JoinFlow.Step
import dev.kore.link.node.MacProbe
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class JoinFlowTest {
    private val me = node("pixel", os = "android", key = "nodekey:me")

    @Test fun probeRuleTakesOnlyOwnOnlineUntaggedMacs() {
        val peers = listOf(
            node("mbp"),
            node("old", online = false),
            node("box", os = "linux"),
            node("work", user = 99),
            node("ci", tags = listOf("tag:ci")),
            node("shared", user = null),
            me.copy(os = "macOS"),
        )
        assertEquals(listOf("mbp"), MacProbe.candidates(me, peers).map { it.shortName })
    }

    /** A flow over [tailnet]; [answer] says what each Mac does when dialled. */
    private class Rig(scope: TestScope, val tailnet: FakeTailnet, val answer: suspend (TailnetNode, () -> Unit) -> LinkSession) {
        val knocks = mutableListOf<Pair<String, Long>>()
        var joined: LinkSession? = null
        val flow = JoinFlow(tailnet, { mac, enrolling -> knocks += mac.shortName to scope.testScheduler.currentTime; answer(mac, enrolling) },
            scope.backgroundScope, { joined = it }, { scope.testScheduler.currentTime }, StandardTestDispatcher(scope.testScheduler))
    }

    @Test fun signInThenFindThenAllowThenHome() = runTest {
        val tailnet = FakeTailnet()
        val allowed = CompletableDeferred<Unit>()
        val link = FakeLink(mac(), { testScheduler.currentTime })
        val rig = Rig(this, tailnet) { mac, enrolling ->
            if (mac.shortName != "mbp") throw java.io.IOException("refused")
            enrolling()
            allowed.await()
            link
        }
        rig.flow.visible(true)
        rig.flow.begin()
        runCurrent()
        assertEquals(1, tailnet.started)
        assertEquals(Step.SigningIn("https://login.tailscale.com/a/x"), rig.flow.step.value)
        tailnet.state = Tailnet.RUNNING
        tailnet.me = me
        tailnet.others = listOf(node("mbp"), node("box", os = "linux"))
        advanceTimeBy(1_001)
        runCurrent()
        assertTrue(rig.flow.step.value is Step.Allowing)
        assertEquals("mbp", (rig.flow.step.value as Step.Allowing).mac)
        allowed.complete(Unit)
        runCurrent()
        assertEquals(Step.Joined(mac()), rig.flow.step.value)
        assertEquals(link, rig.joined)
        assertEquals(listOf("mbp"), rig.knocks.map { it.first })
    }

    @Test fun knocksEveryTwoSecondsWhileVisibleAndStopsAfterTwoMinutes() = runTest {
        val tailnet = FakeTailnet(Tailnet.RUNNING).apply { me = this@JoinFlowTest.me; others = listOf(node("mbp")) }
        val rig = Rig(this, tailnet) { _, _ -> throw java.io.IOException("refused") }
        rig.flow.visible(true)
        rig.flow.begin()
        advanceTimeBy(10_001)
        assertEquals(listOf(0L, 2_000, 4_000, 6_000, 8_000, 10_000), rig.knocks.map { it.second })
        advanceTimeBy(200_000)
        assertEquals(60, rig.knocks.size)
        assertEquals(Step.Finding(listOf("mbp"), stopped = true), rig.flow.step.value)
    }

    @Test fun hiddenJoinScreenKnocksOnNothing() = runTest {
        val tailnet = FakeTailnet(Tailnet.RUNNING).apply { me = this@JoinFlowTest.me; others = listOf(node("mbp")) }
        val rig = Rig(this, tailnet) { _, _ -> throw java.io.IOException("refused") }
        rig.flow.visible(true)
        rig.flow.begin()
        advanceTimeBy(3_000)
        val before = rig.knocks.size
        rig.flow.visible(false)
        advanceTimeBy(60_000)
        assertEquals(before, rig.knocks.size)
        rig.flow.visible(true)
        advanceTimeBy(100)
        assertEquals(before + 1, rig.knocks.size)
    }

    @Test fun noMacOfThisAccountSaysSo() = runTest {
        val tailnet = FakeTailnet(Tailnet.RUNNING).apply { me = this@JoinFlowTest.me; others = listOf(node("box", os = "linux"), node("work", user = 99)) }
        val rig = Rig(this, tailnet) { _, _ -> error("no knock expected") }
        rig.flow.visible(true)
        rig.flow.begin()
        advanceTimeBy(121_000)
        assertEquals(Step.NoMac("me@example.com"), rig.flow.step.value)
        assertEquals(0, rig.knocks.size)
    }

    @Test fun aMacOutsideItsAddWindowKeepsTheKnockingAndANoIsDenied() = runTest {
        val tailnet = FakeTailnet(Tailnet.RUNNING).apply { me = this@JoinFlowTest.me; others = listOf(node("mbp")) }
        var tries = 0
        val rig = Rig(this, tailnet) { _, enrolling ->
            tries++
            enrolling()
            throw NetFailure(if (tries == 1) "bye unknown" else "bye refused")
        }
        rig.flow.visible(true)
        rig.flow.begin()
        runCurrent()
        assertEquals(Step.Finding(listOf("mbp")), rig.flow.step.value)
        advanceTimeBy(2_001)
        assertEquals(Step.Denied("mbp"), rig.flow.step.value)
        advanceTimeBy(60_000)
        assertEquals(2, tries)
        rig.flow.again()
        runCurrent()
        assertEquals(3, tries)
    }

    @Test fun anApprovalWaitShowsTheNodeKey() = runTest {
        val tailnet = FakeTailnet(Tailnet.NEEDS_MACHINE_AUTH)
        val rig = Rig(this, tailnet) { _, _ -> error("no") }
        rig.flow.visible(true)
        rig.flow.begin()
        runCurrent()
        assertEquals(Step.NeedsApproval(null), rig.flow.step.value)
    }
}
