package dev.kore.tailnet

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.ParcelFileDescriptor
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import dev.kore.link.net.ByteConn
import dev.kore.link.net.NetRow
import dev.kore.link.net.NetRows
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.tailnet.bind.tailnet.Binder
import dev.kore.tailnet.bind.tailnet.Sealer
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject
import dev.kore.tailnet.bind.tailnet.Tailnet as Go

/**
 * The phone's own Tailscale node (phase 18 §5), in-process: no VPN, no other app. Runs only
 * between [start] and [stop] — the app holds it while on screen (and, with background mode on,
 * under its foreground service). Its state sits in no-backup storage sealed by a Keystore AES key;
 * ConnectivityManager feeds it the interfaces and the default route, and every outside socket is
 * bound to the current network. Every call may block: never on the main thread.
 */
class EmbeddedTailnet(private val context: Context, private val hostname: String) : Tailnet {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    @Volatile private var current: Network? = null
    @Volatile private var running = false
    private var callback: ConnectivityManager.NetworkCallback? = null
    /** Network changes (Wi-Fi ↔ mobile data): the node clients probe their links. */
    @Volatile var onNetworkChanged: () -> Unit = {}

    override fun state(): String = if (running) Go.state() else "Stopped"
    override fun authUrl(): String? = if (running) Go.authURL().ifEmpty { null } else null
    override fun self(): TailnetNode? = if (running) TailnetNode.parse(Go.self()) else null
    override fun peers(): List<TailnetNode> = if (running) TailnetNode.parseList(Go.peers()) else emptyList()
    override fun whois(ip: String): TailnetNode? = if (running) TailnetNode.parse(Go.whoIs(ip)) else null

    override fun dial(address: String, port: Int, timeoutMs: Long): ByteConn {
        check(running) { "tailnet off" }
        val host = if (':' in address) "[$address]" else address
        val fd = Go.dial("$host:$port").toInt()
        return FdConn(ParcelFileDescriptor.adoptFd(fd))
    }

    /** Throws when the node can't start (its state didn't open, the shim refused): nothing is left registered. */
    @Synchronized
    override fun start() {
        if (running) return
        watchNetwork()
        try {
            Go.setBinder(object : Binder {
                override fun bindSocket(fd: Long) {
                    val network = current ?: return
                    // A dup of the socket: binding it binds the socket; the dup goes, the socket stays.
                    ParcelFileDescriptor.fromFd(fd.toInt()).use { network.bindSocket(it.fileDescriptor) }
                }
            })
            val dir = File(context.noBackupFilesDir, "tailnet").apply { mkdirs() }
            Go.start(dir.path, hostname, KeystoreSealer)
        } catch (e: Exception) {
            unwatchNetwork()
            runCatching { Go.setBinder(null) }
            android.util.Log.w("kore", "tailnet: didn't start (${e::class.simpleName})")
            throw e
        }
        running = true
    }

    /** A network to reach control on right now: the phone isn't offline (airplane mode, no signal). */
    override fun online(): Boolean = runCatching {
        val n = connectivity.activeNetwork ?: return false
        connectivity.getNetworkCapabilities(n)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }.getOrDefault(true)

    @Synchronized
    override fun stop() {
        if (!running) return
        running = false
        unwatchNetwork()
        runCatching { Go.stop() }
        Go.setBinder(null)
    }

    @Synchronized
    override fun logout() {
        // tsnet's Logout tells control to expire this node's key (it stays listed as logged out)
        // and drops the login here; a stopped node is started for it, or control never hears.
        // The state dir and its Keystore key stay: its machine key is what makes the next sign-in
        // the same node again rather than a new one with a "-1" name.
        val was = running
        if (!was) runCatching { start() }
        if (running) runCatching { Go.logout() }
        stop()
    }

