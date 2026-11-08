package dev.kore.link.node

import kotlin.random.Random

/**
 * When the phone tries one node (a Mac or a box), as a pure function of what happened and the time:
 * [NodeClient] drives it and the tests run it on virtual time. No periodic pings, no give-up.
 *
 * - Backoff: 1 s, 2 s, 4 s … 300 s, ±20 % jitter; the app opening, a network change or the peer
 *   coming online tries at once.
 * - Away: the node said it sleeps or quits, or the tailnet says it's offline: wait for it to come
 *   back online (or the cap), never a tight loop.
 * - The node's answer to who this phone is: AwaitingAllow (first contact, the owner reads the Mac's
 *   card), Denied (refused), Removed (revoked). A box that doesn't hold this phone yet (`unknown`)
 *   is waiting for its Mac's push: Away(WAITING), tried again on the Mac's directory naming the box,
 *   and by backoff capped at [WAITING_CAP_MS] while the app is on screen (off screen: the directory only).
 * - SignedOut: the phone's tailnet needs a sign-in; nothing dials until it's back.
 */
class NodeMachine(private val random: Random = Random.Default, private val box: Boolean = false) {
    /** WAITING: a box that doesn't hold this phone yet (its Mac's push is on its way). */
    enum class AwayWhy { ASLEEP, OFF, UNREACHABLE, WAITING }

    sealed class State {
        /** Not running: the app is off screen (and background mode off), or KoreNet is off. */
        data object Idle : State()
        data object Connecting : State()
        data object AwaitingAllow : State()
        data object Up : State()
        /** Not reached; tries again at [at] (ms), or sooner on a trigger. [lastSeen]: when it was last up. */
        data class Away(val why: AwayWhy, val at: Long?, val lastSeen: Long?, val attempt: Int = 0) : State()
        data class Denied(val reason: String) : State()
        data object Removed : State()
        data object SignedOut : State()
    }

    sealed class Event {
        data object Start : Event()
        data object Stop : Event()
        /** The hello went out with an enroll: the node's owner has to Allow it. */
        data object Enrolling : Event()
        data object Connected : Event()
        /** The dial or the handshake didn't get through (no bye). */
        data object Failed : Event()
        /** The node's `bye` (handshake or link), or null when the socket just dropped. */
        data class Ended(val reason: String?) : Event()
        /** The tailnet says the peer is offline / back online. */
        data object PeerOffline : Event()
        data object PeerOnline : Event()
        /** The app opened, the network changed, the owner tapped retry. */
        data object Trigger : Event()
        data object SignedOut : Event()
        data object SignedIn : Event()
        /** A Join's welcome from this node: it allows this phone (again, after a revoke or a no). */
        data object Allowed : Event()
        data object Tick : Event()
        /** The app came on screen or went off it: a waiting box keeps its backoff only on screen. */
        data class Screen(val on: Boolean) : Event()
    }

    var state: State = State.Idle
        private set
    private var attempt = 0
    private var lastSeen: Long? = null
    private var onScreen = true

    /** Applies [event] at [now] (ms); a [State.Connecting] means: dial now. */
    fun on(event: Event, now: Long): State {
        val s = state
        state = when (event) {
            Event.Start -> if (s is State.Idle) connecting(reset = true) else s
            Event.Stop -> State.Idle
            Event.Enrolling -> if (s is State.Connecting) State.AwaitingAllow else s
            Event.Connected -> {
                attempt = 0
                lastSeen = now
                State.Up
            }
            Event.Failed -> if (s is State.Connecting || s is State.AwaitingAllow) backoff(now, AwayWhy.UNREACHABLE) else s
            is Event.Ended -> if (s.passive) s else ended(event.reason, now)
            Event.PeerOffline -> when (s) {
                is State.Connecting, is State.Away -> State.Away(AwayWhy.ASLEEP, null, lastSeen)
                else -> s
            }
            Event.PeerOnline -> if (s is State.Away) connecting(reset = true) else s
            Event.Trigger -> when (s) {
                is State.Away, is State.Denied -> connecting(reset = true)
                else -> s
            }
            Event.SignedOut -> if (s is State.Idle || s is State.Removed) s else State.SignedOut
            Event.SignedIn -> if (s is State.SignedOut) connecting(reset = true) else s
            Event.Allowed -> when (s) {
                is State.Removed, is State.Denied, is State.Away, is State.SignedOut -> connecting(reset = true)
                else -> s
            }
            Event.Tick -> if (s is State.Away && s.at != null && now >= s.at) connecting(reset = false) else s
            is Event.Screen -> {
                onScreen = event.on
                if (!event.on && s is State.Away && s.why == AwayWhy.WAITING) s.copy(at = null) else s
            }
        }
        return state
    }

    /** When the driver should next send [Event.Tick], if at all. */
    val wakeAt: Long? get() = (state as? State.Away)?.at

    private val State.passive: Boolean get() = this is State.Idle || this is State.Removed || this is State.SignedOut

    private fun ended(reason: String?, now: Long): State = when (reason) {
        "revoked" -> State.Removed
        // A box that doesn't hold this phone yet: its Mac's push (or the directory naming it) is on its way.
        "unknown" -> if (box) waiting(now) else State.Denied(reason)
        "refused", "proof" -> State.Denied(reason)
        "paused" -> State.Away(AwayWhy.OFF, null, lastSeen)
        "quit", "sleep" -> State.Away(AwayWhy.ASLEEP, now + jitter(CAP_MS), lastSeen)
        // This side gave up on a dead socket (a probe got nothing): dial again at once.
        "abandoned" -> connecting(reset = true)
        else -> if (state is State.AwaitingAllow && reason == null) State.Denied("closed") else backoff(now, AwayWhy.UNREACHABLE)
    }

    private fun connecting(reset: Boolean): State {
        if (reset) attempt = 0
        return State.Connecting
    }

    private fun backoff(now: Long, why: AwayWhy, cap: Long = CAP_MS): State {
        val base = minOf(cap.toDouble(), 1000.0 * (1L shl minOf(attempt, 16)))
        attempt += 1
        return State.Away(why, now + jitter(base.toLong()), lastSeen, attempt)
    }

    /** On screen: tried again by backoff up to [WAITING_CAP_MS]; off screen only a trigger tries it. */
    private fun waiting(now: Long): State =
        if (onScreen) backoff(now, AwayWhy.WAITING, WAITING_CAP_MS) else State.Away(AwayWhy.WAITING, null, lastSeen, attempt)

    private fun jitter(ms: Long): Long = (ms * (0.8 + 0.4 * random.nextDouble())).toLong()

    companion object {
        const val CAP_MS = 300_000L
        /** A box waiting for its Mac's push is tried at least this often while on screen. */
        const val WAITING_CAP_MS = 60_000L
    }
}
