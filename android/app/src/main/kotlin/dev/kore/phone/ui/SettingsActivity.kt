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
            addView(label("‹", 30f).apply { gravity = Gravity.CENTER; contentDescription = "Back"; setOnClickListener { finish() } }, LinearLayout.LayoutParams(dp(48), dp(48)))
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
        heading("Devices")
        for (n in mesh.nodes.value) content.addView(deviceRow(n))
        if (mesh.nodes.value.isEmpty()) content.addView(label("No devices yet.", 14f, K.dim).apply { setPadding(dp(4), 0, 0, dp(6)) })
        content.addView(toggle("KoreNet on this phone", mesh.networkOn) { mesh.networkOn = it })
        content.addView(button("Leave KoreNet", K.err) { leave() })
        heading("Background")
        content.addView(toggle("Stay connected when Kore is closed", mesh.background) { mesh.background = it; if (it) Onboarding.show(this) })
        content.addView(label("Off, Kore connects only while it's open. On, it keeps a notification and uses more battery.", 13f, K.faint).apply { setPadding(dp(4), dp(6), dp(4), 0) })
        heading("Notifications")
        content.addView(button("Notification settings", K.text) {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
        })
        heading("Privacy")
        content.addView(toggle("Allow screenshots", kore.screenshotsAllowed) { kore.screenshotsAllowed = it; recreate() })
        heading("Updates")
        content.addView(updateRow())
        heading("About")
        val code = mesh.deviceId.toString().take(8).let { it.take(4) + " " + it.drop(4) }
        content.addView(label("Kore for Android ${packageManager.getPackageInfo(packageName, 0).versionName} · this phone $code", 13f, K.faint).apply { setPadding(dp(4), 0, 0, dp(24)) })
    }

    /** One device: its glyph, name and state; ⋯ forgets it on this phone. */
    private fun deviceRow(n: NodeClient): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(14), 0, dp(4), 0)
        background = rounded(K.surface)
        val (glyph, color) = nodeLook(n.state.value)
        addView(label(glyph, 12f, color))
        val kind = if (n.device.value.kind == NodeKind.MAC) "Mac" else "box"
        addView(label(" ${n.name}", 15f).apply { maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(label(kind, 12f, K.faint).apply { setPadding(dp(8), 0, dp(4), 0) })
        addView(label("⋯", 18f, K.dim).apply {
            gravity = Gravity.CENTER
            minHeight = dp(44)
            setPadding(dp(10), 0, dp(10), 0)
            contentDescription = "More for ${n.name}"
            setOnClickListener { v -> PopMenu(this@SettingsActivity).show(v, listOf(PopMenu.Item("Forget on this phone", danger = true) { kore.mesh.forget(n.id); render() })) }
        })
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) }
    }

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

    private fun updateRow(): View = when (val st = Updates.status.value) {
        is Updates.Status.Available -> button("Update available · ${st.offer.version}  ·  Install", K.accent) { kore.scope.launch { Updates.install(kore, st.offer) } }
        is Updates.Status.Downloading -> button("Downloading… ${st.percent}%", K.dim) {}
        Updates.Status.Installing -> button("Installing…", K.dim) {}
        Updates.Status.Checking -> button("Checking…", K.dim) {}
        Updates.Status.UpToDate -> button("Up to date · Check again", K.text) { kore.scope.launch { Updates.check(this@SettingsActivity) } }
        is Updates.Status.Problem -> button(st.line, K.warn) { kore.scope.launch { Updates.check(this@SettingsActivity) } }
        Updates.Status.Idle -> button("Check for updates", K.text) { kore.scope.launch { Updates.check(this@SettingsActivity) } }
    }

    private fun heading(text: String) = content.addView(label(text, 13f, K.dim, bold = true).apply { setPadding(dp(4), dp(18), 0, dp(8)) })

    private fun button(text: String, color: Int, onClick: () -> Unit): View = label(text, 15f, color).apply {
        gravity = Gravity.CENTER_VERTICAL
        minHeight = dp(48)
        setPadding(dp(14), 0, dp(14), 0)
        background = rounded(K.surface)
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) }
    }

    private fun toggle(text: String, on: Boolean, change: (Boolean) -> Unit): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(48)
        setPadding(dp(14), 0, dp(10), 0)
        background = rounded(K.surface)
        addView(label(text, 15f), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(android.widget.Switch(this@SettingsActivity).apply { isChecked = on; setOnCheckedChangeListener { _, v -> change(v) } })
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) }
    }
}
