package dev.kore.phone.ui

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.kore.link.node.NodeClient
import dev.kore.link.trust.NodeKind
import dev.kore.phone.R
import dev.kore.phone.kore
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch

/**
 * Settings: Devices (each device, KoreNet on or off on this phone, Leave KoreNet), the background
 * switch (off by default), notifications, screenshots, updates, and what this phone is.
 */
class SettingsActivity : Activity() {
    private lateinit var content: LinearLayout
    private var watch: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = column()
        root.addView(LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            setPadding(dp(4), dp(4), dp(16), dp(4))
            addView(label("‹", 30f).apply { gravity = Gravity.CENTER; contentDescription = "Back"; setOnClickListener { finish() }; pressable(24) }, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(label("Settings", 17f, bold = true))
        })
        content = column(16)
        root.addView(ScrollView(this).apply { addView(content) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    override fun onStart() {
        super.onStart()
        render()
        watch = kore.scope.launch {
            merge(
                kore.mesh.nodes.flatMapLatest { nodes -> if (nodes.isEmpty()) flowOf(Unit) else combine(nodes.map { it.state }) { } },
                Updates.status,
            ).collect { runOnUiThread { render() } }
        }
    }

    override fun onStop() {
        watch?.cancel()
        super.onStop()
    }

    private fun render() {
        content.removeAllViews()
        val mesh = kore.mesh
        val full = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        content.addView(sectionLabel("Devices", first = true))
        if (mesh.nodes.value.isEmpty()) content.addView(grouped(listOf(groupRow(null, "No devices yet", null))), full)
        else content.addView(grouped(mesh.nodes.value.map(::deviceRow)), full)
        content.addView(sectionLabel("This phone"))
        content.addView(grouped(listOf(
            switchRow(R.drawable.i_net, "KoreNet", "Kore connects only while it's open, so it can't notify you while it's closed.", mesh.networkOn) { mesh.networkOn = it },
            groupRow(R.drawable.i_bell, "Notifications", null, chevron = true) {
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            },
            switchRow(R.drawable.i_shield, "Allow screenshots", null, kore.screenshotsAllowed) { kore.screenshotsAllowed = it; recreate() },
            updateRow(),
        )), full)
        // The one destructive step, alone and last (spec §6: err, centred).
        content.addView(grouped(listOf(LinearLayout(this).apply {
            gravity = Gravity.CENTER
            minimumHeight = dp(52)
            addView(label("Leave KoreNet").apply { type(Type.BodyMedium); setTextColor(Tone.err) })
            contentDescription = "Leave KoreNet"
            setOnClickListener { leave() }
            pressFill(null, Tone.l2, 0)
        })), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(24) })
        val code = mesh.deviceId.toString().take(8).let { it.take(4) + " " + it.drop(4) }
        content.addView(label("Kore for Android ${packageManager.getPackageInfo(packageName, 0).versionName} · this phone $code").apply {
            type(Type.Caption); setTextColor(Tone.faint); gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, dp(24))
        }, full)
    }

    /** One device: its icon, name and kind, a point in its state's colour; a Mac's ⋯ forgets it on this phone. */
    private fun deviceRow(n: NodeClient): View {
        val mac = n.device.value.kind == NodeKind.MAC
        val (_, color) = nodeLook(n.state.value)
        val more = if (!mac) null else barIcon(R.drawable.i_more, "More for ${n.name}").apply {
            // Forget is for a Mac only: a box comes back with the next Mac welcome's directory (T-A5).
            setOnClickListener { v -> PopMenu(this@SettingsActivity).show(v, listOf(PopMenu.Item("Forget on this phone", danger = true) { kore.mesh.forget(n.id); render() })) }
            pressFill(null, Tone.l3, 22)
        }
        return groupRow(if (mac) R.drawable.i_laptop else R.drawable.i_server, n.name, if (mac) "Mac" else "box",
            end = LinearLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(point(color))
                if (more != null) addView(more, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginStart = dp(4) })
            })
    }

    /** A row that holds Kore's switch: the whole row takes the tap; read aloud as a switch. */
    private fun switchRow(icon: Int, title: String, note: String?, on: Boolean, change: (Boolean) -> Unit): View =
        groupRow(icon, title, note, end = switchTrack(on)) { change(!on); if (!isFinishing) render() }.apply { switchSemantics(title, on) }

    private fun leave() {
        lateinit var s: Sheet
        s = Sheet(this, K.err).show {
            title("Leave KoreNet?", "This phone signs out of Tailscale and forgets every device. Joining again needs Allow on a Mac.")
            buttons("Leave", danger = true) {
                s.dismiss()
                kore.mesh.leave()
                startActivity(Intent(this@SettingsActivity, JoinActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
                finish()
            }
        }
    }

    /** Updates (spec §6): what's true now on the row, its one action in accent at the end. */
    private fun updateRow(): View {
        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""
        fun action(text: String, go: () -> Unit) = label(text).apply { type(Type.BodyMedium); setTextColor(Tone.accent); setOnClickListener { go() } }
        val check = { kore.scope.launch { Updates.check(this@SettingsActivity) }; Unit }
        return when (val st = Updates.status.value) {
            is Updates.Status.Available -> groupRow(R.drawable.i_download, "Update ready", "Kore ${st.offer.version}", end = action("Install") { kore.scope.launch { Updates.install(kore, st.offer) } })
            is Updates.Status.Downloading -> groupRow(R.drawable.i_download, "Downloading…", "${st.percent}%")
            Updates.Status.Installing -> groupRow(R.drawable.i_download, "Installing…", null)
            Updates.Status.Checking -> groupRow(R.drawable.i_download, "Checking…", null)
            Updates.Status.UpToDate -> groupRow(R.drawable.i_download, "Updates", "Up to date · $version", end = action("Check", check))
            is Updates.Status.Problem -> groupRow(R.drawable.i_download, "Updates", st.line, secondColor = Tone.warn, end = action("Check", check))
            Updates.Status.Idle -> groupRow(R.drawable.i_download, "Updates", version, end = action("Check", check))
        }
    }

}
