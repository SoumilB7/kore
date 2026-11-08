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
    const val FOR_MS = 120_000L
}

/**
 * The first run (phase 18 §5, korenet-first-connect.html E): Join KoreNet → sign in to Tailscale
 * in a Custom Tab → Finding your Mac… (knocking on the Macs [MacProbe] picks, only while the screen
 * is visible, stopping after 2 min) → Allow on the Mac → Home. A pure flow over a [Tailnet]: the
 * tests run it on a fake one in virtual time.
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
) {
    sealed class Step {
        /** Signed out: one button. */
        data object Join : Step()
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

    private val stepFlow = MutableStateFlow<Step>(Step.Join)
    val step: StateFlow<Step> = stepFlow.asStateFlow()
    private var visible = false
    private var job: Job? = null

    /** The Join screen is (or isn't) showing: the knocking runs only while it is. */
    fun visible(on: Boolean) {
        visible = on
        if (!on) {
            job?.cancel()
            job = null
        } else if (stepFlow.value !is Step.Join && stepFlow.value !is Step.Joined && stepFlow.value !is Step.Denied && job == null) {
            job = scope.launch { run() }
        }
    }

    /** "Join KoreNet": starts the tailnet and follows it to signed in, then knocks. */
    fun begin() {
        stepFlow.value = Step.Starting
        job?.cancel()
        job = scope.launch {
            withContext(io) { tailnet.start() }
            run()
        }
    }

    /** "Try again" (Denied, or Finding stopped): knock for another 2 minutes. */
    fun again() {
        stepFlow.value = Step.Finding(emptyList())
        job?.cancel()
        job = if (visible) scope.launch { run() } else null
    }

    /** Back to Join, the tailnet left as it is. */
    fun cancel() {
        job?.cancel()
        job = null
        stepFlow.value = Step.Join
    }

    private suspend fun run() {
        // Until signed in: the tailnet's own state, read while the screen shows.
        while (visible || stepFlow.value == Step.Starting) {
            when (withContext(io) { tailnet.state() }) {
                Tailnet.RUNNING -> break
                Tailnet.NEEDS_LOGIN -> withContext(io) { tailnet.authUrl() }?.takeIf { it.isNotEmpty() }?.let { url ->
                    if ((stepFlow.value as? Step.SigningIn)?.url != url) stepFlow.value = Step.SigningIn(url)
                }
                Tailnet.NEEDS_MACHINE_AUTH -> stepFlow.value = Step.NeedsApproval(withContext(io) { tailnet.self() }?.nodeKey)
            }
            delay(STATE_EVERY_MS)
        }
        if (!visible) return
        knock()
    }

    private suspend fun knock() {
        val started = clock()
        stepFlow.value = Step.Finding(emptyList())
        while (visible && clock() - started < MacProbe.FOR_MS) {
            val self = withContext(io) { tailnet.self() } ?: return run { stepFlow.value = Step.Join }
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
                        return
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
                    return
                }
            }
            delay(MacProbe.EVERY_MS)
        }
        if (!visible) return
        val self = withContext(io) { tailnet.self() }
        val any = self != null && MacProbe.candidates(self, withContext(io) { tailnet.peers() }).isNotEmpty()
        stepFlow.value = if (any) ((stepFlow.value as? Step.Finding) ?: Step.Finding(emptyList())).copy(stopped = true) else Step.NoMac(self?.login)
    }

    companion object {
        /** How often the tailnet's state is read while signing in (on screen only). */
        const val STATE_EVERY_MS = 1_000L
    }
}
