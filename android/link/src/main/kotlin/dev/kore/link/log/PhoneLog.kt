package dev.kore.link.log

import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * The phone's own diagnostic log, by the Mac's rules (KoreLog): one line per event, an ISO time,
 * a level, the event's name, then `key=value` pairs from [KEYS] only: ids, counts, kinds, states
 * and times, never a message's, a title's or a file's text. A value shaped like a token is
 * redacted. One file a day (UTC), `<yyyy-MM-dd>.log` in [dir]; [TTL_MS] of them are kept (pruned
 * on start and once a day while the app runs), each capped at [FILE_MAX] bytes and all of them at
 * [ALL_MAX], so it never piles up. A Mac or box the phone is linked to asks for it (`logs.get`)
 * to debug the phone without adb.
 *
 *   2026-11-17T10:41:03.118Z info link node=7f3a91c2 state=up ms=412
 *   2026-11-17T10:41:09.502Z error crash class=java.lang.IllegalStateException at=dev.kore.phone.ui.HomeActivity.render:118<…
 */
class PhoneLog(private val dir: File, private val clock: () -> Long = System::currentTimeMillis) {
    @Volatile private var prunedAt = Long.MIN_VALUE / 2

    fun info(event: String, vararg fields: Pair<String, Any?>) = write("info", event, fields)
    fun warn(event: String, vararg fields: Pair<String, Any?>) = write("warn", event, fields)
    fun error(event: String, vararg fields: Pair<String, Any?>) = write("error", event, fields)

    /**
     * An uncaught exception, written at once: its class, its cause's class, and the top of its
     * stack as `Class.method:line` frames. Never its message (it can carry anything).
     */
    fun crash(e: Throwable, thread: String) {
        val frames = e.stackTrace.take(CRASH_FRAMES).joinToString("<") { "${it.className}.${it.methodName}:${it.lineNumber}" }
        write("error", "crash", arrayOf("class" to e.javaClass.name, "cause" to e.cause?.javaClass?.name, "thread" to thread, "at" to frames))
    }

    @Synchronized fun write(level: String, event: String, fields: Array<out Pair<String, Any?>>) {
        val now = clock()
        if (now - prunedAt >= DAY_MS) prune(now)
        val line = line(now, level, event, fields)
        runCatching {
            dir.mkdirs()
            val file = File(dir, name(now))
            if (file.length() >= FILE_MAX) return
            file.appendText(line + "\n")
        }
    }

    /** Files past [TTL_MS], then the oldest past [ALL_MAX] in all, go. */
    @Synchronized fun prune(now: Long = clock()) {
        prunedAt = now
        val files = logs()
        files.filter { now - it.lastModified() > TTL_MS }.forEach { it.delete() }
        var left = logs()
        var total = left.sumOf { it.length() }
        while (total > ALL_MAX && left.isNotEmpty()) {
            total -= left.first().length()
            left.first().delete()
            left = left.drop(1)
        }
    }

    /** Everything kept, oldest first, at most [max] bytes (the newest kept). */
    @Synchronized fun read(max: Int = SEND_MAX): String {
        val all = logs().joinToString("") { runCatching { it.readText() }.getOrDefault("") }
        return if (all.length <= max) all else all.substring(all.length - max).substringAfter('\n')
    }

    private fun logs(): List<File> = (dir.listFiles { f -> f.isFile && NAME.matches(f.name) } ?: emptyArray()).sortedBy { it.name }

    companion object {
        const val DAY_MS = 86_400_000L
        /** What's kept: one day. */
        const val TTL_MS = DAY_MS
        const val FILE_MAX = 512 * 1024L
        const val ALL_MAX = 1024 * 1024L
        /** What one ask sends at most: the newest. */
        const val SEND_MAX = 512 * 1024
        const val CRASH_FRAMES = 14
        private val NAME = Regex("""\d{4}-\d{2}-\d{2}\.log""")
        private val DAY = DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

        /** The keys a line may carry; any other is dropped. */
        val KEYS = setOf(
            "node", "kind", "state", "why", "reason", "code", "ms", "dur_ms", "n", "attempt", "bytes", "screen",
            "step", "version", "from", "to", "class", "cause", "thread", "at", "id", "level", "on", "count", "t",
        )

        /** Keys that hold only class, method and thread names: never redacted. */
        private val CODE_KEYS = setOf("class", "cause", "at", "thread")

        fun name(now: Long): String = DAY.format(Instant.ofEpochMilli(now)) + ".log"

        /** One line, the Mac's shape; a value with a space, quote, `=` or `\` is quoted and escaped. */
        fun line(now: Long, level: String, event: String, fields: Array<out Pair<String, Any?>>): String {
            val sb = StringBuilder(Instant.ofEpochMilli(now).toString()).append(' ').append(level).append(' ').append(event)
            for ((k, v) in fields) {
                if (k !in KEYS || v == null) continue
                // Code names (a crash's classes and frames) aren't tokens; everything else is checked.
                val text = if (k in CODE_KEYS) v.toString().take(2000) else safe(v.toString())
                sb.append(' ').append(k).append('=').append(value(text))
            }
            return sb.toString()
        }

        /** Anything shaped like a token (a long run of base64 or hex with no separators) is redacted. */
        fun safe(v: String): String = TOKEN.replace(v.take(400), "<redacted>")
        private val TOKEN = Regex("""[A-Za-z0-9+/_]{32,}={0,2}""")

        private fun value(v: String): String =
            if (v.isEmpty() || v.any { it == ' ' || it == '"' || it == '=' || it == '\\' || it == '\n' }) {
                "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ") + "\""
            } else v
    }
}
