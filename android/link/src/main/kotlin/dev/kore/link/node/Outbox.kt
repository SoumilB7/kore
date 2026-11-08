package dev.kore.link.node

/**
 * Commands made while a node is out of reach: kept in order for [ttlMs] each, keyed by their
 * command id so one is never queued twice, and handed back once the link is up. Each entry
 * expires on its own: the owner arms one timer for [nextExpiry] (no polling loop). In memory only.
 */
class Outbox<T>(private val ttlMs: Long = TTL_MS, private val now: () -> Long) {
    private class Entry<T>(val id: String, val at: Long, val item: T)

    private val entries = ArrayList<Entry<T>>()

    /** Queues [item] under [id]; false when that id is already waiting. */
    @Synchronized
    fun add(id: String, item: T): Boolean {
        if (entries.any { it.id == id }) return false
        entries += Entry(id, now(), item)
        return true
    }

    /** Everything still fresh, oldest first, taken out of the queue (expired ones are left for [expire]). */
    @Synchronized
    fun drain(): List<Pair<String, T>> {
        val t = now()
        val fresh = entries.filter { t - it.at < ttlMs }
        entries.removeAll(fresh.toSet())
        return fresh.map { it.id to it.item }
    }

    /** The ids that waited [ttlMs] or more, taken out of the queue. */
    @Synchronized
    fun expire(): List<String> {
        val t = now()
        val old = entries.filter { t - it.at >= ttlMs }
        entries.removeAll(old.toSet())
        return old.map { it.id }
    }

    /** When the oldest entry expires (ms), or null when empty. */
    @Synchronized
    fun nextExpiry(): Long? = entries.minOfOrNull { it.at }?.plus(ttlMs)

    @Synchronized
    fun ids(): Set<String> = entries.mapTo(LinkedHashSet()) { it.id }

    companion object {
        /** The phone's lifetime (phase 18 §1: Mac 24 h, phone 30 s). */
        const val TTL_MS = 30_000L
    }
}
