package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject

/**
 * A chat's work as the transcript shows it (the Mac's working rows, minimal): runs of tool,
 * thinking and sub-agent entries fold into "Worked · N steps". While a turn runs, only its
 * current step stays out, one quiet line by the spinner (the latest thought, or a tool's short
 * name · target); the steps before it fold. When the turn ends the whole run folds. Built from
 * the entries the link already sent: nothing is polled or timed.
 */
object LiveWork {
    private val WORK = setOf("tool", "thinking", "agent")

    sealed class Fold {
        data class One(val e: JsonObject) : Fold()
        data class Work(val key: String, val steps: List<JsonObject>, val open: Boolean) : Fold()
        /** The running turn's current step: one line, by the spinner. */
        data class Live(val e: JsonObject) : Fold()
        /** The turn runs and nothing of it shows yet: the spinner on its own line. */
        object Pending : Fold()
    }

    /** [entries] in order; [open]: the folds opened here (by their first step's id); [running]: a turn runs. */
    fun fold(entries: List<JsonObject>, open: Set<String>, running: Boolean): List<Fold> {
        val out = ArrayList<Fold>()
        var run = ArrayList<JsonObject>()
        fun flush(last: Boolean) {
            if (run.isEmpty()) return
            val key = run.first().str("id") ?: ""
            when {
                last && running -> {
                    val head = run.dropLast(1)
                    if (head.isNotEmpty()) {
                        out.add(Fold.Work(key, head, key in open))
                        if (key in open) head.forEach { out.add(Fold.One(it)) }
                    }
                    out.add(Fold.Live(run.last()))
                }
                run.size < 2 -> run.forEach { out.add(Fold.One(it)) }
                key in open -> { out.add(Fold.Work(key, run.toList(), true)); run.forEach { out.add(Fold.One(it)) } }
                else -> out.add(Fold.Work(key, run.toList(), false))
            }
            run = ArrayList()
        }
        for (e in entries) {
            if (e.str("kind") in WORK) run.add(e) else { flush(false); out.add(Fold.One(e)) }
        }
        val tailRun = run.isNotEmpty()
        flush(true)
        // A turn under way with nothing of it on screen (just sent, or between steps after a
        // finished answer): the spinner says so. A streaming answer says so itself.
        val last = entries.lastOrNull()
        if (running && !tailRun && !(last?.str("kind") in setOf("answer", "plan") && last?.bool("done") == false)) out.add(Fold.Pending)
        return out
    }

    /** A live step's words: what it is, and what it's on (null for a thought, which is all words). */
    data class Line(val what: String, val on: String?, val thought: Boolean = false)

    fun line(e: JsonObject): Line = when (e.str("kind")) {
        "thinking" -> Line(latestThought(e.str("text")) ?: "Thinking…", null, thought = true)
        "agent" -> Line("Agent", e.obj("agent")?.str("name")?.takeIf { it.isNotBlank() })
        else -> {
            val tool = e.obj("tool")
            Line(tool?.str("name")?.takeIf { it.isNotBlank() } ?: "Tool", target(tool?.str("summary") ?: tool?.str("path")))
        }
    }

    /** The newest line of a thought, trimmed: what it's thinking now. */
    fun latestThought(text: String?): String? = text?.lineSequence()?.map { it.trim() }?.lastOrNull { it.isNotEmpty() }

    /** A tool's target, short: a path's last part ("Chat.swift"), else its first line ("git status"). */
    fun target(summary: String?): String? {
        val first = summary?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim() ?: return null
        val path = !first.contains(' ') && first.contains('/') && !first.endsWith("/")
        return if (path) first.substringAfterLast('/') else first
    }
}
