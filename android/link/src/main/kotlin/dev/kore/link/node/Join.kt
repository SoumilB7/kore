package dev.kore.link.node

import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetFailure
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.trust.Device
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Which tailnet peers the Join screen knocks on (UX pass, 2026-11-14): Macs of this phone's own
 * user that are online, untagged, and not this node. Only those get a dial to :47470.
 */
object MacProbe {
    fun candidates(self: TailnetNode, peers: List<TailnetNode>): List<TailnetNode> = macs(self, peers).filter { it.online }

    /** This user's Macs the tailnet lists offline (asleep, Tailscale off): not knocked, but named (A6). */
    fun asleep(self: TailnetNode, peers: List<TailnetNode>): List<TailnetNode> = macs(self, peers).filter { !it.online }

    private fun macs(self: TailnetNode, peers: List<TailnetNode>): List<TailnetNode> = peers.filter {
        it.os.equals("macOS", ignoreCase = true) && it.tags.isEmpty() &&
            it.userId != null && it.userId == self.userId && it.nodeKey != self.nodeKey
    }

    /** Knock every 2 s while the Join screen shows, never in the background. */
    const val EVERY_MS = 2_000L
    /** After a Mac answered "Add window closed": within its 3-a-minute pre-auth allowance. */
    const val CLOSED_EVERY_MS = 20_000L
    /** As long as the Mac's Add device window lasts (10 min), so a window opened late is still found. */
    const val FOR_MS = 600_000L
}

/**
 * The first run (phase 18 §5, korenet-first-connect.html E): Join KoreNet → sign in to Tailscale
 * in a Custom Tab → Finding your Mac… (knocking on the Macs [MacProbe] picks, only while the screen
 * is visible, for as long as the Mac's Add device window lasts) → Allow on the Mac → Home. A pure
 * flow over a [Tailnet]: the tests run it on a fake one in virtual time.
 *
 * Mid sign-in ([signingIn]) the browser is in front and this screen isn't: the tailnet's state is
 * still read (the app keeps the tailnet up and a short foreground service holds the process), so a
 * sign-in finished in the browser shows as signed in at once, and the knocking starts on return.
 */
