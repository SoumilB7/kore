package dev.kore.phone

import android.os.Build
import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetDialer
import dev.kore.link.net.PhoneIdentity
import dev.kore.link.net.Tailnet
import dev.kore.link.node.JoinFlow
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeMachine
import dev.kore.link.node.SingleFlight
import dev.kore.link.trust.Device
import dev.kore.link.trust.DeviceBook
import dev.kore.link.trust.NodeKind
import dev.kore.phone.background.MeshService
import dev.kore.phone.background.Notifier
import dev.kore.phone.link.IdentityKey
import dev.kore.phone.link.RaiseKey
import dev.kore.tailnet.EmbeddedTailnet
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * The phone on KoreNet (phase 18 §5): its embedded tailnet, its identity, the devices it knows
 * (a [DeviceBook] in no-backup storage) and one [NodeClient] per device. The tailnet and the node
 * clients run only while the app is on screen — or, with the background setting on (off by
 * default), under [MeshService]'s foreground notification. KoreNet off: nothing runs at all.
 */
class Mesh(private val app: KoreApp) {
    private val prefs = app.getSharedPreferences("kore", android.content.Context.MODE_PRIVATE)

    val tailnet: Tailnet by lazy { EmbeddedTailnet(app, hostname()).also { it.onNetworkChanged = { nodes.value.forEach(NodeClient::reconnectNow) } } }
    val raiseKey = RaiseKey({ app.frontActivity }, ::renewRaiseKey)
    private val raiseSigner = SingleFlight(raiseKey)

    /** Kore's id for this phone: made on joining, kept across sign-ins and Tailscale's re-logins; a new one after Leave. */
    val deviceId: UUID
        get() = prefs.getString("device", null)?.let(UUID::fromString) ?: UUID.randomUUID().also { prefs.edit().putString("device", it.toString()).apply() }

    private fun identity() =
        PhoneIdentity(deviceId, IdentityKey, Build.MODEL ?: "Android", Build.MODEL ?: "Android", runCatching { raiseKey.publicKey }.getOrNull())

    private val bookFile = File(app.noBackupFilesDir, "devices.json")
    val book = DeviceBook(load(), ::save)
    val dialer by lazy { NetDialer(tailnet, ::identity, app.scope) }
    val join by lazy { JoinFlow(tailnet, dialer::enroll, app.scope, ::joined) }

    private val nodesFlow = MutableStateFlow<List<NodeClient>>(emptyList())
    /** One client per known device, Macs first. */
    val nodes: StateFlow<List<NodeClient>> = nodesFlow.asStateFlow()
    private val notifiers = HashMap<UUID, Pair<Notifier, Job>>()

    /** Joined: a Mac allowed this phone and is pinned. */
    val joined: Boolean get() = book.all().any { it.kind == NodeKind.MAC }

    /** KoreNet on this phone (Settings → Devices); off = the tailnet stopped, no dials. */
    var networkOn: Boolean
        get() = prefs.getBoolean("network", true)
        set(on) {
            prefs.edit().putBoolean("network", on).apply()
            apply()
        }

    /** Background mode (off by default): a foreground service keeps the links while the app is closed. */
    var background: Boolean
        get() = prefs.getBoolean("background", false)
        set(on) {
            prefs.edit().putBoolean("background", on).apply()
            apply()
        }

    private var onScreen = false
    private var running = false
    private var settle: Job? = null

    init {
        syncNodes()
    }

    fun node(id: UUID?): NodeClient? = nodesFlow.value.firstOrNull { it.id == id } ?: if (id == null) nodesFlow.value.firstOrNull() else null
    fun node(id: String?): NodeClient? = node(id?.let { runCatching { UUID.fromString(it) }.getOrNull() })
    /** Two or more devices: notifications name theirs. */
    val many: Boolean get() = nodesFlow.value.size > 1

    /** The app came on screen or went off it. */
    fun onScreen(on: Boolean) {
        onScreen = on
        apply()
        nodesFlow.value.forEach { if (on) it.reconnectNow() else it.setPresence(false) }
    }

