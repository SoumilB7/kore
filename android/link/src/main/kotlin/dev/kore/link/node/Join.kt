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
    fun candidates(self: TailnetNode, peers: List<TailnetNode>): List<TailnetNode> = peers.filter {
        it.online && it.os.equals("macOS", ignoreCase = true) && it.tags.isEmpty() &&
            it.userId != null && it.userId == self.userId && it.nodeKey != self.nodeKey
    }

    /** Knock every 2 s while the Join screen shows, for at most 2 min; never in the background. */
    const val EVERY_MS = 2_000L
    /** After a Mac answered "Add window closed": within its 3-a-minute pre-auth allowance. */
    const val CLOSED_EVERY_MS = 20_000L
    const val FOR_MS = 120_000L
}

/**
 * The first run (phase 18 §5, korenet-first-connect.html E): Join KoreNet → sign in to Tailscale
 * in a Custom Tab → Finding your Mac… (knocking on the Macs [MacProbe] picks, only while the screen
 * is visible, stopping after 2 min) → Allow on the Mac → Home. A pure flow over a [Tailnet]: the
 * tests run it on a fake one in virtual time.
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
) {
    sealed class Step {
        /** Signed out: one button. [failed]: the last Join couldn't start the tailnet; the button tries again. */
        data class Join(val failed: Boolean = false) : Step()
        /** The tailnet is coming up, or the sign-in page is about to open. */
        data object Starting : Step()
        /** [url] opens in a Custom Tab; never logged. */
        data class SigningIn(val url: String) : Step()
        /** Signed in; [macs] are the Macs seen (none answers yet). [stopped]: the 2 minutes are up. */
        /** [addClosed]: a Mac answered, but its Add device window isn't open (`bye unknown`). */
        data class Finding(val macs: List<String>, val stopped: Boolean = false, val addClosed: Boolean = false) : Step()
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

    /** The Join screen is (or isn't) showing: the knocking runs only while it is; a sign-in goes on. */
    @Synchronized fun visible(on: Boolean) {
        visible = on
        if (on) follow() else if (!signingIn(stepFlow.value)) halt()
    }

    /** "Join KoreNet": starts the tailnet and follows it to signed in, then knocks. */
    @Synchronized fun begin() {
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

    /** "Try again" (Denied, or Finding stopped): knock for another 2 minutes. */
    @Synchronized fun again() {
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
                Tailnet.NEEDS_LOGIN -> withContext(io) { tailnet.authUrl() }?.takeIf { it.isNotEmpty() }?.let { url ->
                    if ((stepFlow.value as? Step.SigningIn)?.url != url) stepFlow.value = Step.SigningIn(url)
                }
                Tailnet.NEEDS_MACHINE_AUTH -> stepFlow.value = Step.NeedsApproval(withContext(io) { tailnet.self() }?.nodeKey)
            }
            offlineFlow.value = !withContext(io) { tailnet.online() }
            delay(STATE_EVERY_MS)
        }
    }

    /** Knocks for [MacProbe.FOR_MS]; false when the tailnet went away under it. */
    private suspend fun knock(): Boolean {
        val started = clock()
        stepFlow.value = Step.Finding(emptyList())
        while (visible && clock() - started < MacProbe.FOR_MS) {
            val self = withContext(io) { tailnet.self() } ?: return false
            val macs = MacProbe.candidates(self, withContext(io) { tailnet.peers() })
            (stepFlow.value as? Step.Finding)?.let { stepFlow.value = it.copy(macs = macs.map { m -> m.shortName }) }
            for (mac in macs) {
                val link = try {
                    enroll(mac) { stepFlow.value = Step.Allowing(mac.shortName, self) }
                } catch (e: NetFailure) {
                    val reason = dev.kore.link.net.NetControl.Companion.Reason
                    if (e.reason == "bye ${reason.UNKNOWN}") {
                        // Listening for its allowed phones, but its Add device window isn't open.
                        stepFlow.value = Step.Finding(macs.map { it.shortName }, addClosed = true)
                    } else if (stepFlow.value is Step.Allowing || e.reason.startsWith("bye ")) {
                        // Heard, and said no, or its card went unanswered: either ends the knocking.
                        stepFlow.value = Step.Denied(mac.shortName, timedOut = e.reason == "bye ${reason.TIMEOUT}")
                        return true
                    }
                    null
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Not listening (its Add device window is closed): the next Mac, then again.
                    null
                }
                if (link != null) {
                    joined(link)
                    stepFlow.value = Step.Joined(link.peer.record)
                    return true
                }
            }
            // A Mac that said its Add window is closed is asked again only every 20 s: its pre-auth
            // allowance is 3 a minute per device, and a faster knock would lock this phone out for a
            // minute just as the owner opens the window.
            val closed = (stepFlow.value as? Step.Finding)?.addClosed == true
            delay(if (closed) MacProbe.CLOSED_EVERY_MS else MacProbe.EVERY_MS)
        }
        if (!visible) return true
        val self = withContext(io) { tailnet.self() }
        val any = self != null && MacProbe.candidates(self, withContext(io) { tailnet.peers() }).isNotEmpty()
        stepFlow.value = if (any) ((stepFlow.value as? Step.Finding) ?: Step.Finding(emptyList())).copy(stopped = true) else Step.NoMac(self?.login)
        return true
    }

    companion object {
        /** How often the tailnet's state is read while signing in. */
        const val STATE_EVERY_MS = 1_000L
        /** Away from the Join screen this long mid sign-in: given up, back to Join. */
        const val AWAY_MS = 10 * 60_000L

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
