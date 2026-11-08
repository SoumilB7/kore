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
 *   card), Denied (refused, or a box that doesn't hold this phone yet), Removed (revoked).
 * - SignedOut: the phone's tailnet needs a sign-in; nothing dials until it's back.
 */
class NodeMachine(private val random: Random = Random.Default) {
    enum class AwayWhy { ASLEEP, OFF, UNREACHABLE }

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
        data object Tick : Event()
    }

    var state: State = State.Idle
        private set
    private var attempt = 0
    private var lastSeen: Long? = null

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
            Event.Tick -> if (s is State.Away && s.at != null && now >= s.at) connecting(reset = false) else s
        }
        return state
    }

    /** When the driver should next send [Event.Tick], if at all. */
    val wakeAt: Long? get() = (state as? State.Away)?.at

    private val State.passive: Boolean get() = this is State.Idle || this is State.Removed || this is State.SignedOut

    private fun ended(reason: String?, now: Long): State = when (reason) {
        "revoked" -> State.Removed
        "unknown", "refused", "proof" -> State.Denied(reason)
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

    private fun backoff(now: Long, why: AwayWhy): State {
        val base = minOf(CAP_MS.toDouble(), 1000.0 * (1L shl minOf(attempt, 16)))
        attempt += 1
        return State.Away(why, now + jitter(base.toLong()), lastSeen, attempt)
    }

    private fun jitter(ms: Long): Long = (ms * (0.8 + 0.4 * random.nextDouble())).toLong()

    companion object {
        const val CAP_MS = 300_000L
    }
}