    /** Runs or stops the tailnet and the node clients as the screen and the settings say. */
    @Synchronized fun apply() {
        val want = networkOn && joined && (onScreen || background)
        if (background && networkOn && joined) MeshService.start(app) else MeshService.stop(app)
        if (want == running) return
        running = want
        settle?.cancel()
        if (want) {
            settle = app.scope.launch {
                tailnet.start()
                // Until it runs (a few seconds from cold): then the node clients dial.
                var waited = 0
                while (running && tailnet.state() != Tailnet.RUNNING && waited < 30_000) {
                    if (tailnet.state() == Tailnet.NEEDS_LOGIN) return@launch nodesFlow.value.forEach { it.start(); it.post(NodeMachine.Event.SignedOut) }
                    delay(250)
                    waited += 250
                }
                nodesFlow.value.forEach { it.start(); it.post(NodeMachine.Event.SignedIn) }
            }
        } else {
            nodesFlow.value.forEach(NodeClient::stop)
            settle = app.scope.launch { tailnet.stop() }
        }
    }

    /** The Mac answered the Join flow with its welcome: pin it, take its directory, follow it. */
    private fun joined(link: LinkSession) {
        val mac = link.peer.record
        book.put(mac)
        link.peer.directory?.mapNotNull(Device::fromJson)?.let { book.applyDirectory(mac.id, deviceId, it) }
        // The first link is the join's: end it, the node client makes its own.
        link.close()
        syncNodes()
        apply()
    }

    /** A client for every device in the book, none for those gone. */
    @Synchronized fun syncNodes() {
        val devices = book.all().sortedBy { if (it.kind == NodeKind.MAC) 0 else 1 }
        val have = nodesFlow.value.associateBy { it.id }
        val next = devices.map { d ->
            have[d.id] ?: NodeClient(
                d, app.scope, dialer, raiseSigner = raiseSigner,
                onRecord = { book.put(it) },
                onDirectory = { records -> book.applyDirectory(d.id, deviceId, records); syncNodes() },
            ).also { client ->
                if (running) client.start()
                val notifier = Notifier(app, d.id.toString()) { if (many) client.name else null }
                notifiers[d.id] = notifier to app.scope.launch { client.attention.collect { notifier.handle(it, client.chatOnScreen) } }
            }
        }
        (have.keys - next.map { it.id }.toSet()).forEach { id ->
            have[id]?.close()
            notifiers.remove(id)?.let { (n, job) -> job.cancel(); n.clearAll() }
        }
        nodesFlow.update { next }
    }

    /**
     * A new `kore_raise` (a fingerprint enrolled on the phone): its public half to every Mac (a box
     * learns it from its Mac); each says on screen once its owner answered.
     */
    private fun renewRaiseKey(pub: ByteArray) {
        for (node in nodesFlow.value.filter { it.device.value.kind == NodeKind.MAC }) app.scope.launch {
            say("New fingerprint: Allow it on ${node.name}")
            val r = node.raiseKey(pub)
            say(if (r["ok"]?.toString() == "true") "${node.name} took the new fingerprint" else "${node.name} didn't take the new fingerprint")
        }
    }

    private fun say(text: String) {
        val a = app.frontActivity ?: return
        a.runOnUiThread { dev.kore.phone.ui.Quiet.say(a, text) }
    }

    /** Forgets one device (a box that was removed, a Mac that revoked this phone). */
    fun forget(id: UUID) {
        book.remove(id)
        syncNodes()
        if (!joined) apply()
    }

    /** Leave KoreNet: the tailnet signs out, every device and key here goes; back to Join. */
    fun leave() {
        nodesFlow.value.forEach(NodeClient::close)
        notifiers.values.forEach { (n, job) -> job.cancel(); n.clearAll() }
        notifiers.clear()
        nodesFlow.value = emptyList()
        book.clear()
        running = false
        MeshService.stop(app)
        app.scope.launch { tailnet.logout() }
        IdentityKey.forget()
        raiseKey.forget()
        prefs.edit().remove("device").apply()
        join.cancel()
    }

    private fun hostname(): String =
        "kore-" + (Build.MODEL ?: "phone").lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').take(40)

    private fun load(): List<Device> = runCatching {
        (Json.parseToJsonElement(bookFile.readText()) as JsonArray).mapNotNull { (it as? JsonObject)?.let(Device::fromJson) }
    }.getOrDefault(emptyList())

    private fun save(devices: List<Device>) {
        runCatching {
            val tmp = File(bookFile.path + ".tmp")
            tmp.writeText(JsonArray(devices.map { it.toJson() }).toString())
            tmp.renameTo(bookFile)
        }
    }
}
