package dev.kore.link.node

import dev.kore.link.net.Tailnet
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * When the phone's tailnet runs (phase 18 §5): KoreNet on, joined or joining, and on screen or mid
 * sign-in. Nothing keeps it up behind the owner's back: off screen (after the app's grace) the
 * links say bye and the tailnet stops. A sign-in ([JoinFlow.signingIn]) keeps it up whatever the
 * screen: tsnet holds the pending node key in memory only, so a stop while the owner is in the
 * browser would finish a sign-in for a key that no longer exists, and the sign-in would loop.
 * Every start and stop goes through [switch]; the join's step changes re-run [apply].
 */
class TailnetKeeper(
    private val tailnet: Tailnet,
    val switch: TailnetSwitch,
    private val join: JoinFlow,
    private val scope: CoroutineScope,
    /** KoreNet on, joined: read fresh on every [apply]. */
    private val settings: () -> Settings,
    /** Up: true once Running (the node clients dial), false when it wants a sign-in. */
    private val onUp: (signedIn: Boolean) -> Unit,
    /** Going down: the node clients stop first. */
    private val onDown: () -> Unit,
    /** A start failed (it's tried again, [RETRY_MS] doubling): the app may say so. */
    private val onTrouble: (Exception) -> Unit = {},
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    data class Settings(val networkOn: Boolean, val joined: Boolean)

    /** Wanted up (the node clients start with it). */
    @Volatile var running = false
        private set
    private var onScreen = false
    private var settle: Job? = null

    init {
        scope.launch { join.step.collect { apply() } }
    }

    /** The app came on screen or went off it (after its grace). */
    fun onScreen(on: Boolean) {
        onScreen = on
        apply()
    }

    /** Runs or stops the tailnet as the screen, the settings and the join say. */
    @Synchronized fun apply() {
        val want = wants(settings(), join.step.value, onScreen)
        if (want == running) return
        running = want
        settle?.cancel()
        if (want) {
            switch.want(true)
            settle = scope.launch {
                var wait = RETRY_MS
                while (true) {
                    try {
                        switch.settle()
                        break
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        onTrouble(e)
                        delay(wait)
                        wait = minOf(wait * 2, RETRY_CAP_MS)
                    }
                }
                // Until it runs (a few seconds from cold): then the node clients dial.
                var waited = 0L
                while (running && waited < UP_WAIT_MS) {
                    when (withContext(io) { tailnet.state() }) {
                        Tailnet.RUNNING -> break
                        Tailnet.NEEDS_LOGIN -> return@launch onUp(false)
                    }
                    delay(POLL_MS)
                    waited += POLL_MS
                }
                if (running) onUp(true)
            }
        } else {
            // The node clients close their links first; their byes get [BYE_MS] to leave before
            // the tailnet under them stops (a peer then logs why, never a dead socket). Coming
            // back on screen within it cancels the stop.
            onDown()
            settle = scope.launch {
                delay(BYE_MS)
                switch.want(false)
                runCatching { switch.settle() }
            }
        }
    }

    /**
     * Join's start: up now, as [apply] decides from the join's step (Starting: wanted), awaited.
     * Throws the start's failure, or when nothing wants it up (KoreNet off).
     */
    suspend fun up() {
        apply()
        switch.settle()
        check(switch.up) { "tailnet: not wanted up" }
    }

    /** Leave KoreNet: down, the node key dropped on the control plane, the local state gone. */
    @Synchronized fun leave(): Job {
        running = false
        settle?.cancel()
        onDown()
        switch.want(false)
        return scope.launch { switch.logout() }
    }

    companion object {
        const val POLL_MS = 250L
        const val UP_WAIT_MS = 30_000L
        const val RETRY_MS = 2_000L
        const val RETRY_CAP_MS = 60_000L
        const val BYE_MS = 500L

        fun wants(s: Settings, step: JoinFlow.Step, onScreen: Boolean): Boolean {
            val signingIn = JoinFlow.signingIn(step)
            val joining = step !is JoinFlow.Step.Join
            return s.networkOn && (s.joined || joining) && (onScreen || signingIn)
        }
    }
}
