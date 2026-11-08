package dev.kore.phone.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.kore.phone.KoreApp

/**
 * Debug builds only: answers `adb shell am broadcast -a dev.kore.android.debug.STATE` with the
 * phone's KoreNet state in one line (no content, no keys, no URLs), for smoke tests.
 */
class Hooks : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            // The demo Mac asks for the phone's log; the next STATE says how much came back.
            "dev.kore.android.debug.ASK_LOGS" -> {
                (dev.kore.phone.StandIns.current as? Demo)?.links?.get("mac")?.askLogs()
                resultData = "asked"
                return
            }
            // A running turn streams into a chat on the demo Mac (`--es chat <id>`).
            "dev.kore.android.debug.STREAM" -> {
                val chat = intent.getStringExtra("chat") ?: return run { resultData = "no chat" }
                (dev.kore.phone.StandIns.current as? Demo)?.links?.get("mac")?.stream(chat, intent.getIntExtra("pieces", 60), intent.getLongExtra("every", 150))
                    ?: return run { resultData = "no demo" }
                resultData = "streaming"
                return
            }
            // The front screen's list, by state, not pixels: px of it below the view (gap=0 at the
            // end, "unlaid" when its last row isn't laid out), its rows, the first row shown and its top,
            // and whether "↓ New" shows.
            "dev.kore.android.debug.LIST" -> {
                val front = (context.applicationContext as KoreApp).frontActivity ?: return run { resultData = "no screen" }
                val list = findList(front.window.decorView) ?: return run { resultData = "no list" }
                val lm = list.layoutManager as? androidx.recyclerview.widget.LinearLayoutManager ?: return run { resultData = "no rows" }
                val n = list.adapter?.itemCount ?: 0
                val gap = if (n == 0) "0" else lm.findViewByPosition(n - 1)
                    ?.let { maxOf(0, lm.getDecoratedBottom(it) - (list.height - list.paddingBottom)).toString() } ?: "unlaid"
                val jump = find(front.window.decorView) { it == "New, to the end" }
                val first = lm.findFirstVisibleItemPosition()
                val top = lm.findViewByPosition(first)?.let { lm.getDecoratedTop(it) }
                resultData = "gap=$gap rows=$n first=$first@$top jump=${jump != null}"
                return
            }
            // An image on the clipboard (the app's own content URI), for a real Paste into the composer.
            "dev.kore.android.debug.CLIP_IMAGE" -> {
                val dir = java.io.File(context.cacheDir, "shots").apply { mkdirs() }
                val file = java.io.File(dir, "pasted.png")
                context.assets.open("demo/pasted.png").use { input -> file.outputStream().use { input.copyTo(it) } }
                val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
                val clip = android.content.ClipData.newUri(context.contentResolver, "image", uri)
                context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(clip)
                resultData = "clipped $uri"
                return
            }
            // A tap on the screen in front, by the view's identity (its content description,
            // `--es desc Mode`), never by a point: for screenshots of what it opens.
            "dev.kore.android.debug.TAP" -> {
                val front = (context.applicationContext as KoreApp).frontActivity ?: return run { resultData = "no screen" }
                // `--es label Allow`: a shown button by its words, for one without a description.
                intent.getStringExtra("label")?.let { label ->
                    front.runOnUiThread { labelled(front.window.decorView, label)?.performClick() }
                    resultData = "tapped $label"
                    return
                }
                val desc = intent.getStringExtra("desc") ?: return run { resultData = "no desc" }
                front.runOnUiThread { (find(front.window.decorView) { it == desc } ?: find(front.window.decorView) { it.startsWith(desc) })?.performClick() }
                resultData = "tapped $desc"
                return
            }
            // A partial selection, by the words (`--es text "the total"`) in a shown picking text
            // view: a long-press there, in-process (as a finger's, so the system's toolbar comes),
            // then the selection set to exactly those words.
            "dev.kore.android.debug.SELECT" -> {
                val words = intent.getStringExtra("text") ?: return run { resultData = "no text" }
                val front = (context.applicationContext as KoreApp).frontActivity ?: return run { resultData = "no screen" }
                front.runOnUiThread { select(front.window.decorView, words) }
                resultData = "selecting $words"
                return
            }
        }
        val mesh = (context.applicationContext as KoreApp).mesh
        val nodes = mesh.nodes.value.joinToString(",") { "${it.device.value.kind.wire}:${it.state.value::class.simpleName}" }
        resultData = "joined=${mesh.joined} network=${mesh.networkOn} join=${mesh.join.step.value::class.simpleName} nodes=[$nodes] logs=${(dev.kore.phone.StandIns.current as? Demo)?.logsRead}"
    }

    private fun findList(v: android.view.View): androidx.recyclerview.widget.RecyclerView? {
        if (v is androidx.recyclerview.widget.RecyclerView && v.isShown) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) findList(v.getChildAt(i))?.let { return it }
        return null
    }

    /** The first shown clickable text view that reads [label]. */
    private fun labelled(v: android.view.View, label: String): android.view.View? {
        if (v is android.widget.TextView && v.isShown && v.isClickable && v.text.toString() == label) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) labelled(v.getChildAt(i), label)?.let { return it }
        return null
    }

    private fun picking(v: android.view.View, words: String): android.widget.TextView? {
        if (v is android.widget.TextView && v.isShown && v.isTextSelectable && v.text.contains(words)) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) picking(v.getChildAt(i), words)?.let { return it }
        return null
    }

    private fun select(root: android.view.View, words: String) {
        val v = picking(root, words) ?: return
        val start = v.text.indexOf(words)
        val layout = v.layout ?: return
        val line = layout.getLineForOffset(start)
        val x = layout.getPrimaryHorizontal(start) + v.totalPaddingLeft - v.scrollX + 4f
        val y = (layout.getLineTop(line) + layout.getLineBottom(line)) / 2f + v.totalPaddingTop - v.scrollY
        val at = android.os.SystemClock.uptimeMillis()
        fun touch(action: Int, time: Long) = android.view.MotionEvent.obtain(at, time, action, x, y, 0).apply {
            source = android.view.InputDevice.SOURCE_TOUCHSCREEN
        }
        val hold = android.view.ViewConfiguration.getLongPressTimeout().toLong() + 150
        v.dispatchTouchEvent(touch(android.view.MotionEvent.ACTION_DOWN, at))
        v.postDelayed({
            v.dispatchTouchEvent(touch(android.view.MotionEvent.ACTION_UP, at + hold))
            v.postDelayed({ (v.text as? android.text.Spannable)?.let { android.text.Selection.setSelection(it, start, start + words.length) } }, 300)
        }, hold)
    }

    /** The first shown view whose content description [matches] (exact first, then by its start: `Mode` finds "Mode: Manual"). */
    private fun find(v: android.view.View, matches: (String) -> Boolean): android.view.View? {
        if (v.contentDescription?.toString()?.let(matches) == true && v.isShown) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i), matches)?.let { return it }
        return null
    }
}
