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
                val desc = intent.getStringExtra("desc") ?: return run { resultData = "no desc" }
                val front = (context.applicationContext as KoreApp).frontActivity ?: return run { resultData = "no screen" }
                front.runOnUiThread { (find(front.window.decorView) { it == desc } ?: find(front.window.decorView) { it.startsWith(desc) })?.performClick() }
                resultData = "tapped $desc"
                return
            }
        }
        val mesh = (context.applicationContext as KoreApp).mesh
        val nodes = mesh.nodes.value.joinToString(",") { "${it.device.value.kind.wire}:${it.state.value::class.simpleName}" }
        resultData = "joined=${mesh.joined} network=${mesh.networkOn} join=${mesh.join.step.value::class.simpleName} nodes=[$nodes] logs=${(dev.kore.phone.StandIns.current as? Demo)?.logsRead}"
    }

    /** The first shown view whose content description [matches] (exact first, then by its start: `Mode` finds "Mode: Manual"). */
    private fun find(v: android.view.View, matches: (String) -> Boolean): android.view.View? {
        if (v.contentDescription?.toString()?.let(matches) == true && v.isShown) return v
        if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i), matches)?.let { return it }
        return null
    }
}
