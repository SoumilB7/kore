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
import dev.kore.link.node.TailnetKeeper
import dev.kore.link.node.TailnetSwitch
import dev.kore.link.trust.Device
import dev.kore.link.trust.DeviceBook
import dev.kore.link.trust.NodeKind
import dev.kore.phone.background.Notifier
import dev.kore.phone.background.SignInService
import dev.kore.phone.link.IdentityKey
import dev.kore.phone.link.RaiseKey
import dev.kore.tailnet.EmbeddedTailnet
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
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
 * clients run while the app is on screen, a short while after it ([TailnetKeeper.LINGER_MS], the
 * links kept quiet so coming back is instant, longer while a followed chat works), or mid sign-in
 * (under [SignInService]). No service or wake lock keeps them: past that, nothing links, dials or
 * works in the background. KoreNet off: nothing runs at all. When is [TailnetKeeper]'s; every start and stop goes through its switch.
 */
class Mesh(private val app: KoreApp) {
    private val prefs = app.getSharedPreferences("kore", android.content.Context.MODE_PRIVATE)

    /** A stand-in's (a debug build's demo), else the phone's own embedded one. */
    private val standIn = StandIns.current
    val tailnet: Tailnet by lazy {
        standIn?.tailnet ?: EmbeddedTailnet(app, hostname()).also { it.onNetworkChanged = { nodes.value.forEach(NodeClient::reconnectNow) } }
    }
    val raiseKey = RaiseKey({ app.frontActivity }, ::renewRaiseKey)
    private val raiseSigner = SingleFlight(raiseKey)

    /** Kore's id for this phone: made on joining, kept across sign-ins and Tailscale's re-logins; a new one after Leave. */
    val deviceId: UUID
        get() = prefs.getString("device", null)?.let(UUID::fromString) ?: UUID.randomUUID().also { prefs.edit().putString("device", it.toString()).apply() }

    /** The name the Mac's card and rows show (the phone's own, not its model code); the model stays the model. */
    val name: String by lazy { PhoneName.of(app) }

    private fun identity() =
        PhoneIdentity(deviceId, IdentityKey, name, Build.MODEL ?: "Android", runCatching { raiseKey.publicKey }.getOrNull())

    private val bookFile = File(app.noBackupFilesDir, "devices.json")
    val book = DeviceBook(standIn?.devices ?: load()) { if (standIn == null) save(it) }
    val dialer by lazy { NetDialer(tailnet, ::identity, app.scope) }
    private val switch by lazy { TailnetSwitch(tailnet) }
    val join by lazy {
        JoinFlow(tailnet, dialer::enroll, app.scope, ::joined, start = {
            // Join pressed straight after Leave: the old node signs out first.
            leaving?.join()
            // Join pressed with KoreNet off (turned off, then Leave): Join turns it on.
            if (!networkOn) prefs.edit().putBoolean("network", true).apply()
            keeper.up()
        }, restart = { switch.set(false); switch.set(true) })
    }
    private val keeper: TailnetKeeper by lazy {
        // Mid Leave the tailnet stays up until the Macs heard.
        TailnetKeeper(tailnet, switch, join, app.scope, { TailnetKeeper.Settings(networkOn, inBook) },
            onUp = { signedIn ->
                app.log.info("tailnet", "state" to if (signedIn) "up" else "signed-out")
                troubled = false
                nodesFlow.value.forEach { it.start(); it.post(if (signedIn) NodeMachine.Event.SignedIn else NodeMachine.Event.SignedOut) }
                // A node waiting for its peer hears it come online (the tailnet's bus, no poll).
                if (peerFollow == null) peerFollow = peerWatch.follow(nodes)
            },
            onDown = {
                app.log.info("tailnet", "state" to "down")
                peerFollow?.cancel()
                peerFollow = null
                peerWatch.stop()
                nodesFlow.value.forEach(NodeClient::stop)
            },
            onTrouble = { e ->
                android.util.Log.w("kore", "tailnet: start failed (${e::class.simpleName}), trying again")
                app.log.warn("tailnet", "state" to "start-failed", "class" to e.javaClass.name)
                // Once per spell of failures; it keeps trying by itself.
                if (!troubled && joined) say("Tailscale didn't start · trying again")
                troubled = true
            },
            realtime = android.os.SystemClock::elapsedRealtime,
            keep = { nodesFlow.value.any(NodeClient::followsWork) })
    }
    @Volatile private var troubled = false
    private val peerWatch by lazy { dev.kore.link.node.PeerWatch(tailnet, app.scope, { nodesFlow.value }) }
    @Volatile private var peerFollow: kotlinx.coroutines.Job? = null

    private val nodesFlow = MutableStateFlow<List<NodeClient>>(emptyList())
    /** One client per known device, Macs first. */
    val nodes: StateFlow<List<NodeClient>> = nodesFlow.asStateFlow()
    private val notifiers = HashMap<UUID, Pair<Notifier, Job>>()

    /** Joined: a Mac allowed this phone and is pinned (not while leaving). */
    val joined: Boolean get() = leaving?.isActive != true && inBook

