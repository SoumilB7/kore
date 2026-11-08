package dev.kore.link.net

import dev.kore.link.node.NetResume
import dev.kore.link.node.NodeDialer
import dev.kore.link.node.PeerOffline
import dev.kore.link.trust.Binding
import dev.kore.link.trust.Device
import dev.kore.link.trust.IdentitySigner
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
    /** As the Mac's Allow card shows it: the phone's model name. */
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
        val peer = peers.firstOrNull { it.nodeKey in device.nodeKeys }
            ?: peers.firstOrNull { device.fqdn.isNotEmpty() && it.dnsName.trimEnd('.') == device.fqdn.trimEnd('.') }
        if (peer != null && !peer.online) throw PeerOffline()
        val address = peer?.address ?: device.fqdn.trimEnd('.').ifEmpty { throw PeerOffline() }
        return open(address, device, resume, null, enrolling)
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
    }
}
