package dev.kore.link.node

import kotlin.random.Random

/**
 * When the phone tries one node (a Mac or a box), as a pure function of what happened and the time:
 * [NodeClient] drives it and the tests run it on virtual time. No periodic pings, no give-up.
 *
 * - Backoff: 1 s, 2 s, 4 s … 300 s, ±20 % jitter; the app opening, a network change or the peer
 *   coming online tries at once.
 * - Away: a Mac said it sleeps (ASLEEP), the tailnet says the node is offline (OFFLINE), or it
 *   doesn't answer (UNREACHABLE): each tried again by the same backoff, never a tight loop and never
 *   a wait with no end. The tailnet's offline is a hint (its list lags a start), not a reason to stop.
 * - The node's answer to who this phone is: AwaitingAllow (first contact, the owner reads the Mac's
 *   card), Denied (refused), Removed (revoked). A box that doesn't hold this phone yet (`unknown`)
 *   is waiting for its Mac's push: Away(WAITING), tried again on the Mac's directory naming the box,
 *   and by backoff capped at [WAITING_CAP_MS] while the app is on screen (off screen: the directory only).
 * - A Mac whose KoreNet was switched off (`bye off`) is Away(NET_OFF), not Denied: tried again the
 *   same way (backoff capped at [WAITING_CAP_MS] on screen; off screen on the app opening or a network
 *   change), its refused dials meanwhile kept as NET_OFF. `refused` (the owner's Deny) stays Denied.
 * - SignedOut: the phone's tailnet needs a sign-in; nothing dials until it's back.
 */
class NodeMachine(private val random: Random = Random.Default, private val box: Boolean = false) {
    /**
     * ASLEEP: a Mac said `bye sleep` (only a Mac sleeps). OFFLINE: the tailnet lists the node
     * offline. UNREACHABLE: it didn't answer. OFF: an owner Mac took this phone offline (`paused`).
     * WAITING: a box that doesn't hold this phone yet (its Mac's push is on its way). NET_OFF: the
     * Mac's KoreNet is switched off.
     */
    enum class AwayWhy { ASLEEP, OFFLINE, OFF, UNREACHABLE, WAITING, NET_OFF }

    sealed class State {
        /** Not running: the app is off screen, or KoreNet is off. */
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
    /** After a `restart`: the next of [RESTART_MS] waits, until it's up again or they're spent. */
    private var quick: Int? = null
    private var lastSeen: Long? = null
    private var onScreen = true
    /** The node last said its KoreNet went off: dials it refuses meanwhile are that, not unreachable. */
    private var netOff = false

    /** Applies [event] at [now] (ms); a [State.Connecting] means: dial now. */
    fun on(event: Event, now: Long): State {
        val s = state
        state = when (event) {
            Event.Start -> if (s is State.Idle) connecting(reset = true) else s
            Event.Stop -> State.Idle
            Event.Enrolling -> if (s is State.Connecting) State.AwaitingAllow else s
            Event.Connected -> {
                attempt = 0
                quick = null
                netOff = false
                lastSeen = now
                State.Up
            }
            Event.Failed -> when {
                s !is State.Connecting && s !is State.AwaitingAllow -> s
                netOff -> slowly(now, AwayWhy.NET_OFF)
                else -> backoff(now, AwayWhy.UNREACHABLE)
            }
            is Event.Ended -> if (s.passive) s else ended(event.reason, now)
            Event.PeerOffline -> when (s) {
                is State.Connecting, is State.Away -> backoff(now, AwayWhy.OFFLINE)
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
                if (!event.on && s is State.Away && (s.why == AwayWhy.WAITING || s.why == AwayWhy.NET_OFF)) s.copy(at = null) else s
            }
        }
        return state
    }

    /** When the driver should next send [Event.Tick], if at all. */
    val wakeAt: Long? get() = (state as? State.Away)?.at

    private val State.passive: Boolean get() = this is State.Idle || this is State.Removed || this is State.SignedOut

    private fun ended(reason: String?, now: Long): State {
        netOff = reason == "off"
        return endedFor(reason, now)
    }