    private val inBook: Boolean get() = book.all().any { it.kind == NodeKind.MAC }

    /** Leave under way: the Macs are told, then the tailnet signs out. */
    @Volatile private var leaving: Job? = null

    /** KoreNet on this phone (Settings → Devices); off = the tailnet stopped, no dials. */
    var networkOn: Boolean
        get() = prefs.getBoolean("network", true)
        set(on) {
            prefs.edit().putBoolean("network", on).apply()
            apply()
        }

    private var onScreen = false

    init {
        syncNodes()
        keeper.running // made now: it follows the join's steps from the first one
        // A sign-in that ended (signed in, cancelled, given up): its foreground service goes.
        app.scope.launch {
            join.step.collect {
                app.log.info("join", "step" to JoinFlow.label(it))
                if (!JoinFlow.signingIn(it)) SignInService.stop(app)
            }
        }
    }

    fun node(id: UUID?): NodeClient? = nodesFlow.value.firstOrNull { it.id == id } ?: if (id == null) nodesFlow.value.firstOrNull() else null
    fun node(id: String?): NodeClient? = node(id?.let { runCatching { UUID.fromString(it) }.getOrNull() })
    /** The Mac that tells boxes about this phone, by name (the first Mac known). */
    fun ownerName(): String = nodesFlow.value.firstOrNull { it.device.value.kind == NodeKind.MAC }?.name ?: "your Mac"

    /**
     * What [n] last said it does (its welcome's `caps`), kept across launches: before this
     * launch's first welcome the menus stay as they were, not as an unknown device's.
     */
    fun caps(n: NodeClient?): Set<String> =
        if (n == null) emptySet() else dev.kore.phone.ui.Offers.caps(n.welcome.value, prefs.getStringSet(capsKey(n.id), null))

    private fun capsKey(id: UUID) = "caps.$id"

    /** The Mac this phone joined through, as rows name it ("waiting for MacBook"). */
    val macName: String get() = ownerName()

    /**
     * The Mac a device's words name: a Mac itself, or for a box the Mac whose directory lists it
     * (its [Device.via]), else the first Mac (T-A1/T-A3: never Mac A for Mac B's box).
     */
    fun macFor(n: NodeClient): String {
        val d = n.device.value
        if (d.kind == NodeKind.MAC) return n.name
        return d.via.firstNotNullOfOrNull { id -> nodesFlow.value.firstOrNull { it.id == id }?.name } ?: ownerName()
    }
    /** Two or more devices: notifications name theirs. */
    val many: Boolean get() = nodesFlow.value.size > 1

    /** The app came on screen or went off it. */
    fun onScreen(on: Boolean) {
        onScreen = on
        keeper.onScreen(on)
        if (on) apply()
        // Signed out while the tailnet kept running (a key that expired): every device says Sign in (A3).
        if (on && keeper.running) app.scope.launch {
            if (runCatching { tailnet.state() }.getOrNull() == Tailnet.NEEDS_LOGIN) nodesFlow.value.forEach { it.post(NodeMachine.Event.SignedOut) }
        }
        nodesFlow.value.forEach {
            if (on) {
                it.post(NodeMachine.Event.Screen(true))
                it.resume()
            } else {
                it.setPresence(false)
            }
        }
    }

    /**
     * "Join KoreNet": a short foreground service first, while the app is still in front (Android
     * 12+ refuses one started from the background), so the process lives through the browser.
     */
    fun beginJoin() {
        SignInService.start(app)
        join.begin()
    }

    /** Runs or stops the tailnet and the node clients as the screen and the settings say. */
    fun apply() {
        keeper.apply()
    }

    /** The Mac answered the Join flow with its welcome: pin it, take its directory, follow it. */
    private fun joined(link: LinkSession) {
        val mac = link.peer.record
        book.put(mac)
        link.peer.directory?.mapNotNull(Device::fromJson)?.let { book.applyDirectory(mac.id, deviceId, it) }
        // The first link is the join's: end it, the node client makes its own.
        link.close()
        syncNodes()
        // Joined again with a client already here (it was removed, or refused): it starts over.
        node(mac.id)?.allowed(mac)
        apply()
    }