class JoinFlow(
    private val tailnet: Tailnet,
    /** First contact with one Mac: the enroll handshake (the app's `NetDialer.enroll`). */
    private val enroll: suspend (TailnetNode, enrolling: () -> Unit) -> LinkSession,
    private val scope: CoroutineScope,
    /** The Mac answered with its welcome: pin it, keep its directory, go Home. */
    private val joined: (LinkSession) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** Brings the tailnet up for Join (the app's [TailnetSwitch]); throws when it can't. */
    private val start: suspend () -> Unit = { withContext(io) { tailnet.start() } },
    /** Stops and starts the tailnet: a node signed out mid-run (key expiry) offers its sign-in URL only from a fresh start. */
    private val restart: suspend () -> Unit = { withContext(io) { tailnet.stop(); tailnet.start() } },
) {
    sealed class Step {
        /** Signed out: one button. [failed]: the last Join couldn't start the tailnet; the button tries again. */
        data class Join(val failed: Boolean = false) : Step()
        /** The tailnet is coming up, or the sign-in page is about to open. */
        data object Starting : Step()
        /** [url] opens in a Custom Tab; never logged. */
        data class SigningIn(val url: String) : Step()
        /** Signed in; [macs] are the Macs seen (none answers yet). [stopped]: the 10 minutes are up. */
        /** [addClosed]: a Mac answered, but its Add device window isn't open (`bye unknown`); [closedOn] names it. */
        /** [asleep]: this user's Macs the tailnet lists offline (not knocked; the owner wakes one). */
        data class Finding(
            val macs: List<String>,
            val stopped: Boolean = false,
            val addClosed: Boolean = false,
            val closedOn: String? = null,
            val asleep: List<String> = emptyList(),
        ) : Step()
        /** The hello went to [mac]; its owner reads the card. [self] is what that card shows of this phone. */
        data class Allowing(val mac: String, val self: TailnetNode) : Step()
        /** The Mac's owner said no (`bye refused`), or its card went unanswered ([timedOut], `bye timeout`). */
        data class Denied(val mac: String, val timedOut: Boolean = false) : Step()
        /** No Mac of this account on the tailnet: probably the wrong account. */
        data class NoMac(val login: String?) : Step()
        /** The tailnet wants this node approved or signed (Tailnet Lock) before it's on. */
        data class NeedsApproval(val nodeKey: String?) : Step()
        data class Joined(val mac: Device) : Step()
    }

    private val stepFlow = MutableStateFlow<Step>(Step.Join())
    val step: StateFlow<Step> = stepFlow.asStateFlow()
    private val offlineFlow = MutableStateFlow(false)
    /** Mid sign-in with no network (airplane mode, no signal): the screen says so; it goes on when back. */
    val offline: StateFlow<Boolean> = offlineFlow.asStateFlow()
    /** The sign-in URL to open in the browser, once each. */
    val tab = SignInTab()
    @Volatile private var visible = false
    private var job: Job? = null
    /** Signing in again on a joined phone (key expiry, signed out): no knocking once signed in. */
    @Volatile private var reauth = false

    /** The Join screen is (or isn't) showing: the knocking runs only while it is; a sign-in goes on. */
    @Synchronized fun visible(on: Boolean) {
        visible = on
        if (on) follow() else if (!signingIn(stepFlow.value)) halt()
    }

    /** "Join KoreNet": starts the tailnet and follows it to signed in, then knocks. */
    @Synchronized fun begin() {
        reauth = false
        launchSignIn()
    }

    /**
     * "Sign in" on a joined phone that is signed out of Tailscale (A1): the sign-in again, whatever
     * step an earlier Join in this process left; once signed in it's [Step.Finding] with no knock,
     * and the screen goes Home.
     */
    @Synchronized fun signInAgain() {
        reauth = true
        launchSignIn()
    }

    private fun launchSignIn() {
        halt()
        tab.reset()
        offlineFlow.value = false
        stepFlow.value = Step.Starting
        job = scope.launch {
            try {
                start()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                stepFlow.value = Step.Join(failed = true)
                return@launch
            }
            run()
        }
    }

    /** "Try again" (Denied, or Finding stopped): knock for another 10 minutes. */
    @Synchronized fun again() {
        reauth = false
        halt()
        stepFlow.value = Step.Finding(emptyList())
        if (visible) follow()
    }

    /** Back to Join. */
    @Synchronized fun cancel() {
        halt()
        tab.reset()
        offlineFlow.value = false
        stepFlow.value = Step.Join()
    }

    private fun follow() {
        val s = stepFlow.value
        if (job?.isActive != true && s !is Step.Join && s !is Step.Joined && s !is Step.Denied) job = scope.launch { run() }
    }

    private fun halt() {
        job?.cancel()
        job = null
    }

    private suspend fun run() {
        while (true) {
            if (!signedIn()) return
            if (reauth) {
                stepFlow.value = Step.Finding(emptyList())
                return
            }
            if (!visible) {
                // Signed in from the browser while away: say so; the knocking waits for the screen.
                if (signingIn(stepFlow.value)) stepFlow.value = Step.Finding(emptyList())
                return
            }
            // false: the tailnet went away mid-knock (stopped, signed out): wait for it again.
            if (knock()) return
        }
    }

    /**
     * Until signed in: the tailnet's own state, read while the screen shows and, mid sign-in, while
     * it doesn't (at most [AWAY_MS] away, then back to Join). False when it stops waiting.
     */
    private suspend fun signedIn(): Boolean {
        var away: Long? = null
        var noUrl = 0
        while (true) {
            if (!visible) {
                if (!signingIn(stepFlow.value)) return false
                val now = clock()
                val since = away ?: now.also { away = it }
                if (now - since >= AWAY_MS) {
                    tab.reset()
                    offlineFlow.value = false
                    stepFlow.value = Step.Join()
                    return false
                }
            } else {
                away = null
            }
            when (withContext(io) { tailnet.state() }) {
                Tailnet.RUNNING -> {
                    offlineFlow.value = false
                    return true
                }
                Tailnet.NEEDS_LOGIN -> {
                    val url = withContext(io) { tailnet.authUrl() }?.takeIf { it.isNotEmpty() }
                    if (url != null) {
                        noUrl = 0
                        if ((stepFlow.value as? Step.SigningIn)?.url != url) stepFlow.value = Step.SigningIn(url)
                    } else if (++noUrl == NO_URL_RESTART) {
                        // Signed out while running (a key that expired): only a fresh start asks control for a URL.
                        runCatching { restart() }
                    }
                }
                Tailnet.NEEDS_MACHINE_AUTH -> stepFlow.value = Step.NeedsApproval(withContext(io) { tailnet.self() }?.nodeKey)
            }
            offlineFlow.value = !withContext(io) { tailnet.online() }
            delay(STATE_EVERY_MS)
        }
    }

    /** One Mac's answer to a knock. */
    private sealed class Answer(val mac: TailnetNode) {
        class Welcome(mac: TailnetNode, val link: LinkSession) : Answer(mac)
        /** Listening for its phones, but its Add device window isn't open (`bye unknown`). */
        class Closed(mac: TailnetNode) : Answer(mac)
        /** Heard, and said no, or its card went unanswered. */
        class No(mac: TailnetNode, val timedOut: Boolean) : Answer(mac)
        /** Not listening (KoreNet off there, or not reached). */
        class Missed(mac: TailnetNode) : Answer(mac)
    }

    /**
     * Knocks for [MacProbe.FOR_MS]; false when the tailnet went away under it. Every Mac is knocked
     * at once (T-A7): the first welcome wins and the rest are cancelled; one Mac's no is final only
     * when no other Mac is still deciding. A Mac whose Add window is closed is asked every 20 s,
     * the others every 2 s.
     */
    private suspend fun knock(): Boolean {
        val started = clock()
        stepFlow.value = Step.Finding(emptyList())
        val next = HashMap<String, Long>()
        var closedOn: String? = null
        while (visible && clock() - started < MacProbe.FOR_MS) {
            val self = withContext(io) { tailnet.self() } ?: return false
            val peers = withContext(io) { tailnet.peers() }
            val macs = MacProbe.candidates(self, peers)
            val asleep = MacProbe.asleep(self, peers).map { it.shortName }
            (stepFlow.value as? Step.Finding)?.let { stepFlow.value = it.copy(macs = macs.map { m -> m.shortName }, asleep = asleep) }
            val now = clock()
            val due = macs.filter { (next[it.nodeKey] ?: 0L) <= now }
            val answers = askAll(due, self)
            answers.filterIsInstance<Answer.Welcome>().firstOrNull()?.let { w ->
                // Read before [joined]: it ends the link, and a closed link has no peer.
                val record = w.link.peer.record
                joined(w.link)
                stepFlow.value = Step.Joined(record)
                return true
            }
            answers.filterIsInstance<Answer.No>().firstOrNull()?.let { no ->
                stepFlow.value = Step.Denied(no.mac.shortName, timedOut = no.timedOut)
                return true
            }
            for (a in answers) next[a.mac.nodeKey] = clock() + if (a is Answer.Closed) MacProbe.CLOSED_EVERY_MS else MacProbe.EVERY_MS
            answers.filterIsInstance<Answer.Closed>().firstOrNull()?.let { closedOn = it.mac.shortName }
            if (closedOn != null) (stepFlow.value as? Step.Finding)?.let { stepFlow.value = it.copy(addClosed = true, closedOn = closedOn) }
            val wake = (macs.mapNotNull { next[it.nodeKey] }.minOrNull() ?: (clock() + MacProbe.EVERY_MS)) - clock()
            delay(wake.coerceIn(MacProbe.EVERY_MS / 4, MacProbe.CLOSED_EVERY_MS))
        }
        if (!visible) return true
        val self = withContext(io) { tailnet.self() }
        val peers = if (self != null) withContext(io) { tailnet.peers() } else emptyList()
        // No Mac with Kore here only when this user has no Mac on the tailnet at all; one asleep keeps Finding (A6).
        val any = self != null && (MacProbe.candidates(self, peers).isNotEmpty() || MacProbe.asleep(self, peers).isNotEmpty())
        stepFlow.value = if (any) ((stepFlow.value as? Step.Finding) ?: Step.Finding(emptyList())).copy(stopped = true) else Step.NoMac(self?.login)
        return true
    }

    /**
     * Knocks on [macs] at once. Returns as soon as one welcomes this phone (the others are
     * cancelled, a welcome that lands after it is closed), else once every knock has answered.
     * A Mac's no waits for the Macs still deciding: their Allow wins over it.
     */
    private suspend fun askAll(macs: List<TailnetNode>, self: TailnetNode): List<Answer> {
        if (macs.isEmpty()) return emptyList()
        val winner = java.util.concurrent.atomic.AtomicReference<LinkSession?>(null)
        val out = java.util.Collections.synchronizedList(ArrayList<Answer>())
        kotlinx.coroutines.coroutineScope {
            val done = kotlinx.coroutines.channels.Channel<Answer>(kotlinx.coroutines.channels.Channel.UNLIMITED)
            val jobs = macs.map { mac ->
                launch {
                    var heard = false
                    val answer = try {
                        val link = enroll(mac) {
                            heard = true
                            stepFlow.value = Step.Allowing(mac.shortName, self)
                        }
                        if (winner.compareAndSet(null, link)) Answer.Welcome(mac, link) else { link.close(); Answer.Missed(mac) }
                    } catch (e: NetFailure) {
                        val reason = dev.kore.link.net.NetControl.Companion.Reason
                        when {
                            e.reason == "bye ${reason.UNKNOWN}" -> Answer.Closed(mac)
                            heard || e.reason.startsWith("bye ") -> Answer.No(mac, timedOut = e.reason == "bye ${reason.TIMEOUT}")
                            else -> Answer.Missed(mac)
                        }
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Answer.Missed(mac)
                    }
                    done.send(answer)
                }
            }
            repeat(macs.size) {
                val a = done.receive()
                out += a
                if (a is Answer.Welcome) {
                    jobs.forEach { it.cancel() }
                    return@coroutineScope
                }
            }
        }
        // A Mac left asking (Allowing) while another one's no came first: back to Finding.
        if (out.none { it is Answer.Welcome } && stepFlow.value is Step.Allowing && out.none { it is Answer.No }) {
            stepFlow.value = Step.Finding(macs.map { it.shortName })
        }
        return out.toList()
    }

    companion object {
        /** How often the tailnet's state is read while signing in. */
        const val STATE_EVERY_MS = 1_000L
        /** Away from the Join screen this long mid sign-in: given up, back to Join. */
        const val AWAY_MS = 10 * 60_000L
        /** Signed out with no sign-in URL for this many reads: the tailnet is started afresh once. */
        const val NO_URL_RESTART = 3

        /** A step's name for the phone's log (written out: R8 renames the classes in a release build). */
        fun label(s: Step): String = when (s) {
            is Step.Join -> if (s.failed) "join-failed" else "join"
            Step.Starting -> "starting"
            is Step.SigningIn -> "signing-in"
            is Step.Finding -> if (s.stopped) "finding-stopped" else if (s.addClosed) "finding-closed" else "finding"
            is Step.Allowing -> "allowing"
            is Step.Denied -> if (s.timedOut) "timed-out" else "denied"
            is Step.NoMac -> "no-mac"
            is Step.NeedsApproval -> "needs-approval"
            is Step.Joined -> "joined"
        }

        /** Mid sign-in: the tailnet holds a node key only in memory; stopping it now loses that sign-in. */
        fun signingIn(s: Step): Boolean = s is Step.Starting || s is Step.SigningIn || s is Step.NeedsApproval
    }
}

/**
 * Which sign-in URL the Join screen opens in the browser: each new one once. A new Join, a
 * Cancel, or any step but SigningIn lets the same URL open again. Kept with the flow, not the
 * screen, so a screen rebuilt under the browser doesn't open it a second time.
 */
class SignInTab {
    private var opened: String? = null

    /** The URL to open now for [s], or null. */
    @Synchronized fun toOpen(s: JoinFlow.Step): String? = when (s) {
        is JoinFlow.Step.SigningIn -> if (opened == s.url) null else s.url.also { opened = it }
        else -> {
            opened = null
            null
        }
    }

    @Synchronized fun reset() {
        opened = null
    }
}
