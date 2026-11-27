package dev.kore.link

import dev.kore.link.net.NetFailure
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeDialer
import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.State
import dev.kore.link.node.PeerOffline
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import kotlinx.coroutines.test.StandardTestDispatcher
import dev.kore.link.node.RaiseSigner
import dev.kore.link.node.SingleFlight
import dev.kore.link.trust.Raise
import java.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class NodeClientTest {
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.content
    private fun JsonObject.cmd() = this["cmd"] as JsonObject

    /** A node client whose dials are answered, in order, by [plan] (a link, or a failure). */
    private class Rig(
        scope: TestScope, plan: List<() -> Any>, signer: RaiseSigner? = null, device: dev.kore.link.trust.Device = mac(),
        logs: (() -> String)? = null, onLogsAsked: () -> Unit = {},
    ) {
        val clock = { scope.testScheduler.currentTime }
        val links = mutableListOf<FakeLink>()
        val dials = mutableListOf<Long>()
        val resumes = mutableListOf<dev.kore.link.node.NetResume?>()
        /** What [NodeClient.resume] reported: (ms, how). */
        val heard = mutableListOf<Pair<Long, String>>()
        private val queue = ArrayDeque(plan)
        val client = NodeClient(device, scope.backgroundScope, NodeDialer { device, resume, enrolling ->
            dials += clock()
            resumes += resume
            when (val next = (queue.removeFirstOrNull() ?: { NetFailure("timeout") })()) {
                is FakeLink -> next.also { links += it }
                is Throwable -> throw next
                "enroll" -> { enrolling(); CompletableDeferred<Unit>().await(); error("never") }
                else -> error("bad plan")
            }
        }, clock = clock, raiseSigner = signer, machineRandom = object : kotlin.random.Random() {
            override fun nextBits(bitCount: Int) = 0
            override fun nextDouble() = 0.5
        }, logs = logs, onLogsAsked = onLogsAsked, onResumed = { ms, how -> heard += ms to how })
    }

    private fun TestScope.link() = FakeLink(mac(), { testScheduler.currentTime })

    @Test fun theMacsDirectoryNamingAWaitingBoxDialsItAtOnce() = runTest {
        val link = FakeLink(box(), { testScheduler.currentTime })
        val rig = Rig(this, listOf({ NetFailure("bye unknown") }, { link }), device = box())
        rig.client.start()
        runCurrent()
        assertEquals(NodeMachine.AwayWhy.WAITING, (rig.client.state.value as State.Away).why)
        advanceTimeBy(100)
        rig.client.named()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf(0L, 100L), rig.dials)
    }

    @Test fun aBoxThatRemovedThisPhoneStartsOverWhenTheMacNamesItAgain() = runTest {
        val link = FakeLink(box(), { testScheduler.currentTime })
        val rig = Rig(this, listOf({ NetFailure("bye revoked") }, { link }), device = box())
        rig.client.start()
        runCurrent()
        assertEquals(State.Removed, rig.client.state.value)
        rig.client.named()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(2, rig.dials.size)
    }

    @Test fun aNamedBoxTheTailnetSaysIsOfflineWaitsForItsOwnTimer() = runTest {
        val rig = Rig(this, listOf({ PeerOffline() }), device = box())
        rig.client.start()
        runCurrent()
        assertEquals(NodeMachine.AwayWhy.OFFLINE, (rig.client.state.value as State.Away).why)
        rig.client.named()
        runCurrent()
        assertEquals(1, rig.dials.size)
    }

    /** C28: the Mac's directory gives a waiting box a key it didn't have (its other node): dialled now. */
    @Test fun aRecordThatGainsANodeKeyDialsAnAwayBoxAtOnce() = runTest {
        val link = FakeLink(box(), { testScheduler.currentTime })
        val rig = Rig(this, listOf({ PeerOffline() }, { link }), device = box())
        rig.client.start()
        runCurrent()
        assertEquals(NodeMachine.AwayWhy.OFFLINE, (rig.client.state.value as State.Away).why)
        advanceTimeBy(100)
        // The same record again: nothing.
        rig.client.recordChanged(box())
        runCurrent()
        assertEquals(1, rig.dials.size)
        rig.client.recordChanged(box().copy(nodeKeys = listOf("nodekey:box", "nodekey:box-kore")))
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf(0L, 100L), rig.dials)
    }

    /** Item 6: the tailnet's bus says a key came online; the box waiting on it dials now, others don't. */
    @Test fun aPeerComingOnlineOnTheBusWakesTheNodeThatWaitsForIt() = runTest {
        val link = FakeLink(box(), { testScheduler.currentTime })
        val rig = Rig(this, listOf({ PeerOffline() }, { link }), device = box())
        val up = Rig(this, listOf({ link() }))
        rig.client.start()
        up.client.start()
        runCurrent()
        assertEquals(NodeMachine.AwayWhy.OFFLINE, (rig.client.state.value as State.Away).why)
        val net = FakeTailnet(Tailnet.RUNNING).apply {
            onlineNow = "nodekey:mac"
            // Another node first (nothing), then the box's.
            peerSets.addAll(listOf("nodekey:mac,nodekey:other", "nodekey:box,nodekey:mac,nodekey:other"))
        }
        val watch = dev.kore.link.node.PeerWatch(net, backgroundScope, { listOf(rig.client, up.client) }, io = StandardTestDispatcher(testScheduler))
        watch.kick()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(2, rig.dials.size)
        // The Mac was up all along: never dialled again.
        assertEquals(1, up.dials.size)
    }

    /** A box that moved to a node no record holds (`mybox-kore`): the bus's new key, named after it, wakes it. */
    @Test fun aMovedBoxIsWokenByItsNewNodeByName() = runTest {
        val link = FakeLink(box(), { testScheduler.currentTime })
        val rig = Rig(this, listOf({ PeerOffline() }, { link }), device = box())
        rig.client.start()
        runCurrent()
        val me = TailnetNode("p.tail.ts.net.", "p", "android", true, 7, null, "nodekey:p", listOf("100.64.1.1"))
        val net = FakeTailnet(Tailnet.RUNNING).apply {
            this.me = me
            others = listOf(TailnetNode("mybox-kore.tail.ts.net.", "mybox-kore", "linux", true, 7, null, "nodekey:new", listOf("100.113.194.5")))
            peerSets.add("nodekey:new")
        }
        val watch = dev.kore.link.node.PeerWatch(net, backgroundScope, { listOf(rig.client) }, io = StandardTestDispatcher(testScheduler))
        watch.kick()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
    }

    /** Nothing waits: the watch never starts (no bus held). */
    @Test fun thePeerWatchRunsOnlyWhileANodeWaits() = runTest {
        val up = Rig(this, listOf({ link() }))
        up.client.start()
        runCurrent()
        val net = FakeTailnet(Tailnet.RUNNING).apply { peerSets.add("nodekey:x") }
        val watch = dev.kore.link.node.PeerWatch(net, backgroundScope, { listOf(up.client) }, io = StandardTestDispatcher(testScheduler))
        watch.kick()
        runCurrent()
        assertEquals(0, net.peerWaits)
    }

    @Test fun aNamedNodeThatIsUpIsLeftAlone() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        rig.client.named()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(1, rig.dials.size)
    }

    @Test fun startDialsAndRoutesTheSnapshotAndDeltas() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf("presence"), link.types())
        link.push(buildJsonObject { put("t", "snapshot"); put("rev", 1); put("windows", kotlinx.serialization.json.JsonArray(emptyList())); put("chats", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("id", "c1"); put("title", "one") }))) })
        link.push(buildJsonObject { put("t", "delta"); put("rev", 2); put("chats", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("id", "c2"); put("title", "two") }))) })
        runCurrent()
        val snap = rig.client.snapshot.value!!
        assertEquals("2", snap.s("rev"))
        assertEquals(2, (snap["chats"] as kotlinx.serialization.json.JsonArray).size)
    }

    @Test fun usageIsAskedOnceAMinutePerCliOnlyWhileUp() = runTest {
        val away = Rig(this, listOf({ PeerOffline() }))
        away.client.start()
        runCurrent()
        // Away: nothing asked, nothing queued (the next screen opening asks again).
        assertEquals(emptyList<String>(), away.client.askUsage(listOf("claude")))
        assertEquals(emptySet<String>(), away.client.queued.value)
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        assertEquals(listOf("claude", "codex"), rig.client.askUsage(listOf("claude", "codex", "claude")))
        val asked = link.sent.filter { it.s("t") == "cmd" }.map { it.cmd() }
        assertEquals(listOf("claude", "codex"), asked.map { it.s("provider") })
        assertEquals(setOf("account.usage"), asked.map { it.s("type") }.toSet())
        // No login named: read-only, the node's own logins.
        assertTrue(asked.none { it.containsKey("login") })
        advanceTimeBy(59_000)
        assertEquals(emptyList<String>(), rig.client.askUsage(listOf("claude", "codex")))
        advanceTimeBy(1_000)
        assertEquals(listOf("codex"), rig.client.askUsage(listOf("codex")))
        assertEquals(3, link.sent.count { it.s("t") == "cmd" })
    }

    @Test fun commandsMadeWhileAwayExpireThirtySecondsEachWithOneTimer() = runTest {
        val rig = Rig(this, listOf({ PeerOffline() }))
        val results = mutableListOf<JsonObject>()
        backgroundScope.launch { rig.client.results.collect { results += it } }
        rig.client.start()
        runCurrent()
        assertTrue(rig.client.state.value is State.Away)
        val a = rig.client.send("c1", "hi")
        advanceTimeBy(10_000)
        val b = rig.client.stop("c1")
        assertEquals(setOf(a, b), rig.client.queued.value)
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals(listOf(a), results.map { it.s("id") })
        assertEquals("expired", results.single().s("code"))
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(listOf(a, b), results.map { it.s("id") })
        assertEquals(emptySet<String>(), rig.client.queued.value)
        // Offline is retried by backoff (1 s, 2 s, 4 s …), never left waiting with no timer.
        assertTrue(rig.dials.size in 3..8)
        val gaps = rig.dials.zipWithNext { x, y -> y - x }
        assertTrue(gaps.toString(), gaps.zipWithNext().all { (x, y) -> y >= x * 8 / 10 })
    }

    @Test fun aCallThatTimedOutIsNeverSentWhenTheNodeComesBack() = runTest {
        val link = link()
        val clock = { testScheduler.currentTime }
        // Away until 25 s, then the next dial reaches the node.
        val rig = Rig(this, List(40) { { if (clock() >= 25_000) link else PeerOffline() } })
        rig.client.start()
        runCurrent()
        assertTrue(rig.client.state.value is State.Away)
        val answer = async { rig.client.call(dev.kore.link.node.Control.folderAdd("/srv/app"), 20_000) }
        runCurrent()
        assertEquals(1, rig.client.queued.value.size)
        advanceTimeBy(20_001)
        runCurrent()
        assertEquals("timeout", answer.await().s("code"))
        assertEquals(emptySet<String>(), rig.client.queued.value)
        advanceTimeBy(5_000)
        rig.client.reconnectNow()
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(0, link.sent.count { it.s("t") == "cmd" })
    }

    private val copyOnce = dev.kore.link.node.Control.CopyEnd(null, "w_1", sessionId = "s1")
    private fun copy(again: Boolean) = dev.kore.link.node.Control.copyVia("ask-1", copyOnce, dev.kore.link.node.Control.CopyEnd(null, "w_2"), "claude", "Repos", again)
    private fun FakeLink.cmds() = sent.filter { it.s("t") == "cmd" }
    private fun JsonObject.again() = ((this["cmd"] as JsonObject)["copy"] as JsonObject)["again"] != null

    @Test fun aCopysLinkDropsAndTheNextOneAsksHowItEndedUnderTheSameId() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        val answer = async { rig.client.callAcross(copy(false), copy(true), 900_000) }
        runCurrent()
        val sent = first.cmds().single()
        assertTrue(!sent.again())
        first.drop(null)
        advanceTimeBy(1_000)
        runCurrent()
        val asked = second.cmds().single()
        assertEquals(sent.s("id"), asked.s("id"))
        assertTrue(asked.again())
        assertTrue(answer.isActive)
        second.push(buildJsonObject { put("t", "result"); put("id", asked.s("id")!!); put("ok", true) })
        runCurrent()
        assertEquals("true", answer.await().s("ok"))
        // Answered: a later link asks nothing.
        assertEquals(1, first.cmds().size + second.cmds().size - 1)
    }

    @Test fun aCopyNeverSentGoesOnceTheNodeIsBackAndOnlyOnce() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ NetFailure("timeout") }, { link }))
        rig.client.start()
        runCurrent()
        val answer = async { rig.client.callAcross(copy(false), copy(true), 900_000) }
        advanceTimeBy(1_000)
        runCurrent()
        val sent = link.cmds().single()
        assertTrue(!sent.again())
        link.push(buildJsonObject { put("t", "result"); put("id", sent.s("id")!!); put("ok", true) })
        runCurrent()
        assertEquals("true", answer.await().s("ok"))
    }

    @Test fun aCopyWhoseMacNeverComesBackEndsInOneTimeoutAndIsNotAskedLater() = runTest {
        val first = link()
        val late = link()
        val clock = { testScheduler.currentTime }
        val rig = Rig(this, listOf({ first }) + List(200) { { if (clock() > 900_000) late else PeerOffline() } })
        rig.client.start()
        runCurrent()
        val answer = async { rig.client.callAcross(copy(false), copy(true), 900_000) }
        runCurrent()
        first.drop(null)
        advanceTimeBy(900_001)
        runCurrent()
        assertEquals("timeout", answer.await().s("code"))
        rig.client.reconnectNow()
        advanceTimeBy(300_000)
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(0, late.cmds().size)
    }

    @Test fun aCopyWhoseMacStaysAwayEndsAfterAMinuteNotTheWholeWait() = runTest {
        val first = link()
        val rig = Rig(this, listOf<() -> Any>({ first }) + List(200) { { PeerOffline() } })
        rig.client.start()
        runCurrent()
        val answer = async { rig.client.callAcross(copy(false), copy(true), 900_000, awayMs = 60_000) }
        runCurrent()
        first.drop(null)
        advanceTimeBy(59_000)
        runCurrent()
        assertTrue(answer.isActive)
        advanceTimeBy(2_000)
        runCurrent()
        assertEquals("timeout", answer.await().s("code"))
        // A link that's up the whole while waits for the answer however long the copy takes.
        val up = link()
        val steady = Rig(this, listOf({ up }))
        steady.client.start()
        runCurrent()
        val long = async { steady.client.callAcross(copy(false), copy(true), 900_000, awayMs = 60_000) }
        advanceTimeBy(600_000)
        runCurrent()
        assertTrue(long.isActive)
        up.push(buildJsonObject { put("t", "result"); put("id", up.cmds().single().s("id")!!); put("ok", true) })
        runCurrent()
        assertEquals("true", long.await().s("ok"))
    }

    @Test fun queuedCommandsGoOutOnceTheNodeIsBack() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ NetFailure("timeout") }, { link }))
        rig.client.start()
        runCurrent()
        val id = rig.client.send("c1", "hello")
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf(0L, 1_000L), rig.dials)
        assertEquals(State.Up, rig.client.state.value)
        val cmd = link.sent.single { it.s("t") == "cmd" }
        assertEquals(id, cmd.s("id"))
        assertEquals("chat.send", cmd.cmd().s("type"))
        assertEquals(emptySet<String>(), rig.client.queued.value)
    }

    @Test fun openTranscriptsAreFollowedAgainOnTheNextLink() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        rig.client.openTranscript("c1", 40)
        first.drop(null)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf("presence", "tx.open"), second.types())
        assertEquals("40", second.sent[1].s("last"))
    }

    @Test fun revokedStopsDialing() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        link.drop("revoked")
        runCurrent()
        assertEquals(State.Removed, rig.client.state.value)
        rig.client.reconnectNow()
        advanceTimeBy(600_000)
        assertEquals(1, rig.dials.size)
    }

    /** Removed on the Mac, then Join again (same phone, new enroll, allowed): Up, not "removed". */
    @Test fun revokedThenAllowedAgainDialsAndIsUp() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        first.drop("revoked")
        runCurrent()
        assertEquals(State.Removed, rig.client.state.value)
        rig.client.allowed(mac())
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(2, rig.dials.size)
        assertEquals("presence", second.types().first())
    }

    @Test fun aQuietLinkGetsOneKoreNetPingAndIsAbandonedWithoutItsPong() = runTest {
        val dead = link().apply { pongs = false }
        val fresh = link()
        val rig = Rig(this, listOf({ dead }, { fresh }))
        rig.client.start()
        runCurrent()
        advanceTimeBy(14_000)
        rig.client.reconnectNow()
        runCurrent()
        assertEquals(0, dead.pings.size)
        advanceTimeBy(2_000)
        rig.client.reconnectNow()
        rig.client.reconnectNow()
        runCurrent()
        // One ping on stream 0, never a link command.
        assertEquals(1, dead.pings.size)
        assertEquals(listOf("presence"), dead.types())
        advanceTimeBy(4_999)
        assertTrue(!dead.ended.isCompleted)
        advanceTimeBy(2)
        runCurrent()
        assertEquals("abandoned", dead.ended.getCompleted())
        assertEquals(2, rig.dials.size)
        assertEquals(State.Up, rig.client.state.value)
    }

    // MARK: off screen and back (0.3.10: every app switch relinked)

    private fun snapshot(vararg chats: Pair<String, String>) = buildJsonObject {
        put("t", "snapshot"); put("rev", 3); put("windows", kotlinx.serialization.json.JsonArray(emptyList()))
        put("chats", kotlinx.serialization.json.JsonArray(chats.map { (id, state) -> buildJsonObject { put("id", id); put("state", state) } }))
    }

    @Test fun tenSecondsInAnotherAppComesBackOnTheSameLink() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        rig.client.setPresence(false)
        advanceTimeBy(10_000)
        rig.client.setPresence(true, "c1")
        rig.client.resume()
        runCurrent()
        // One ping, its pong at once: the same link, no dial, never Connecting.
        assertEquals(1, link.pings.size)
        assertEquals(1, rig.dials.size)
        assertTrue(!link.ended.isCompleted)
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf(0L to "same"), rig.heard)
        assertEquals(listOf("presence", "presence", "presence"), link.types())
    }

    @Test fun aKeptLinkThatDiedMeanwhileIsMadeAgainWithItsCursorsWithinASecond() = runTest {
        val dead = link().apply { pongs = false }
        val fresh = link()
        val rig = Rig(this, listOf({ dead }, { fresh }))
        rig.client.start()
        runCurrent()
        dead.push(snapshot("c1" to "idle"))
        runCurrent()
        rig.client.setPresence(false)
        advanceTimeBy(4 * 60_000)
        rig.client.resume()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        advanceTimeBy(NodeClient.RESUME_PROBE_MS + 1)
        runCurrent()
        assertEquals("abandoned", dead.ended.getCompleted())
        assertEquals(2, rig.dials.size)
        // The new link resumes: the old link's ticket and the snapshot's rev.
        val resume = rig.resumes[1]!!
        assertArrayEquals(byteArrayOf(4, 2), resume.ticket)
        assertEquals("3", (resume.cursors["snapshot"] as JsonObject).s("rev"))
        assertEquals(State.Up, rig.client.state.value)
        assertEquals("new", rig.heard.single().second)
        assertTrue(rig.heard.single().first <= NodeClient.RESUME_PROBE_MS + 1)
        // The snapshot the screen shows was never dropped.
        assertEquals("3", rig.client.snapshot.value!!.s("rev"))
    }

    @Test fun tenMinutesAwayResumesSilentlyFromCold() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        first.push(snapshot("c1" to "idle"))
        runCurrent()
        // Past the linger: the keeper stops the clients (a bye), the tailnet goes.
        rig.client.setPresence(false)
        advanceTimeBy(5 * 60_000)
        rig.client.stop()
        runCurrent()
        assertEquals(State.Idle, rig.client.state.value)
        assertTrue(first.ended.isCompleted)
        advanceTimeBy(5 * 60_000)
        // Back: started with the tailnet, then the resume. One dial, with the cursors; the
        // snapshot shown meanwhile is the one it had.
        rig.client.start()
        rig.client.post(NodeMachine.Event.Screen(true))
        rig.client.resume()
        assertEquals("3", rig.client.snapshot.value!!.s("rev"))
        runCurrent()
        assertEquals(2, rig.dials.size)
        assertArrayEquals(byteArrayOf(4, 2), rig.resumes[1]!!.ticket)
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf(0L to "cold"), rig.heard)
    }

    @Test fun aNetworkChangeWhileAwayProbesAndRedialsOnceAndNoTimerDialsOffScreen() = runTest {
        val dead = link().apply { pongs = false }
        val rig = Rig(this, listOf({ dead }, { NetFailure("timeout") }, { link() }))
        rig.client.start()
        runCurrent()
        rig.client.setPresence(false)
        advanceTimeBy(30_000)
        // Wi-Fi to mobile data while in another app: the kept link is probed (5 s), dropped,
        // dialled once; that dial fails and nothing dials again by the clock off screen.
        rig.client.reconnectNow()
        advanceTimeBy(NodeClient.PROBE_MS + 1)
        runCurrent()
        assertEquals("abandoned", dead.ended.getCompleted())
        assertEquals(2, rig.dials.size)
        val away = rig.client.state.value as State.Away
        assertEquals(null, away.at)
        advanceTimeBy(10 * 60_000)
        assertEquals(2, rig.dials.size)
        // Back on screen: dialled at once.
        rig.client.post(NodeMachine.Event.Screen(true))
        rig.client.resume()
        runCurrent()
        assertEquals(3, rig.dials.size)
        assertEquals(State.Up, rig.client.state.value)
        assertEquals("cold", rig.heard.single().second)
    }

    @Test fun aFollowedChatWorkingIsKnownUntilItsTurnEnds() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        link.push(snapshot("c1" to "working", "c2" to "working"))
        runCurrent()
        // Only chats open in a screen count.
        assertTrue(!rig.client.followsWork())
        rig.client.openTranscript("c1")
        assertTrue(rig.client.followsWork())
        // Off screen no deltas come: the turn's end in the attention stream says it.
        link.push(buildJsonObject { put("t", "attn.event"); put("aid", 4); put("op", "turn"); put("turn", buildJsonObject { put("chatId", "c1") }) })
        runCurrent()
        assertTrue(!rig.client.followsWork())
        // A later snapshot is the truth again.
        link.push(snapshot("c1" to "working"))
        runCurrent()
        assertTrue(rig.client.followsWork())
    }

    @Test fun aPongKeepsTheLink() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        advanceTimeBy(20_000)
        rig.client.reconnectNow()
        advanceTimeBy(60_000)
        assertEquals(1, link.pings.size)
        assertTrue(!link.ended.isCompleted)
        assertEquals(1, rig.dials.size)
    }

    private fun TestScope.cardChat(risk: String?) = buildJsonObject {
        put("t", "snapshot"); put("rev", 1); put("windows", kotlinx.serialization.json.JsonArray(emptyList()))
        put("chats", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject {
            put("id", "c1")
            put("cards", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject {
                put("id", "k1"); put("digest", "d1g"); if (risk != null) put("risk", risk)
            })))
        })))
    }

    /** A node that hands out [nonce] for `raise.chal` and records what it was asked. */
    private fun TestScope.raiseNode(nonce: ByteArray) = link().apply {
        respond = { m -> if (m.s("t") == "raise.chal") buildJsonObject { put("t", "raise.chal"); put("id", m.s("id")); put("nonce", Base64.getEncoder().encodeToString(nonce)) } else null }
    }

    @Test fun everyAnswerIsAPlainTapRiskyAllowToo() = runTest {
        var asked = 0
        val link = raiseNode(ByteArray(32))
        val rig = Rig(this, listOf({ link }), signer = { asked++; ByteArray(8) })
        rig.client.start()
        runCurrent()
        val ids = mutableListOf<String?>()
        for ((risk, action) in listOf("shell" to "allow", "write" to "allow", "network" to "allow", "network" to "deny", null to "allow")) {
            link.push(cardChat(risk))
            runCurrent()
            ids += rig.client.answer("c1", "k1", action)
            runCurrent()
        }
        // No fingerprint, no nonce asked for, nothing signed: the answer alone, over the card's digest.
        assertEquals(0, asked)
        assertEquals(0, link.sent.count { it.s("t") == "raise.chal" })
        val cmds = link.sent.filter { it.s("t") == "cmd" }
        assertEquals(ids, cmds.map { it.s("id") })
        assertEquals(listOf("allow", "allow", "allow", "deny", "allow"), cmds.map { it.cmd().s("action") })
        for (c in cmds) {
            val answer = c.cmd()
            assertEquals("chat.answer", answer.s("type"))
            assertEquals("d1g", answer.s("digest"))
            assertEquals(null, answer.s("nonce"))
            assertEquals(null, answer.s("sig"))
        }
    }

    @Test fun aNewFingerprintKeyWaitsForTheMacsOneResult() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        val pub = byteArrayOf(1, 2, 3)
        val answer = async { rig.client.raiseKey(pub) }
        runCurrent()
        val sent = link.sent.single { it.s("t") == "raise.key" }
        assertEquals(Base64.getEncoder().encodeToString(pub), sent.s("pub"))
        // The owner takes a while; the answer is keyed raise.key:<id>.
        advanceTimeBy(90_000)
        assertTrue(!answer.isCompleted)
        link.push(buildJsonObject { put("t", "result"); put("id", "raise.key:" + sent.s("id")); put("ok", true) })
        assertEquals("true", answer.await().s("ok"))
    }

    @Test fun anUnansweredFingerprintKeyTimesOut() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        val answer = async { rig.client.raiseKey(byteArrayOf(9)) }
        advanceTimeBy(NodeClient.RAISE_KEY_MS + 1)
        assertEquals("timeout", answer.await().s("code"))
    }

    @Test fun takenOfflineTheLinkIsParkedAndNothingRedials() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        link.push(buildJsonObject { put("t", "paused") })
        runCurrent()
        assertEquals(NodeMachine.AwayWhy.OFF, (rig.client.state.value as State.Away).why)
        // The app opening, the peer coming online: the parked link is the way back, no dial.
        rig.client.post(NodeMachine.Event.Trigger)
        rig.client.post(NodeMachine.Event.PeerOnline)
        advanceTimeBy(600_000)
        assertEquals(1, rig.dials.size)
    }

    @Test fun broughtOnlineItDialsStraightBackAndIsUp() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        first.push(buildJsonObject { put("t", "paused") })
        runCurrent()
        first.drop("online")
        runCurrent()
        assertEquals(2, rig.dials.size)
        assertEquals(State.Up, rig.client.state.value)
    }

    @Test fun leaveTellsTheMacAndTakesItsAnswer() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "leave") buildJsonObject { put("t", "result"); put("id", "leave:" + m.s("id")); put("ok", true) } else null }
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        assertTrue(rig.client.leave())
    }

    @Test fun leaveGivesUpAfterTwoSecondsWithoutAnAnswer() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        val left = async { rig.client.leave() }
        advanceTimeBy(NodeClient.LEAVE_MS - 1)
        assertTrue(!left.isCompleted)
        advanceTimeBy(2)
        assertEquals(false, left.await())
    }

    @Test fun raiseSignsTheDigestOverThisLinksBindingAndTheNodesNonce() = runTest {
        val key = dev.kore.link.trust.SoftwareIdentity.fresh()
        val nonce = ByteArray(32) { it.toByte() }
        val link = link()
        link.respond = { m ->
            when {
                m.s("t") == "raise.chal" -> buildJsonObject { put("t", "raise.chal"); put("id", m.s("id")); put("nonce", Base64.getEncoder().encodeToString(nonce)) }
                m.s("t") == "cmd" && m.cmd().s("type") == "raise" -> buildJsonObject { put("t", "result"); put("id", m.s("id")); put("ok", true) }
                else -> null
            }
        }
        val rig = Rig(this, listOf({ link }), signer = { d -> key.sign(d) })
        rig.client.start()
        runCurrent()
        val r = rig.client.raise("chat-7f3a", "auto")
        assertEquals("true", r.s("ok"))
        val raise = link.sent.single { it.s("t") == "cmd" }.cmd()
        assertEquals("chat-7f3a", raise.s("chatId"))
        assertEquals("auto", raise.s("modeId"))
        val digest = Raise.digest(link.binding, nonce, "chat-7f3a", "auto")
        assertTrue(dev.kore.link.trust.IdentityProof.verify(Base64.getDecoder().decode(raise.s("sig")), digest, key.publicKey))
        assertArrayEquals(nonce, Base64.getDecoder().decode(raise.s("nonce")))
    }

    @Test fun noFingerprintIsCancelledAndNothingIsSent() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "raise.chal") buildJsonObject { put("t", "raise.chal"); put("id", m.s("id")); put("nonce", Base64.getEncoder().encodeToString(ByteArray(32))) } else null }
        val rig = Rig(this, listOf({ link }), signer = { null })
        rig.client.start()
        runCurrent()
        assertEquals("cancelled", rig.client.raise("c", "auto").s("code"))
        assertEquals(0, link.sent.count { it.s("t") == "cmd" })
    }

    @Test fun aRefusedChallengeComesBackAsItsResult() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "raise.chal") buildJsonObject { put("t", "result"); put("id", "raise.chal:" + m.s("id")); put("ok", false); put("code", "denied.raiseMode") } else null }
        val rig = Rig(this, listOf({ link }), signer = { ByteArray(1) })
        rig.client.start()
        runCurrent()
        assertEquals("denied.raiseMode", rig.client.raise("c", "bypass").s("code"))
    }

    @Test fun oneFingerprintPromptAtATime() = runTest {
        val gate = CompletableDeferred<ByteArray?>()
        var asked = 0
        val one = SingleFlight { asked++; gate.await() }
        val first = async { one.sign(ByteArray(32)) }
        runCurrent()
        assertEquals(null, one.sign(ByteArray(32)))
        gate.complete(byteArrayOf(1))
        assertArrayEquals(byteArrayOf(1), first.await())
        assertEquals(1, asked)
        assertTrue(one.sign(ByteArray(32)) != null)
    }

    @Test fun anEnrollingDialWaitsForAllow() = runTest {
        val rig = Rig(this, listOf({ "enroll" }))
        rig.client.start()
        runCurrent()
        assertEquals(State.AwaitingAllow, rig.client.state.value)
    }

    @Test fun uploadFramesUseLinkOneElevenShapes() {
        val frames = NodeClient.uploadFrames("u1", "a.png", "image/png", ByteArray(NodeClient.UPLOAD_CHUNK + 1))
        assertEquals(4, frames.size)
        assertTrue(frames[0].startsWith("{\"t\":\"blob.put.begin\",\"uploadId\":\"u1\""))
        assertTrue(frames[2].contains("\"index\":1"))
        assertEquals("{\"t\":\"blob.put.end\",\"uploadId\":\"u1\"}", frames[3])
    }

    /** 1.13: a Mac asks for the phone's log: pieces from the one read of its first ask, said once on screen. */
    @Test fun aLogAskIsAnsweredInPiecesFromOneRead() = runTest {
        val link = link()
        var reads = 0
        var asked = 0
        val text = "x".repeat(NodeClient.LOG_PIECE + 10)
        val rig = Rig(this, listOf({ link }), logs = { reads++; text }, onLogsAsked = { asked++ })
        rig.client.start()
        runCurrent()
        link.push(kotlinx.serialization.json.buildJsonObject { put("t", "logs.get"); put("id", "L1"); put("offset", 0) })
        runCurrent()
        link.push(kotlinx.serialization.json.buildJsonObject { put("t", "logs.get"); put("id", "L1"); put("offset", NodeClient.LOG_PIECE) })
        runCurrent()
        val chunks = link.sent.filter { it.s("t") == "logs.chunk" }
        assertEquals(2, chunks.size)
        assertEquals(listOf(0, NodeClient.LOG_PIECE), chunks.map { it["offset"]!!.jsonPrimitive.int })
        assertEquals(text.length, chunks[0]["total"]!!.jsonPrimitive.int)
        assertEquals(text, chunks.joinToString("") { it.s("text") ?: "" })
        assertEquals(1, reads)
        assertEquals(1, asked)
    }

    @Test fun aClientWithNoLogAnswersNothing() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        link.push(kotlinx.serialization.json.buildJsonObject { put("t", "logs.get"); put("id", "L1") })
        runCurrent()
        assertTrue(link.sent.none { it.s("t") == "logs.chunk" })
    }
}
