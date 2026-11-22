package dev.kore.link.node

import dev.kore.link.net.NetDialer
import dev.kore.link.net.Tailnet
import dev.kore.link.trust.NodeKind
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The phone's PeerOnline (NodeMachine's event): while a node is Away waiting for its peer, one IO
 * coroutine waits on the embedded tailnet's IPN bus ([Tailnet.waitPeers]). When a node key comes
 * online, every waiting node whose record holds it is told, and so is a box or Mac that may have
 * moved to it (a node named after it, of this phone's user, that no record holds:
 * [NetDialer.movedBoxes], [NetDialer.movedMacs]). Its dial's identity proof still decides. Nothing
 * runs while no node waits, or on a tailnet without events.
 */
class PeerWatch(
    private val tailnet: Tailnet,
    private val scope: CoroutineScope,
    private val nodes: () -> List<NodeClient>,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val waitMs: Long = WAIT_MS,
) {
    @Volatile private var job: Job? = null

    /** A node's state may have changed: the watch runs while any node waits for its peer. */
    fun kick() {
        synchronized(this) {
            if (job?.isActive == true || waiting().isEmpty()) return
            job = scope.launch(io) { watch() }
        }
    }

    fun stop() {
        synchronized(this) {
            job?.cancel()
            job = null
        }
    }

    /** Kicks on every change of every node's state (the list as it changes too). */
    fun follow(list: StateFlow<List<NodeClient>>): Job = scope.launch {
        list.collectLatest { clients ->
            if (clients.isEmpty()) return@collectLatest
            merge(*clients.map { it.state }.toTypedArray()).collect { kick() }
        }
    }

    private fun waiting() = nodes().filter { waits(it.state.value) }

    private suspend fun watch() {
        var known = tailnet.onlinePeers()
        while (currentCoroutineContext().isActive) {
            if (waiting().isEmpty()) return
            val next = tailnet.waitPeers(known, waitMs) ?: return
            val came = keys(next) - keys(known)
            known = next
            if (came.isNotEmpty()) cameOnline(came)
        }
    }

    /** Keys that just came online: PeerOnline for each waiting node they may be. */
    internal fun cameOnline(came: Set<String>) {
        val targets = waiting()
        if (targets.isEmpty()) return
        val fresh by lazy { tailnet.peers().filter { it.nodeKey in came } }
        val self by lazy { tailnet.self() }
        for (node in targets) {
            val d = node.device.value
            val hit = d.nodeKeys.any { it in came } || when (d.kind) {
                NodeKind.BOX -> NetDialer.movedBoxes(d, fresh, self).isNotEmpty()
                NodeKind.MAC -> NetDialer.movedMacs(d, fresh, self).isNotEmpty()
                else -> false
            }
            if (hit) node.post(NodeMachine.Event.PeerOnline)
        }
    }

    companion object {
        /** One bus wait at most this long before the waiting nodes are looked at again. */
        const val WAIT_MS = 60_000L

        /** Away for its peer (asleep, offline, unreachable, waiting): never taken offline or KoreNet off. */
        fun waits(s: NodeMachine.State) =
            s is NodeMachine.State.Away && s.why != NodeMachine.AwayWhy.OFF && s.why != NodeMachine.AwayWhy.NET_OFF

        fun keys(set: String): Set<String> = set.split(',').filter { it.isNotEmpty() }.toSet()
    }
}
