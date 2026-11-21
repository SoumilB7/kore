package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject

/**
 * A box's folders as the ＋ sheet's Window half walks them: from the box user's home, one level at
 * a time (`fs.list`, subfolders only), up and into, a new folder made where it stands (`fs.mkdir`),
 * and Open here (`folder.add`). Each folder read is kept while the sheet lives (the last
 * [KEEP]), so going back up shows at once. Pure: the sheet asks the box; this says what to show.
 */
class FolderBrowser {
    companion object {
        const val KEEP = 32

        /** Why [name] can't be a new folder here (one line), or null. */
        fun nameProblem(name: String, siblings: List<String>): String? = when {
            name.isBlank() -> "Name the folder."
            '/' in name || '\u0000' in name || name.any { it == '\n' || it == '\r' } -> "One name, no slashes."
            name.startsWith(".") -> "Not a hidden folder."
            name.toByteArray().size > 255 -> "Too long."
            siblings.any { it == name } -> "$name is already there."
            else -> null
        }

        /** `~` for the home, `~/a/b` under it; anything else as it is. */
        fun shown(path: String, home: String?): String = when {
            home == null -> path
            path == home -> "~"
            path.startsWith(home.trimEnd('/') + "/") -> "~/" + path.removePrefix(home.trimEnd('/') + "/")
            else -> path
        }
    }

    data class Listing(val folders: List<String>, val more: Boolean)

    /** The box user's home, as the box named it at the first listing. */
    var home: String? = null
        private set
    /** The folder shown; null until the first listing answers. */
    var path: String? = null
        private set
    /** The folder being read (null: none; "" the home, before the box has named it). */
    var reading: String? = null
        private set
    /** The last refusal, as the box said it; cleared by the next move. */
    var problem: String? = null
        private set
    /** The box refused the browse itself (an older kore-host): the sheet falls back to its served folders. */
    var unsupported = false
        private set

    private val kept = object : LinkedHashMap<String, Listing>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Listing>) = size > KEEP
    }

    val folders: List<String> get() = path?.let { kept[it]?.folders }.orEmpty()
    val more: Boolean get() = path?.let { kept[it]?.more } == true
    val started: Boolean get() = path != null || reading != null || unsupported

    /** Open here takes the folder shown, never while another is being read. */
    val canOpen: Boolean get() = path != null && reading == null

    /** The home's first read failed (not an older box): nothing to show; the sheet offers Retry. */
    val failedFirst: Boolean get() = path == null && reading == null && !unsupported

    /** Above the home there's nothing a phone may open: up stops there. */
    val canGoUp: Boolean get() = path.let { p -> p != null && p != home && parentOf(p) != null }

    /**
     * Goes to [to] (null: the home): a folder already read shows at once (false); else it's read
     * now, and true says the sheet should ask the box for it.
     */
    fun go(to: String?): Boolean {
        problem = null
        val target = to ?: home
        if (target != null) kept[target]?.let { path = target; reading = null; return false }
        reading = target ?: ""
        return true
    }

    fun into(name: String): String? = path?.let { child(it, name) }

    fun up(): String? = if (canGoUp) parentOf(path!!) else null

    /**
     * The box's answer to `fs.list` for [asked] (null: the home). A late answer for a folder the
     * sheet has left is kept but not shown.
     */
    fun listed(asked: String?, result: JsonObject) {
        val current = reading == (asked ?: "") || (asked == null && reading == home)
        if (!result.bool("ok")) {
            if (!current) return
            reading = null
            // The first read failed: nothing of it is kept, so Retry starts clean.
            if (path == null) { home = null; kept.clear() }
            val code = result.str("code")
            // An older box: a phone's grant isn't let browse at all.
            if (code == "denied.control" || (code == "invalid" && path == null)) unsupported = true
            else problem = result.str("message") ?: refusalWords(code)
            return
        }
        val at = result.str("path") ?: asked ?: return
        if (asked == null && home == null) home = at
        kept[at] = Listing(
            result.objs("entries").filter { it.str("kind") == "dir" || (it.str("kind") == "link" && it.bool("dir")) }.mapNotNull { it.str("name") },
            result.bool("more"),
        )
        if (current) { path = at; reading = null }
    }

    /** [name] was made where the browser stands: listed there, and the browser goes into it (empty). */
    fun made(name: String, at: String? = path) {
        val parent = at ?: return
        val listing = kept[parent]
        if (listing != null && name !in listing.folders) {
            kept[parent] = listing.copy(folders = (listing.folders + name).sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it }))
        }
        val inside = child(parent, name)
        kept[inside] = Listing(emptyList(), false)
        path = inside
        reading = null
        problem = null
    }

    fun refused(line: String) { problem = line }

    private fun child(parent: String, name: String) = if (parent == "/") "/$name" else "${parent.trimEnd('/')}/$name"

    private fun parentOf(p: String): String? {
        val trimmed = p.trimEnd('/')
        if (trimmed.isEmpty()) return null
        val cut = trimmed.lastIndexOf('/')
        return if (cut <= 0) "/" else trimmed.substring(0, cut)
    }
}
