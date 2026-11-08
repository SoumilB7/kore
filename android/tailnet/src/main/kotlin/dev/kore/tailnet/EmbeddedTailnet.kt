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

    @Synchronized
    override fun start() {
        if (running) return
        watchNetwork()
        Go.setBinder(object : Binder {
            override fun bindSocket(fd: Long) {
                val network = current ?: return
                // A dup of the socket: binding it binds the socket; the dup goes, the socket stays.
                ParcelFileDescriptor.fromFd(fd.toInt()).use { network.bindSocket(it.fileDescriptor) }
            }
        })
        val dir = File(context.noBackupFilesDir, "tailnet").apply { mkdirs() }
        Go.start(dir.path, hostname, KeystoreSealer)
        running = true
    }

    @Synchronized
    override fun stop() {
        if (!running) return
        running = false
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
        runCatching { Go.stop() }
        Go.setBinder(null)
    }

    @Synchronized
    override fun logout() {
        if (running) runCatching { Go.logout() }
        stop()
        File(context.noBackupFilesDir, "tailnet").deleteRecursively()
        KeystoreSealer.forget()
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

    private fun changed() {
        feed()
        if (running) Go.networkChanged()
        onNetworkChanged()
    }

    private fun feed() {
        runCatching { Go.setInterfaces(interfaces().toString()) }
    }

    /** Every network ConnectivityManager knows, as the shim's rows; the default one marked, with its IPv4 gateway. */
    private fun interfaces(): JSONArray {
        val rows = JSONArray()
        val active = current
        for (network in connectivity.allNetworks) {
            val lp = connectivity.getLinkProperties(network) ?: continue
            val name = lp.interfaceName ?: continue
            val ni = runCatching { NetworkInterface.getByName(name) }.getOrNull()
            val gateway = lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress
            rows.put(JSONObject().apply {
                put("name", name)
                put("index", ni?.index ?: 0)
                put("mtu", ni?.mtu?.takeIf { it > 0 } ?: lp.mtu.takeIf { it > 0 } ?: 1500)
                put("up", ni?.isUp ?: true)
                put("broadcast", false)
                put("loopback", ni?.isLoopback ?: false)
                put("pointToPoint", ni?.isPointToPoint ?: false)
                put("multicast", ni?.supportsMulticast() ?: false)
                put("addrs", JSONArray(lp.linkAddresses.map { "${it.address.hostAddress?.substringBefore('%')}/${it.prefixLength}" }))
                put("default", network == active)
                put("gateway", gateway ?: "")
            })
        }
        return rows
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

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    override fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return c.iv + c.doFinal(plain)
    }

    override fun open(sealed: ByteArray): ByteArray {
        require(sealed.size > IV) { "short" }
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV)) }
        return c.doFinal(sealed, IV, sealed.size - IV)
    }

    fun forget() {
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
    }
}
