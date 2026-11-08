package dev.kore.phone.ui

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import dev.kore.link.node.JoinFlow.Step
import dev.kore.phone.R
import dev.kore.phone.kore
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * The first run (korenet-first-connect.html E): Join KoreNet → Tailscale's sign-in in a Custom Tab
 * → Finding your Mac… → Allow on the Mac → Home. One primary action per screen at most. The
 * knocking on Macs runs only while this screen shows ([dev.kore.link.node.JoinFlow]).
 */
class JoinActivity : Activity() {
    private lateinit var root: LinearLayout
    private var watch: Job? = null
    /** The sign-in URL no browser here could open: the screen offers it to copy. */
    private var unopened: String? = null
    private val flow get() = kore.mesh.join

    /** Opened from a removed or refused device's row (Join again, Ask again): knocks though joined. */
    private val again get() = intent?.getBooleanExtra(AGAIN, false) == true
    /** The knock [again] asked for has started (once per screen). */
    private var knocked = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (kore.mesh.joined && !again && intent?.getBooleanExtra("signIn", false) != true) return home()
        knocked = savedInstanceState?.getBoolean(AGAIN) == true
        root = column()
        setContentView(root)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(AGAIN, knocked)
    }

    override fun onStart() {
        super.onStart()
        if (isFinishing) return
        if (kore.mesh.joined && !again && intent?.getBooleanExtra("signIn", false) != true) return home()
        flow.visible(true)
        if (again && !knocked) {
            knocked = true
            flow.again()
        }
        // "Sign in" from a signed-out device (A1): the sign-in again, whatever an earlier Join left.
        if (intent?.getBooleanExtra("signIn", false) == true && !knocked) {
            knocked = true
            flow.signInAgain()
        }
        watch = kore.scope.launch { flow.step.combine(flow.offline) { s, off -> s to off }.collect { (s, off) -> runOnUiThread { render(s, off) } } }
    }

    override fun onStop() {
        watch?.cancel()
        if (::root.isInitialized) flow.visible(false)
        super.onStop()
    }

    private fun render(s: Step, offline: Boolean) {
        root.removeAllViews()
        if (s !is Step.SigningIn) unopened = null
        flow.tab.toOpen(s)?.let { if (!signIn(it)) unopened = it }
        // Mid sign-in with no network: one quiet line; it goes on by itself once back.
        val noNet = if (offline) "\nNo internet on this phone; Kore goes on once it's back." else ""
        when (s) {
            // Cancel on a Join again: back to the devices.
            is Step.Join -> if (again && kore.mesh.joined) home() else {
                screen(logo(), "Kore", if (s.failed) "Tailscale didn't start on this phone. Try again." else "Your Mac's chats, from here.") {
                    primary(if (s.failed) "Try again" else "Join KoreNet") { kore.mesh.beginJoin() }
                    addView(label("Signs in with Tailscale", 12f, K.faint).apply { gravity = Gravity.CENTER })
                }
            }
            Step.Starting -> screen(halo(R.drawable.ic_mac, pulse = true), "Starting…", "Kore's own Tailscale is coming up.$noNet") { quiet("Cancel") { flow.cancel() } }
            is Step.SigningIn -> {
                val small = if (unopened == s.url) "No browser here opened the sign-in page. Copy its link into one." else "Finish in the browser tab; Kore goes on from there."
                screen(halo(R.drawable.ic_mac, pulse = true), "Sign in to Tailscale", small + noNet) {
                    if (unopened == s.url) secondary("Copy sign-in link") { copy("sign-in link", s.url) }
                    else secondary("Open sign-in again") { if (!signIn(s.url)) { unopened = s.url; render(s, offline) } }
                    quiet("Cancel") { flow.cancel() }
                }
            }
            is Step.Finding -> {
                // Signed in again after a lapse: the devices are known, Home picks up from here.
                if (kore.mesh.joined && !again) {
                    kore.mesh.nodes.value.forEach { it.post(dev.kore.link.node.NodeMachine.Event.SignedIn) }
                    return home()
                }
                val mac = when (s.macs.size) {
                    0 -> null
                    1 -> s.macs[0]
                    2 -> "${s.macs[0]} and ${s.macs[1]}"
                    else -> s.macs.dropLast(1).joinToString(", ") + " and " + s.macs.last()
                }
                val one = s.macs.size <= 1
                val line = when {
                    mac == null && s.asleep.isNotEmpty() -> "${s.asleep.first()} is on your tailnet but offline.\nWake it and open Kore there."
                    mac == null -> "Signed in. No Mac is on your tailnet yet."
                    s.addClosed -> "Open Add device on ${s.closedOn ?: mac}.\nIn Kore there: Devices, then +."
                    s.stopped -> "$mac didn't answer. In Kore there, open Devices and press +, then try again."
                    one -> "$mac is on your tailnet.\nIn Kore there, open Devices and press +."
                    else -> "$mac are on your tailnet.\nIn Kore on one of them, open Devices and press +."
                }
                screen(halo(R.drawable.ic_mac, pulse = !s.stopped), if (s.stopped) "No answer yet" else "Finding your Mac…", line) {
                    if (s.stopped) primary("Try again") { flow.again() }
                    quiet("Cancel") { flow.cancel() }
                }
            }
            is Step.Allowing -> screen(halo(R.drawable.ic_mac, pulse = true), "Allow on ${s.mac}", "Kore there is asking about this phone.") {
                addView(facts(listOf("This phone" to dev.kore.phone.PhoneName.of(this@JoinActivity), "Tailscale" to s.self.shortName, "Address" to (s.self.ips.firstOrNull() ?: ""))))
                quiet("Cancel") { flow.cancel() }
            }
            is Step.Denied -> screen(halo(R.drawable.ic_mac), if (s.timedOut) "No answer on ${s.mac}" else "Not allowed on ${s.mac}",
                if (s.timedOut) "Nobody pressed Allow on ${s.mac} in time." else "${s.mac} said no to this phone.") {
                secondary("Ask again") { flow.again() }
                quiet("Leave KoreNet") { leave() }
            }
            is Step.NoMac -> screen(halo(R.drawable.ic_mac), "No Mac with Kore here",
                (s.login?.let { "Signed in as $it.\n" } ?: "") + "Kore may be on a Mac signed in to another account.") {
                secondary("Switch account") { leave() }
                quiet("Get Kore for Mac") { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(KORE_FOR_MAC))) }
            }
            is Step.NeedsApproval -> screen(halo(R.drawable.ic_mac), "Waiting for a signature",
                "Your tailnet has to approve or sign this phone first (Tailnet Lock or device approval).") {
                s.nodeKey?.let { key ->
                    addView(facts(listOf("Node key" to key.take(16) + "…" + key.takeLast(4))))
                    secondary("Copy node key") { copy("node key", key) }
                }
                quiet("Cancel") { flow.cancel() }
            }
            is Step.Joined -> home()
        }
    }

    /**
     * Tailscale's own page in a Custom Tab over the app (no library: the session extra is enough;
     * a browser without Custom Tabs opens it as a plain tab). No browser at all: a plain VIEW in a
     * new task, then the link to copy.
     */
    private fun signIn(url: String): Boolean {
        val uri = Uri.parse(url)
        val tab = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            putExtras(Bundle().apply { putBinder("android.support.customtabs.extra.SESSION", null) })
            putExtra("android.support.customtabs.extra.TOOLBAR_COLOR", K.bg)
            putExtra("androidx.browser.customtabs.extra.SHARE_STATE", 2)
        }
        val plain = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { startActivity(tab) }.isSuccess || runCatching { startActivity(plain) }.isSuccess) return true
        android.util.Log.w("kore", "sign-in: no browser opened the page")
        return false
    }

    private fun copy(what: String, text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(what, text))
        Quiet.say(this, "Copied")
    }

    private fun leave() {
        kore.mesh.leave()
    }

    private fun home() {
        startActivity(Intent(this, HomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }

    // MARK: the screen's parts (360 dp mockup: a centred middle, actions at the foot)

    private fun screen(top: View, big: String, small: String, foot: LinearLayout.() -> Unit) {
        val mid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(34), 0, dp(34), 0)
            addView(top, LinearLayout.LayoutParams(dp(64), dp(64)))
            addView(label(big, 20f, bold = true).apply { gravity = Gravity.CENTER; setPadding(0, dp(14), 0, dp(6)) })
            addView(label(small, 13.5f, K.dim).apply { gravity = Gravity.CENTER; setLineSpacing(0f, 1.25f) })
        }
        root.addView(mid, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), 0, dp(20), dp(26))
            foot()
        })
    }

    private fun logo(): View = label("K", 30f, K.accent, bold = true).apply {
        gravity = Gravity.CENTER
        typeface = Typeface.DEFAULT_BOLD
        background = rounded(K.surface, 16)
    }

    private fun halo(glyph: Int, pulse: Boolean = false): View = ImageView(this).apply {
        setImageResource(glyph)
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        setPadding(dp(18), dp(18), dp(18), dp(18))
        background = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setStroke(dp(2), K.raised)
        }
        if (pulse) animate().alpha(0.5f).setDuration(900).withEndAction { animate().alpha(1f).setDuration(900) }.start()
    }

    private fun facts(rows: List<Pair<String, String>>): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(10), dp(14), dp(10))
        background = rounded(K.surface, 12)
        for ((k, v) in rows) addView(LinearLayout(this@JoinActivity).apply {
            addView(label(k, 12f, K.faint), LinearLayout.LayoutParams(dp(96), LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(label(v, 12f, K.text).apply { typeface = Typeface.MONOSPACE; maxLines = 1 })
        })
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(10) }
    }

    private fun LinearLayout.primary(text: String, go: () -> Unit) = addView(label(text, 15f, K.onAccent, bold = true).apply {
        gravity = Gravity.CENTER
        background = rounded(K.accent, 14)
        setOnClickListener { go() }
        tag = text
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(10) })

    private fun LinearLayout.secondary(text: String, go: () -> Unit) = addView(label(text, 15f, K.text).apply {
        gravity = Gravity.CENTER
        background = rounded(K.surface, 14)
        setOnClickListener { go() }
        tag = text
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(10) })

    private fun LinearLayout.quiet(text: String, go: () -> Unit) = addView(label(text, 15f, K.dim).apply {
        gravity = Gravity.CENTER
        setOnClickListener { go() }
        tag = text
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(34)))

    companion object {
        const val KORE_FOR_MAC = "https://github.com/SoumilB7/kore"
        /** Extra: Join again / Ask again from a device's row. */
        const val AGAIN = "again"
    }
}