    /** The default network's every change goes to Go: interfaces, default route, then an event. */
    private fun watchNetwork() {
        current = connectivity.activeNetwork
        feed()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { current = network; changed() }
            override fun onLost(network: Network) { if (current == network) current = null; changed() }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) { current = network; changed() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = Unit
        }
        connectivity.registerDefaultNetworkCallback(cb)
        callback = cb
    }

    private fun unwatchNetwork() {
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
    }

    private fun changed() {
        feed()
        if (running) Go.networkChanged()
        onNetworkChanged()
    }

    private var saidEmpty = false

    private fun feed() {
        val rows = runCatching { interfaces() }.getOrDefault(emptyList())
        if (rows.isEmpty() && !saidEmpty) android.util.Log.w("kore", "tailnet: no network interfaces (offline?); control waits for one")
        saidEmpty = rows.isEmpty()
        runCatching { Go.setInterfaces(JSONArray(rows.map { it.json() }).toString()) }
    }

    /**
     * Every network ConnectivityManager knows, the default one marked with its IPv4 gateway. Some
     * phones list none (or none with an interface name) for a moment: then the active network
     * alone, then java.net's own list, so tsnet always has a way to control ([NetRows.pick]).
     */
    @Suppress("DEPRECATION") // allNetworks: the one list of every network without a callback per network.
    private fun interfaces(): List<NetRow> {
        val active = current ?: connectivity.activeNetwork
        val all = runCatching { connectivity.allNetworks.toList() }.getOrDefault(emptyList()).mapNotNull { row(it, it == active) }
        return NetRows.pick(all, { active?.let { row(it, true) } }, ::javaRows)
    }

    private fun row(network: Network, default: Boolean): NetRow? {
        val lp = runCatching { connectivity.getLinkProperties(network) }.getOrNull() ?: return null
        val name = lp.interfaceName ?: return null
        val ni = runCatching { NetworkInterface.getByName(name) }.getOrNull()
        val gateway = lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress
        return NetRow(
            name = name,
            index = ni?.index ?: 0,
            mtu = ni?.mtu?.takeIf { it > 0 } ?: lp.mtu.takeIf { it > 0 } ?: 1500,
            up = ni?.isUp ?: true,
            loopback = ni?.isLoopback ?: false,
            pointToPoint = ni?.isPointToPoint ?: false,
            multicast = ni?.supportsMulticast() ?: false,
            addrs = lp.linkAddresses.map { "${it.address.hostAddress?.substringBefore('%')}/${it.prefixLength}" },
            default = default,
            gateway = gateway ?: "",
        )
    }

    /** java.net's interfaces, up and with an address, loopback left out. */
    private fun javaRows(): List<NetRow> = runCatching {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }.map { ni ->
            NetRow(
                name = ni.name, index = ni.index, mtu = ni.mtu.takeIf { it > 0 } ?: 1500, up = true, loopback = false,
                pointToPoint = ni.isPointToPoint, multicast = ni.supportsMulticast(),
                addrs = ni.interfaceAddresses.map { "${it.address.hostAddress?.substringBefore('%')}/${it.networkPrefixLength}" },
                default = false, gateway = "",
            )
        }
    }.getOrDefault(emptyList())

    private fun NetRow.json() = JSONObject().apply {
        put("name", name)
        put("index", index)
        put("mtu", mtu)
        put("up", up)
        put("broadcast", false)
        put("loopback", loopback)
        put("pointToPoint", pointToPoint)
        put("multicast", multicast)
        put("addrs", JSONArray(addrs))
        put("default", default)
        put("gateway", gateway)
    }

    private class FdConn(private val pfd: ParcelFileDescriptor) : ByteConn {
        override val input: InputStream = FileInputStream(pfd.fileDescriptor)
        override val output: OutputStream = FileOutputStream(pfd.fileDescriptor)
        // shutdown first: a read blocked on the socket wakes (close alone doesn't), and Go's end sees EOF.
        override fun close() {
            runCatching { android.system.Os.shutdown(pfd.fileDescriptor, android.system.OsConstants.SHUT_RDWR) }
            runCatching { pfd.close() }
        }
    }
}

/**
 * tsnet's state at rest, sealed with a Keystore AES-GCM key that never leaves the Keystore. No
 * user authentication (the node runs while the phone is locked), and never
 * `setUnlockedDeviceRequired` (OnePlus refused it).
 */
object KeystoreSealer : Sealer {
    private const val ALIAS = "kore_tailnet_state"
    private const val IV = 12
    /** The shim's `Lost` (store.go): this state can never open again, so it starts signed out. */
    private const val LOST = "sealer: lost"

    /**
     * The key, made only when the Keystore says for sure there's none ([create], sealing). A lookup
     * that throws is the Keystore failing for a moment: it propagates, never a new key that would
     * orphan the state sealed under the old one.
     */
    private fun key(create: Boolean): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (ks.containsAlias(ALIAS)) return ks.getKey(ALIAS, null) as? SecretKey ?: throw java.security.KeyStoreException("sealer: key unreadable")
        if (!create) throw IllegalStateException("$LOST (no key)")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    override fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(create = true)) }
        return c.iv + c.doFinal(plain)
    }

    override fun open(sealed: ByteArray): ByteArray {
        if (sealed.size <= IV) throw IllegalStateException("$LOST (short)")
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, sealed, 0, IV)) }
        return try {
            c.doFinal(sealed, IV, sealed.size - IV)
        } catch (e: javax.crypto.AEADBadTagException) {
            // Sealed under another key: no retry ever opens it.
            throw IllegalStateException("$LOST (other key)")
        }
    }

    fun forget() {
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
    }
}
