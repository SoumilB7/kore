package dev.kore.link.node

import dev.kore.link.net.Tailnet
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The one way the phone's tailnet starts and stops. Every start and stop runs in turn under one
 * lock, never cancelled halfway, and after each the wanted state is read again: a blocking stop
 * that lands after a newer start can't leave the tailnet off while the app thinks it's on.
 * [want] is set at once by whoever decides (in order); [settle] brings the tailnet there.
 */
class TailnetSwitch(private val tailnet: Tailnet, private val io: CoroutineDispatcher = Dispatchers.IO) {
    private val lock = Mutex()
    @Volatile private var wanted = false
    /** What the last finished start or stop left. */
    @Volatile var up = false
        private set

    fun want(on: Boolean) {
        wanted = on
    }

    /** [want] then [settle]: returns once it's there; throws the start's failure. */
    suspend fun set(on: Boolean) {
        want(on)
        settle()
    }

    /** Runs starts and stops until the tailnet is as last wanted; a failed start throws (and stays down). */
    suspend fun settle() = lock.withLock { settleLocked() }

    private suspend fun settleLocked() {
        while (true) {
            // Read once: a [want] between the check and the run would start a tailnet that's
            // already up (or stop one that's down).
            val target = wanted
            if (up == target) break
            withContext(NonCancellable + io) {
                if (target) tailnet.start() else tailnet.stop()
                up = target
            }
        }
    }

    /**
     * Leave KoreNet: the node logged out on the control plane ([Tailnet.logout]). Down afterwards,
     * then as wanted by then (a Join pressed straight after signs the same node in again).
     */
    suspend fun logout() = lock.withLock {
        withContext(NonCancellable + io) {
            runCatching { tailnet.logout() }
            up = false
        }
        settleLocked()
    }
}
