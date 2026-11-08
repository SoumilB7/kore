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
        val mesh = (context.applicationContext as KoreApp).mesh
        val nodes = mesh.nodes.value.joinToString(",") { "${it.device.value.kind.wire}:${it.state.value::class.simpleName}" }
        resultData = "joined=${mesh.joined} network=${mesh.networkOn} background=${mesh.background} join=${mesh.join.step.value::class.simpleName} nodes=[$nodes]"
    }
}