    /** A client for every device in the book, none for those gone. */
    @Synchronized fun syncNodes() {
        val devices = book.all().sortedBy { if (it.kind == NodeKind.MAC) 0 else 1 }
        val have = nodesFlow.value.associateBy { it.id }
        val next = devices.map { d ->
            have[d.id]?.also { if (it.device.value != d) it.recordChanged(d) } ?: NodeClient(
                d, app.scope, standIn?.dialer ?: dialer, raiseSigner = raiseSigner,
                onRecord = { book.put(it) },
                onDirectory = { records ->
                    book.applyDirectory(d.id, deviceId, records)
                    syncNodes()
                    // A box the Mac names now holds this phone, or can be reached: tried again at once.
                    val named = records.filter { it.kind == NodeKind.BOX }.map { it.id }.toSet()
                    nodesFlow.value.filter { it.id in named }.forEach(NodeClient::named)
                    // The Mac took this phone back (brought online): boxes that said `paused` hear it too.
                    nodesFlow.value.filter { it.device.value.kind == NodeKind.BOX && (it.state.value as? NodeMachine.State.Away)?.why == NodeMachine.AwayWhy.OFF }
                        .forEach { it.post(NodeMachine.Event.Trigger) }
                },
                logs = { app.log.read() },
                onLogsAsked = {
                    app.log.info("logs", "node" to shortId(d.id), "kind" to "asked")
                    say("Kore asked for this phone's logs")
                },
                // Back on screen to the node heard again: on the kept link, a new one, or from cold.
                onResumed = { ms, how -> app.log.info("resume", "node" to shortId(d.id), "ms" to ms, "kind" to how) },
            ).also { client ->
                // Each change of state, one line: which device (8 hex of its id), what, and why.
                app.scope.launch {
                    client.state.collect { s ->
                        app.log.info("node", "node" to shortId(d.id), "kind" to d.kind.wire, "state" to NodeMachine.label(s),
                            "why" to (s as? NodeMachine.State.Away)?.why?.let(NodeMachine::label), "reason" to (s as? NodeMachine.State.Denied)?.reason,
                            "attempt" to (s as? NodeMachine.State.Away)?.attempt)
                    }
                }
                // Each welcome's caps kept for the next cold start (only when they changed).
                app.scope.launch {
                    client.welcome.collect { w ->
                        if (w == null) return@collect
                        val caps = dev.kore.phone.ui.Offers.caps(w)
                        if (prefs.getStringSet(capsKey(d.id), null) != caps) prefs.edit().putStringSet(capsKey(d.id), caps).apply()
                    }
                }
                if (keeper.running) client.start()
                val notifier = Notifier(app, d.id.toString()) { if (many) client.name else null }
                notifiers[d.id] = notifier to app.scope.launch { client.attention.collect { notifier.handle(it, client.chatOnScreen) } }
            }
        }
        (have.keys - next.map { it.id }.toSet()).forEach { id ->
            have[id]?.close()
            prefs.edit().remove(capsKey(id)).apply()
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

    /** A device in the log: the first 8 hex of its id, never its name. */
    private fun shortId(id: UUID): String = id.toString().take(8)

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

    /**
     * Leave KoreNet: each linked Mac hears it first (it forgets this phone at once, its boxes with
     * it; at most [NodeClient.LEAVE_MS]), then the tailnet signs out and every device and key here
     * goes; back to Join. A Mac out of reach retires the old record itself on the next Allow.
     */
    fun leave() {
        if (leaving?.isActive == true) return
        val macs = nodesFlow.value.filter { it.device.value.kind == NodeKind.MAC }
        // The owner left (Settings or Join's Leave): the log says so, so a sign-out and a new
        // device after it never read as a spontaneous reset.
        app.log.info("join", "step" to "leave", "n" to macs.size)
        join.cancel()
        leaving = app.scope.launch {
            coroutineScope { macs.forEach { launch { it.leave() } } }
            forgetAll()
        }
    }

    private fun forgetAll() {
        val devices = book.all().size
        nodesFlow.value.forEach(NodeClient::close)
        notifiers.values.forEach { (n, job) -> job.cancel(); n.clearAll() }
        notifiers.clear()
        nodesFlow.value = emptyList()
        book.clear()
        keeper.leave()
        IdentityKey.forget()
        raiseKey.forget()
        prefs.edit().remove("device").apply()
        // What Leave cleared: the tailnet's login (logged out on Tailscale's side, the node kept for
        // a re-join), this phone's Kore identity and fingerprint keys, and its device book.
        app.log.info("leave", "state" to "cleared", "kind" to "tailnet-logout,identity,raise-key,device-book", "count" to devices)
    }

    /** This install's own id: made once, kept through Leave and re-joins (gone only with the app's data). */
    private val installId: String
        get() = prefs.getString("install", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("install", it).apply() }

    private fun hostname(): String = hostnameFor(Build.MODEL, installId)

    companion object {
        /**
         * The phone's tailnet name, unique and stable per install: "kore-cph2381-7f3a". Two phones
         * of one model never share it, so Tailscale never adds "-1", and a "-1" never means "the
         * same phone again" (T-A8).
         */
        fun hostnameFor(model: String?, install: String): String {
            val m = (model ?: "phone").lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').take(24).ifEmpty { "phone" }
            val tag = install.lowercase().filter { it in "0123456789abcdef" }.take(4).padEnd(4, '0')
            return "kore-$m-$tag"
        }
    }

    private fun load(): List<Device> = runCatching {
        (Json.parseToJsonElement(bookFile.readText()) as JsonArray).mapNotNull { (it as? JsonObject)?.let(Device::fromJson) }
    }.getOrDefault(emptyList())

    private fun save(devices: List<Device>) {
        runCatching {
            val tmp = File(bookFile.path + ".tmp")
            tmp.writeText(JsonArray(devices.map { it.toJson(local = true) }).toString())
            tmp.renameTo(bookFile)
        }
    }
}