    private fun endedFor(reason: String?, now: Long): State = when (reason) {
        "revoked" -> State.Removed
        // A box that doesn't hold this phone yet: its Mac's push (or the directory naming it) is on its way.
        // A Mac in the book that no longer knows this phone removed it while the app was closed (A4):
        // the same story as a live `revoked`, never "not allowed" (the Join flow keeps its own words).
        "unknown" -> if (box) waiting(now) else State.Removed
        "refused", "proof" -> State.Denied(reason)
        // The Mac's identity key changed (Kore 0.3.7 made a new one): pair again, never retried.
        "key-changed", "bye key-changed" -> State.Denied("key-changed")
        // The Mac's KoreNet switched off: back by itself once it's on again.
        "off" -> slowly(now, AwayWhy.NET_OFF)
        "paused" -> State.Away(AwayWhy.OFF, null, lastSeen)
        // A Mac brought this phone online again (its parked link ends so): dial straight back.
        "online" -> connecting(reset = true)
        // A Mac going to sleep says so; it's tried again on the cap (or at once when the app opens).
        "sleep" -> State.Away(AwayWhy.ASLEEP, now + jitter(CAP_MS), lastSeen)
        "quit" -> State.Away(AwayWhy.UNREACHABLE, now + jitter(CAP_MS), lastSeen)
        // kore-host restarting (an update, a service restart): back within seconds, tried at
        // 1 s, 2 s, 5 s, then the usual backoff. A peer that predates it says something else.
        "restart" -> {
            attempt = 0
            quick = 0
            backoff(now, AwayWhy.UNREACHABLE)
        }
        // This side gave up on a dead socket (a probe got nothing): dial again at once.
        "abandoned" -> connecting(reset = true)
        else -> if (state is State.AwaitingAllow && reason == null) State.Denied("closed") else backoff(now, AwayWhy.UNREACHABLE)
    }

    private fun connecting(reset: Boolean): State {
        if (reset) attempt = 0
        return State.Connecting
    }

    private fun backoff(now: Long, why: AwayWhy, cap: Long = CAP_MS): State {
        quick?.let { i ->
            if (i < RESTART_MS.size) {
                quick = i + 1
                return State.Away(why, now + RESTART_MS[i], lastSeen, attempt)
            }
            quick = null
        }
        val base = minOf(cap.toDouble(), 1000.0 * (1L shl minOf(attempt, 16)))
        attempt += 1
        return State.Away(why, now + jitter(base.toLong()), lastSeen, attempt)
    }

    /** On screen: tried again by backoff up to [WAITING_CAP_MS]; off screen only a trigger tries it. */
    private fun waiting(now: Long): State = slowly(now, AwayWhy.WAITING)

    private fun slowly(now: Long, why: AwayWhy): State =
        if (onScreen) backoff(now, why, WAITING_CAP_MS) else State.Away(why, null, lastSeen, attempt)

    private fun jitter(ms: Long): Long = (ms * (0.8 + 0.4 * random.nextDouble())).toLong()

    companion object {
        /** A state's name for the phone's log: written out, as R8 renames classes in a release build. */
        /** An away reason's name for the log (written out: R8 may rename enum constants). */
        fun label(why: AwayWhy): String = when (why) {
            AwayWhy.ASLEEP -> "asleep"
            AwayWhy.OFFLINE -> "offline"
            AwayWhy.OFF -> "taken-offline"
            AwayWhy.UNREACHABLE -> "unreachable"
            AwayWhy.WAITING -> "waiting"
            AwayWhy.NET_OFF -> "net-off"
        }

        fun label(s: State): String = when (s) {
            State.Idle -> "idle"
            State.Connecting -> "connecting"
            State.AwaitingAllow -> "allowing"
            State.Up -> "up"
            is State.Away -> "away"
            is State.Denied -> "denied"
            State.Removed -> "removed"
            State.SignedOut -> "signed-out"
        }
        const val CAP_MS = 300_000L
        /** A box waiting for its Mac's push is tried at least this often while on screen. */
        const val WAITING_CAP_MS = 60_000L
        /** The waits after a node said `restart`, before the usual backoff. */
        val RESTART_MS = longArrayOf(1_000L, 2_000L, 5_000L)
    }
}
