package dev.kore.phone

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Holds the phone's KoreNet ([Mesh]): the tailnet and a link to each device, run while a Kore
 * screen shows (and, with the background setting on, under its foreground service). Screenshots
 * are allowed unless turned off in Settings; backups stay off.
 */
class KoreApp : Application() {
    /** Background work: a failure is logged without its content, never a crash that drops a link. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, e -> android.util.Log.w("kore", "background: ${e::class.simpleName}") })

    val mesh by lazy { Mesh(this) }

    /** A debug build (installed over adb), never a release one. */
    val debuggable get() = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0

    var screenshotsAllowed: Boolean
        get() = getSharedPreferences("kore", MODE_PRIVATE).getBoolean("screenshots", true)
        set(value) = getSharedPreferences("kore", MODE_PRIVATE).edit().putBoolean("screenshots", value).apply()

    /** The screen in front, for the fingerprint prompt. */
    @Volatile private var front: java.lang.ref.WeakReference<Activity>? = null
    val frontActivity: Activity? get() = front?.get()

    /** The node shown in front and the chat open there: presence follows it. */
    fun focus(node: String?, chat: String? = null) {
        mesh.nodes.value.forEach { n -> if (n.id.toString() == node) n.setPresence(true, chat) else n.setPresence(true) }
    }

    private var started = 0
    private val main = Handler(Looper.getMainLooper())
    /** Off screen for a moment (a rotation, a hop between screens) isn't off screen. */
    private val offScreen = Runnable { mesh.onScreen(false) }

    override fun onCreate() {
        super.onCreate()
        // The screen on, or the phone unlocked: a quiet link gets one probe.
        registerReceiver(object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context, i: android.content.Intent) {
                if (started > 0) mesh.nodes.value.forEach { it.reconnectNow() }
            }
        }, android.content.IntentFilter().apply {
            addAction(android.content.Intent.ACTION_SCREEN_ON)
            addAction(android.content.Intent.ACTION_USER_PRESENT)
        }, android.content.Context.RECEIVER_NOT_EXPORTED)
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityCreated(a: Activity, b: Bundle?) {
                if (!screenshotsAllowed) a.window.setFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE, android.view.WindowManager.LayoutParams.FLAG_SECURE)
            }
            override fun onActivityStarted(a: Activity) {
                if (started++ == 0) {
                    main.removeCallbacks(offScreen)
                    mesh.onScreen(true)
                }
            }
            override fun onActivityResumed(a: Activity) {
                front = java.lang.ref.WeakReference(a)
                val chat = if (a is dev.kore.phone.ui.ChatActivity) a.intent?.getStringExtra("chat") else null
                focus(a.nodeId, chat)
            }
            override fun onActivityPaused(a: Activity) { if (front?.get() === a) front = null }
            override fun onActivityStopped(a: Activity) {
                started = maxOf(0, started - 1)
                if (started == 0) main.postDelayed(offScreen, OFF_SCREEN_GRACE_MS)
            }
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) = Unit
            override fun onActivityDestroyed(a: Activity) = Unit
        })
    }

    companion object {
        const val OFF_SCREEN_GRACE_MS = 5_000L
    }
}

val Activity.kore: KoreApp get() = application as KoreApp

/** The node a screen shows: its intent's `node`, else the first one. */
val Activity.nodeId: String? get() = intent?.getStringExtra("node") ?: kore.mesh.nodes.value.firstOrNull()?.id?.toString()
