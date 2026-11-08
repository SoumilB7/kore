package dev.kore.link.net

import dev.kore.link.node.NetResume
import dev.kore.link.node.NodeDialer
import dev.kore.link.node.PeerOffline
import dev.kore.link.trust.Binding
import dev.kore.link.trust.Device
import dev.kore.link.trust.IdentitySigner
import dev.kore.link.trust.NodeKind
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Who this phone is on KoreNet: its device id (Kore's, kept across sign-ins) and keys. */
class PhoneIdentity(
    val device: UUID,
    /** The non-biometric Keystore identity key (works while locked, for background links). */
    val signer: IdentitySigner,
    /** As the Mac's Allow card shows it: the phone's own name (its settings' device name). */
    val name: String,
    val model: String,
    /** The biometric `kore_raise` key's public half (SPKI DER), sent on enroll. */
    val raiseKey: ByteArray?,
)

/**
 * Opens link 2.0 sessions over the phone's tailnet: finds the node's address by its node key (or
 * name), dials :47470 off the main thread, takes the peer's node key and user from this node's own
 * WhoIs (never the peer's word), and runs the handshake.
 */
class NetDialer(
    private val tailnet: Tailnet,
    private val identity: () -> PhoneIdentity,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : NodeDialer {
    override suspend fun dial(device: Device, resume: NetResume?, enrolling: () -> Unit): LinkSession {
        val peers = withContext(io) { tailnet.peers() }
        val peer = known(device, peers)
        // A Mac whose node is gone or offline may be on a new node: Tailscale reinstalled, or
        // Kore's own tailnet in place of the uninstalled app (a new node key, often a new name).
        // This phone's user's other online Macs are tried; only the one whose identity proof holds
        // for this record gets in (its new node key appended after a same-user WhoIs, ID2): no
        // re-Join, no Allow. Another Mac fails at its challenge, before this phone says a word.
        if (device.kind == NodeKind.MAC && (peer == null || !peer.online)) {
            val self = withContext(io) { tailnet.self() }
            for (moved in movedMacs(device, peers, self)) {
                try {
                    return open(moved.address, device, resume, null, enrolling)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: NetFailure) {
                    // It answered as this Mac (the challenge named it) and said no: that's the word.
                    if (e.reason.startsWith("bye ")) throw e
                } catch (e: Exception) {
                    // Not Kore there, or not this Mac: the next.
                }
            }
        }
        val address = peer?.address ?: device.fqdn.trimEnd('.').ifEmpty { throw PeerOffline() }
        // The tailnet's "offline" lags (a node just started lists its peers offline for a while):
        // dialed anyway, and only a dial that fails to a peer listed offline is PeerOffline.
        val listedOffline = peer != null && !peer.online
        return try {
            open(address, device, resume, null, enrolling)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: NetFailure) {
            throw e
        } catch (e: Exception) {
            if (listedOffline) throw PeerOffline() else throw e
        }
    }

    /** First contact with a Mac in its Add device window: the hello carries who this phone is. */
    suspend fun enroll(mac: TailnetNode, enrolling: () -> Unit): LinkSession {
        val me = identity()
        val enroll = NetControl.Enroll(name = me.name, identityKey = me.signer.publicKey, model = me.model, kind = "phone", raiseKey = me.raiseKey)
        return open(mac.address, null, null, enroll, enrolling, NetClientSession.ENROLL_WINDOW_MS)
    }

    private suspend fun open(
        address: String,
        record: Device?,
        resume: NetResume?,
        enroll: NetControl.Enroll?,
        enrolling: () -> Unit,
        windowMs: Long = NetClientSession.CLIENT_WINDOW_MS,
    ): LinkSession {
        val self = withContext(io) { tailnet.self() } ?: throw NetFailure("signedOut")
        val conn = withContext(io) { tailnet.dial(address, Tailnet.PORT, DIAL_MS) }
        val who = withContext(io) { tailnet.whois(address) }
        if (who == null) {
            conn.close()
            throw NetFailure("whois")
        }
        val sameUser = who.userId != null && who.userId == self.userId && who.tags.isEmpty()
        val me = identity()
        val session = NetClientSession(
            local = NetLocal(me.device, self.nodeKey, me.signer),
            route = Binding.TAILNET,
            peer = NetPeerFacts(who.nodeKey, sameUser),
            expected = record?.id,
            record = record,
            ticket = resume?.ticket,
            cursors = resume?.cursors,
            enroll = enroll,
        )
        return NetConnection(conn, session, scope, clock, io).handshake(windowMs) { if (enroll != null) enrolling() }
    }

    companion object {
        /** How long a dial may block (the shim's own cap). */
        const val DIAL_MS = 20_000L
        /** Other Macs tried for one that moved, at most. */
        const val MOVED_TRIES = 4

        /** The node a record names: one of its node keys, else its name. */
        fun known(device: Device, peers: List<TailnetNode>): TailnetNode? =
            peers.firstOrNull { it.nodeKey in device.nodeKeys }
                ?: peers.firstOrNull { device.fqdn.isNotEmpty() && it.dnsName.trimEnd('.') == device.fqdn.trimEnd('.') }

        /**
         * Where a Mac that left its known node may be now: online, untagged macOS nodes of this
         * phone's own user, none the record already holds a key of. Its old name first (a
         * reinstall that kept it), then by name; at most [MOVED_TRIES].
         */
        fun movedMacs(device: Device, peers: List<TailnetNode>, self: TailnetNode?): List<TailnetNode> {
            val user = self?.userId ?: return emptyList()
            val name = device.fqdn.trimEnd('.').substringBefore('.')
            return peers
                .filter { it.os == "macOS" && it.online && it.tags.isEmpty() && it.userId == user && it.nodeKey !in device.nodeKeys && it.nodeKey != self.nodeKey }
                .sortedWith(compareBy({ it.shortName != name && !it.shortName.startsWith("$name-") }, { it.dnsName }))
                .take(MOVED_TRIES)
        }
    }
}
