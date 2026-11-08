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
        }
        val mesh = (context.applicationContext as KoreApp).mesh
        val nodes = mesh.nodes.value.joinToString(",") { "${it.device.value.kind.wire}:${it.state.value::class.simpleName}" }
        resultData = "joined=${mesh.joined} network=${mesh.networkOn} join=${mesh.join.step.value::class.simpleName} nodes=[$nodes] logs=${(dev.kore.phone.StandIns.current as? Demo)?.logsRead}"
    }
}
